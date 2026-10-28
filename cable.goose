namespace campfire;
import std;
import json;
import base64;
import http;
import http.websocket;
import http.shared;
import sqlite;
import database;
import view_data;
import sessions;

struct CablePermit { value: bool = true }
struct Publication { room: i64, reply: http::MailAddress, body: u8[] }
// A report to the broker: its kind, an address in the reporting worker's box, and a publication sequence.
struct CableCommand { kind: i32, address: http::MailAddress, value: i64 = 0 }
let CABLE_WINDOW: i64 = 8;
// Every enrolled connection of the worker drained or left the publications before value.
let CABLE_CREDIT: i32 = 2;
// The worker has no cable connection left: the publications before value are credited, and later ones skip it.
let CABLE_EMPTY: i32 = 3;
let CABLE_PUBLISH: i32 = 5;
// The worker's publications go to this address from now on, beginning with sequence value.
let CABLE_REP: i32 = 6;
let CABLE_ACK: i32 = 256;
// Mail to a worker's representative connection: records of publications for the worker to deliver.
let CABLE_PUBS: i32 = 257;
// Mail a worker sends one of its own connections, so that its loop calls it to write.
let CABLE_KICK: i32 = 258;
let CABLE_ENROLLED: i32 = 65536;
// The most kicks a worker has in its box at once. Publication mail queues behind them, so a small number lets
// readers kicked later in a round take the publications that arrived meanwhile in the same write.
let CABLE_KICKS: i64 = 32;
// The most frame bytes one batch writes before waiting for its drain.
let CABLE_BATCH: i64 = 32768;
// A publication record: sequence, room, shared body and its length. A mailbox slot holds four.
let CABLE_RECORD: i64 = 32;
let CABLE_MAIL: i64 = 128;

fn cable_command(kind: i32, address: http::MailAddress, value: i64 = 0) {
    qput(CableCommand { kind: kind, address: address, value: value });
}

// Reports the broker must not lose. They are rare, one per worker per publication, so a full queue only delays one.
fn cable_tell(kind: i32, address: http::MailAddress, value: i64) {
    while !qput(CableCommand { kind: kind, address: address, value: value }) { sleep_ms(1); }
}

fn publish(room: i64, reply: http::MailAddress, body: const u8[:]) {
    // Each publication owns one permit until final delivery, including queued acknowledgements.
    assert(qput(Publication { room: room, reply: reply, body: sql_text(body) }));
    cable_command(CABLE_PUBLISH, reply);
}

fn cable_put(out: u8[>..]&, value: i64) {
    for i in 8 { out.push((value >> (8*i)) as! u8); }
}

// The broker's view of one worker: the connection whose address takes its publications, and how far
// they were sent and credited. A live worker is enrolled in every publication from credited to the tail.
struct CableLink {
    rep: http::MailAddress = http::MailAddress { .. },
    live: bool = false,
    // The representative's address went stale; the worker names another, or reports that it has none.
    stale: bool = false,
    sent: i64 = 0,
    credited: i64 = 0,
}
// The broker owns body from enrollment to retirement, which waits until every enrolled worker credited it.
struct CableDelivery {
    reply: http::MailAddress = http::MailAddress { .. }, room: i64 = 0,
    body: http::Shared = http::Shared { .. }, length: i64 = 0, remaining: i64 = 0
}

// Orders publications, bounds them by the window and the permits, and hands each to every worker with a
// cable connection: one mail per worker, whatever its number of readers. Workers match and write.
thread_fn cable_broker(queued_ack: bool, window_size: i64) {
    var links: CableLink[>..] = [];
    var window: CableDelivery[>..] = [];
    for _ in window_size { window.push(CableDelivery { .. }); }
    var head: i64 = 0;
    var tail: i64 = 0;
    var acknowledged: i64 = 0;
    var body: u8[>..] = [];
    var mail: u8[>..] = [];
    // A worker's box was full: poll for commands, rather than wait for one, and retry.
    var blocked = false;
    fn credit(link: CableLink&, through: i64) {
        while link.credited < through { window[link.credited & (window_size-1)].remaining--; link.credited++; }
    }
    fn apply_command(command: const CableCommand&) {
        if command.kind == CABLE_PUBLISH { return; }
        var index: i64 = -1;
        for &link, i in links { if link.rep.box == command.address.box { index = i; break; } }
        if command.kind == CABLE_REP {
            if index < 0 { index = links.len; links.push(CableLink { .. }); }
            let link .= links[index];
            // A worker that had no connection enrolls in later publications only; one that changed
            // representative is sent again what it has not received.
            if !link.live { link.live = true; link.credited = tail; link.sent = tail; }
            else { link.sent = max(command.value, link.credited); }
            link.rep = command.address; link.stale = false;
        } else if index >= 0 && links[index].live {
            let link .= links[index];
            if command.kind == CABLE_CREDIT { credit(link, min(command.value, link.sent)); }
            else if command.kind == CABLE_EMPTY { credit(link, tail); link.live = false; link.sent = tail; }
        }
    }
    loop {
        if blocked {
            blocked = false;
            let command, exists = qpoll<CableCommand>();
            if exists { apply_command(command); } else { sleep_ms(1); }
        } else {
            let first = qget<CableCommand>();
            apply_command(first);
        }
        // Bound control processing so a busy command queue cannot starve delivery.
        for _ in 0..127 {
            let command, exists = qpoll<CableCommand>();
            if !exists { break; }
            apply_command(command);
        }
        loop {
            while tail - head < window_size {
                let pending, exists = qpoll<Publication>();
                if !exists { break; }
                let entry .= window[tail & (window_size-1)];
                entry.reply = pending.reply; entry.room = pending.room;
                entry.remaining = 0;
                for link in links { if link.live { entry.remaining++; } }
                entry.body = http::Shared { .. }; entry.length = 0;
                if entry.remaining != 0 {
                    body.clear();
                    json::format_string(body, pending.body);
                    let shared, failed = http::shared_put(body, 1);
                    assert(failed == 0);
                    entry.body = shared; entry.length = body.len;
                }
                tail++;
            }
            if queued_ack {
                // Enrollment and payload retention precede success; drain credits still own retirement.
                while acknowledged < tail {
                    let slot = acknowledged & (window_size-1);
                    if http::mail_send(window[slot].reply, CABLE_ACK, "") == http::FULL { break; }
                    acknowledged++;
                }
            }
            // One mail per worker carries up to four publications; the worker enrolls and writes to its readers.
            for &link in links {
                while link.live && !link.stale && link.sent < tail {
                    mail.clear();
                    var n: i64 = 0;
                    while (n+1) * CABLE_RECORD <= CABLE_MAIL && link.sent + n < tail {
                        let sequence = link.sent + n;
                        let entry .= window[sequence & (window_size-1)];
                        cable_put(mail, sequence); cable_put(mail, entry.room); cable_put(mail, entry.body.h); cable_put(mail, entry.length);
                        n++;
                    }
                    let sent = http::mail_send(link.rep, CABLE_PUBS, mail);
                    if sent == http::SENT { link.sent += n; }
                    else if sent == http::FULL { blocked = true; break; }
                    else { link.stale = true; }
                }
            }
            let previous = head;
            // Retire in publication order, including writes whose HTTP client disconnected.
            while head < tail {
                let slot = head & (window_size-1);
                if window[slot].remaining != 0 { break; }
                if queued_ack {
                    if head == acknowledged { break; }
                } else if http::mail_send(window[slot].reply, CABLE_ACK, "") == http::FULL { break; }
                if window[slot].body.h != 0 { http::shared_release(window[slot].body); window[slot].body = http::Shared { .. }; }
                head++;
                assert(qput(CablePermit { .. }));
            }
            if head == previous { break; }
        }
    }
}

fn cable_le(data: const u8[:], at: i64, n: i64) -> i64 {
    var v: i64 = 0;
    for i in n { v |= (data[at+i] as i64) << (8*i); }
    return v;
}

// prefix caches the encoded `{"identifier":...,"message":` that starts each delivery.
struct CableSubscriber { live: bool = false, retiring: bool = false, room: i64, stream: i32, identifier: u8[:], prefix: u8[:] }
// A worker's cable connection, which only its worker's thread touches.
struct CableLocal {
    live: bool = false, gen: i64 = 0, address: http::MailAddress = http::MailAddress { .. }, user: i64 = 0,
    // Not waiting for a written batch to drain.
    ready: bool = true,
    // Listed for a kick; sent one that has not arrived.
    kicked: bool = false, mailed: bool = false,
    // The next publication to write, and the bytes of its current message already written.
    sequence: i64 = 0, offset: i64 = 0,
    // Publications before credited are released; those from credited to sequence wait on a drain.
    credited: i64 = 0,
    // The live subscriptions, by slot.
    mask: i32 = 0,
    subs: CableSubscriber[16] = [CableSubscriber { .. }; 16],
}
// A publication the worker holds: its readers share body, which the broker keeps until the worker credits it.
struct CableEntry { room: i64 = 0, body: http::Shared = http::Shared { .. }, length: i64 = 0, remaining: i64 = 0 }
// One worker's cable state. Publications arrive in sequence; entries[sequence & (window-1)] holds each until
// every connection of the worker enrolled in it drained or left. Subscriptions are snapshotted when the
// worker receives a publication: later subscribers do not inherit it.
struct CableShard {
    window: i64 = 8,
    // The next sequence expected, the first not done by every enrolled connection, and the last credit reported.
    next: i64 = 0, done: i64 = 0, reported: i64 = 0,
    // The connection whose address takes the worker's publications, or -1, and the live connections.
    rep: i64 = -1, count: i64 = 0, gens: i64 = 0, probe: i64 = 0,
    // An address in the worker's box, which names the worker to the broker.
    box: http::MailAddress = http::MailAddress { .. },
    entries: CableEntry[512] = [CableEntry { .. }; 512],
    // Connections to kick, as pairs of index and generation: the first listed of kicks. It never shrinks.
    // flying counts the kicks mailed that have not arrived.
    listed: i64 = 0, flying: i64 = 0,
    kicks: i64[>..] = [],
}

fn cable_owns(conns: const CableLocal[:], index: i64, gen: i64) -> bool {
    return index >= 0 && index < conns.len && conns[index].live && conns[index].gen == gen;
}

fn cable_matches(sub: const CableSubscriber&, user: i64, room: i64) -> bool {
    return sub.live && (if room==0 { sub.stream==2 } else if room<0 { sub.stream==5 && user == -room } else { sub.stream==1 && sub.room==room });
}

// Credits the broker with the publications every enrolled connection drained or left.
fn cable_credit(shard: CableShard&) {
    while shard.done < shard.next && shard.entries[shard.done & (shard.window-1)].remaining == 0 { shard.done++; }
    if shard.rep >= 0 && shard.done > shard.reported {
        shard.reported = shard.done;
        cable_tell(CABLE_CREDIT, shard.box, shard.done);
    }
}

// Adds an upgraded connection, which takes the publications its worker receives from now on.
fn cable_open(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, address: http::MailAddress, user: i64) -> i64 {
    var index: i64 = -1;
    for &c, i in conns { if !c.live { index = i; break; } }
    if index < 0 {
        index = conns.len;
        conns.push(CableLocal { .. });
        for _ in 0..shard.window { targets.push(0); }
    }
    shard.gens++;
    let c .= conns[index];
    c.live = true; c.gen = shard.gens; c.address = address; c.user = user; c.ready = true; c.kicked = false; c.mailed = false;
    c.sequence = shard.next; c.offset = 0; c.credited = shard.next; c.mask = 0;
    shard.count++;
    if shard.rep < 0 { shard.rep = index; shard.box = address; cable_tell(CABLE_REP, address, shard.next); }
    return index;
}

// Removes a connection that closed: its unsent deliveries are cancelled and their publications credited.
fn cable_leave(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&, index: i64, gen: i64) {
    guard cable_owns(conns, index, gen) else { return; }
    let w = shard.window;
    let c .= conns[index];
    c.live = false; c.mask = 0;
    // Its kick, if mailed, ends with the exchange.
    if c.mailed { c.mailed = false; shard.flying--; }
    for &target, slot in targets[index*w..(index+1)*w] {
        if target & CABLE_ENROLLED != 0 { shard.entries[slot].remaining--; }
        target = 0;
    }
    for &sub in c.subs {
        if sub.live || sub.retiring {
            storage.free_slice(sub.identifier); storage.free_slice(sub.prefix);
            sub.live = false; sub.retiring = false;
        }
    }
    shard.count--;
    if shard.rep == index {
        shard.rep = -1;
        for &other, i in conns { if other.live { shard.rep = i; break; } }
        if shard.rep >= 0 {
            // Mail to the old address may have been dropped: the broker sends again from next.
            cable_tell(CABLE_REP, conns[shard.rep].address, shard.next);
        } else {
            // With no connection left, every publication the worker holds is done.
            shard.done = shard.next; shard.reported = shard.next;
            cable_tell(CABLE_EMPTY, shard.box, shard.next);
        }
    }
    cable_credit(shard);
}

// Enrolls the worker's matching subscriptions in each publication of a broker mail, and lists the ready
// readers other than current for a kick.
fn cable_receive(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, data: const u8[:], current: i64) {
    let w = shard.window;
    var at: i64 = 0;
    while at + CABLE_RECORD <= data.len {
        let sequence = cable_le(data, at, 8);
        let room = cable_le(data, at+8, 8);
        let body = http::Shared { h: cable_le(data, at+16, 8) };
        let length = cable_le(data, at+24, 8);
        at += CABLE_RECORD;
        // Sent again after the worker changed representative.
        if sequence < shard.next { continue; }
        if sequence > shard.next {
            // The broker enrolled the worker afresh, after it had no connection: it skips what it was never sent.
            if shard.done == shard.next { shard.done = sequence; }
            else { for k in shard.next..sequence { shard.entries[k & (w-1)] = CableEntry { .. }; } }
            shard.next = sequence;
        }
        let slot = sequence & (w-1);
        var enrolled: i64 = 0;
        for &c, ci in conns {
            var mask: i32 = 0;
            if c.live {
                var live = c.mask;
                var si: i64 = 0;
                while live != 0 {
                    if live & 1 != 0 && cable_matches(c.subs[si], c.user, room) { mask |= 1 << si; }
                    live >>= 1; si++;
                }
            }
            if mask != 0 {
                mask |= CABLE_ENROLLED; enrolled++;
                if ci != current && c.ready && !c.kicked && !c.mailed { c.kicked = true; cable_list(shard, ci); cable_list(shard, c.gen); }
            }
            targets[ci*w+slot] = mask;
        }
        shard.entries[slot] = CableEntry { room: room, body: body, length: length, remaining: enrolled };
        shard.next = sequence + 1;
    }
}

fn cable_list(shard: CableShard&, value: i64) {
    if shard.listed < shard.kicks.len { shard.kicks[shard.listed] = value; } else { shard.kicks.push(value); }
    shard.listed++;
}

// Mails each listed connection a kick, up to CABLE_KICKS in flight or until the worker's box is full.
fn cable_pump(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&) {
    var k: i64 = 0;
    while k < shard.listed && shard.flying < CABLE_KICKS {
        let index = shard.kicks[k];
        let gen = shard.kicks[k+1];
        if cable_owns(conns, index, gen) && conns[index].kicked {
            let sent = http::mail_send(conns[index].address, CABLE_KICK, "");
            if sent == http::FULL { break; }
            // A live exchange's address always takes mail: this one ended.
            if sent != http::SENT { cable_leave(shard, conns, targets, storage, index, gen); }
            else { conns[index].kicked = false; conns[index].mailed = true; shard.flying++; }
        }
        k += 2;
    }
    let rest = shard.listed - k;
    for i in rest { shard.kicks[i] = shard.kicks[k+i]; }
    shard.listed = rest;
}

// A connection's kick arrived.
fn cable_kicked(shard: CableShard&, conns: CableLocal[>..]&, index: i64, gen: i64) {
    if cable_owns(conns, index, gen) && conns[index].mailed { conns[index].mailed = false; shard.flying--; }
}

// Checks one connection's address per call, in turn: a connection whose exchange ended unseen leaves.
fn cable_probe(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&) {
    guard conns.len > 0 else { return; }
    shard.probe = (shard.probe + 1) % conns.len;
    let index = shard.probe;
    if conns[index].live && !http::mail_live(conns[index].address) { cable_leave(shard, conns, targets, storage, index, conns[index].gen); }
}

// Writes the connection's next batch once its last one drained: frames in publication order from the
// shared bodies, coalesced up to CABLE_BATCH. Only a message larger than that is fragmented.
fn cable_service(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&, index: i64, out: http::Reply) {
    let w = shard.window;
    let c .= conns[index];
    guard c.live && c.ready && out.stream.open else { return; }
    c.sequence = max(c.sequence, shard.done); c.credited = max(c.credited, shard.done);
    // The drained batch's final messages keep their publications until now.
    while c.credited < c.sequence {
        let at = index*w + (c.credited & (w-1));
        if targets[at] & CABLE_ENROLLED != 0 { shard.entries[c.credited & (w-1)].remaining--; targets[at] = 0; }
        c.credited++;
    }
    while c.sequence < shard.next {
        let at = index*w + (c.sequence & (w-1));
        if targets[at] & 65535 != 0 { break; }
        if targets[at] & CABLE_ENROLLED != 0 { shard.entries[c.sequence & (w-1)].remaining--; targets[at] = 0; }
        c.sequence++; c.credited = c.sequence; c.offset = 0;
    }
    var wire: i64 = 0;
    while c.sequence < shard.next {
        let slot = c.sequence & (w-1);
        let mask = targets[index*w+slot];
        if mask & 65535 == 0 { c.sequence++; c.offset = 0; continue; }
        var subscription: i64 = 0;
        while mask & (1 << subscription) == 0 { subscription++; }
        let sub .= c.subs[subscription];
        let prefix = sub.prefix;
        let entry = shard.entries[slot];
        let length = prefix.len + entry.length + 1;
        let room = CABLE_BATCH - wire - 4;
        if wire > 0 && length - c.offset > room { break; }
        let end = min(length, c.offset + room);
        let whole = end == length;
        let size = end - c.offset;
        var frame: u8[..4] = [];
        frame.push(((if c.offset == 0 { 1 } else { 0 }) | (if whole { 128 } else { 0 })) as! u8);
        if size < 126 { frame.push(size as! u8); }
        else { frame.push(126); frame.push((size >> 8) as! u8); frame.push(size as! u8); }
        http::send(out, frame);
        if c.offset < prefix.len { http::send(out, prefix[c.offset..min(end, prefix.len)]); }
        let start = max(c.offset, prefix.len) - prefix.len;
        let stop = min(end, prefix.len + entry.length) - prefix.len;
        if start < stop { assert(http::send_shared(out, entry.body, start, stop)); }
        wire += frame.len + size;
        if !whole { c.offset = end; break; }
        http::send(out, "}");
        targets[index*w+slot] = mask & ~(1 << subscription);
        if sub.retiring { storage.free_slice(sub.identifier); storage.free_slice(sub.prefix); sub.retiring = false; }
        c.offset = 0;
    }
    if wire > 0 { http::after_drain(out); c.ready = false; }
}

fn cable_join(conns: CableLocal[>..]&, storage: u8[>..]&, index: i64, room: i64, stream: i32, identifier: const u8[:]) {
    let c .= conns[index];
    var duplicate = false;
    var slot: i64 = -1;
    var count: i64 = 0;
    for sub, i in c.subs {
        if sub.live || sub.retiring { count++; }
        if sub.live && sub.identifier == identifier { duplicate = true; }
        if !sub.live && !sub.retiring { slot = i; }
    }
    if duplicate || count >= 16 { return; }
    let id = storage.alloc_slice(identifier.len); copy_into(id, identifier);
    var encoded: u8[>..] = [];
    encoded.append("{\"identifier\":"); json::format_string(encoded, identifier); encoded.append(",\"message\":");
    let prefix = storage.alloc_slice(encoded.len); copy_into(prefix, encoded);
    c.subs[slot] = CableSubscriber { live: true, room: room, stream: stream, identifier: id, prefix: prefix, .. };
    c.mask |= 1 << slot;
}

// Cancels a subscription's unsent deliveries; an already-started WebSocket message finishes before its
// identifier can be reused.
fn cable_unsubscribe(shard: const CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&, index: i64, identifier: const u8[:]) {
    let w = shard.window;
    let c .= conns[index];
    for &sub, si in c.subs {
        if sub.live && sub.identifier == identifier {
            let current = c.sequence & (w-1);
            let mask = targets[index*w+current];
            let partial = c.offset != 0 && (mask & (1 << si)) != 0 && (mask & ((1 << si)-1)) == 0;
            sub.live = false; sub.retiring = partial;
            c.mask &= ~(1 << si);
            if !partial { storage.free_slice(sub.identifier); storage.free_slice(sub.prefix); }
            for &target, slot in targets[index*w..(index+1)*w] {
                if !partial || slot != current { target &= ~(1 << si); }
            }
        }
    }
}

fn cable_string(node: json::Node?, name: const u8[:]) -> const u8[:] {
    let value, ok = json::as_string(json::member(node, name)); return value;
}

fn cable_decode(encoded: const u8[:]) -> u8[] {
    var decoded: u8[>..] = [];
    if !base64::decode(decoded, encoded) { return []; }
    return decoded;
}

fn cable_subscribe(db, user: i64, identifier: const u8[:], key: const u8[:]) -> bool, i64, i32 {
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let params, error = json::parse(identifier, nodes, strings);
    guard error.len == 0 else { return false, 0, 0; }
    let channel = cable_string(params, "channel");
    if channel == "RoomMessagesChannel" || channel == "Turbo::StreamsChannel" {
        let signed = cable_string(params, "signed_stream_name");
        let split = find(signed, "--");
        guard split > 0 else { return false, 0, 0; }
        let decoded = cable_decode(signed[..split]); guard decoded.len > 0 else { return false, 0, 0; }
        var values: json::Node[>..] = []; var text: u8[>..] = [];
        let value, bad = json::parse(decoded, values, text);
        let name, valid = json::as_string(value);
        guard bad.len == 0 && valid && signed_stream(name, key) == signed else { return false, 0, 0; }
        if channel == "Turbo::StreamsChannel" {
            return name == "rooms" || name == str(gid_param("User",user),":rooms"), 0, if name=="rooms" { 2 } else { 5 };
        }
        guard ends_with(name, ":messages") else { return false, 0, 0; }
        let rows = sql_rows(db, "SELECT r.id,r.type FROM rooms r JOIN memberships m ON m.room_id=r.id JOIN users u ON u.id=m.user_id WHERE m.user_id=? AND u.status=0", [sql_text(user)]);
        for row in rows {
            var id: i64 = 0;
            for cell, i in row { if i == 0 { let n, ok = parse_int(cell); id = n; } else if i == 1 && name == str(gid_param(cell,id),":messages") { return true, id, 1; } }
        }
        return false, 0, 0;
    }
    if channel == "PresenceChannel" || channel == "RoomChannel" || channel == "TypingNotificationsChannel" {
        let n, valid = json::as_i64(json::member(params,"room_id"));
        var room = n as i64;
        if !valid { let id, ok = parse_int(cable_string(params,"room_id")); room = id; }
        let member = sql_number(db,"SELECT count(*) FROM memberships WHERE user_id=? AND room_id=?",[sql_text(user),sql_text(room)]) > 0;
        return member, room, if channel == "PresenceChannel" { 3 } else { 4 };
    }
    return channel == "HeartbeatChannel" || channel == "ReadRoomsChannel" || channel == "UnreadRoomsChannel", 0, 4;
}

fn presence_change(db: sqlite::Db, user: i64, room: i64, mode: i32) -> bool {
    var now: u8[>..]=[]; var cutoff: u8[>..]=[]; campfire_sql_now(now); campfire_disconnected_before(cutoff);
    campfire_writer_enter();
    let failed=sqlite::run() {
        if mode==0 {sql_rows(db,"UPDATE memberships SET connections=CASE WHEN connected_at>=? THEN connections+1 ELSE 1 END,connected_at=?,unread_at=NULL,updated_at=? WHERE user_id=? AND room_id=?",[sql_text(cutoff),sql_text(now),sql_text(now),sql_text(user),sql_text(room)]);}
        else if mode==1 {sql_rows(db,"UPDATE memberships SET connections=CASE WHEN connected_at>=? THEN connections ELSE 1 END,connected_at=?,updated_at=? WHERE user_id=? AND room_id=?",[sql_text(cutoff),sql_text(now),sql_text(now),sql_text(user),sql_text(room)]);}
        else {sql_rows(db,"UPDATE memberships SET connected_at=CASE WHEN connections>1 AND connected_at>=? THEN connected_at ELSE NULL END,connections=MAX(connections-1,0),updated_at=? WHERE user_id=? AND room_id=?",[sql_text(cutoff),sql_text(now),sql_text(user),sql_text(room)]);}
    };
    campfire_writer_leave(); return failed.len==0;
}

fn cable_message(db: sqlite::Db, user: i64, key: const u8[:], data: const u8[:], presence: i64[:],
                 shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&, index: i64, gen: i64, out: http::Reply) {
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let root, error = json::parse(data, nodes, strings);
    if error.len > 0 { return; }
    let command = cable_string(root, "command"); let identifier = cable_string(root, "identifier");
    if identifier.len == 0 || identifier.len > 2048 { return; }
    var params_nodes: json::Node[>..]=[]; var params_strings: u8[>..]=[];
    let params,bad_params=json::parse(identifier,params_nodes,params_strings);
    let presence_channel=cable_string(params,"channel")=="PresenceChannel";
    let presence_room=signed_integer(json::member(params,"room_id"));
    http::later(out, 3000);
    let owned = cable_owns(conns, index, gen);
    if command == "unsubscribe" {
        if presence_channel {for &room in presence {if room==presence_room {presence_change(db,user,room,2);room=0;}}}
        if owned { cable_unsubscribe(shard,conns,targets,storage,index,identifier); }
        return;
    }
    if command=="message" && presence_channel {
        var action_nodes: json::Node[>..]=[]; var action_strings: u8[>..]=[];
        let info,error=json::parse(cable_string(root,"data"),action_nodes,action_strings);
        let action=cable_string(info,"action");
        if action!="absent" && action!="present" && action!="refresh" {return;}
        for room in presence {if room==presence_room && room>0 {presence_change(db,user,room,if action=="absent" {2} else if action=="present" {0} else {1});}}
        return;
    }
    if command != "subscribe" { return; }
    var accepted = false; var room: i64 = 0; var stream: i32 = 0;
    let failed = sqlite::run() { let yes, r, s = cable_subscribe(db,user,identifier,key); accepted=yes; room=r; stream=s; };
    accepted = accepted && failed.len == 0;
    if accepted && presence_channel {
        var exists=false; var slot: i64=-1;
        for value,i in presence {if value==room {exists=true;} if value==0 {slot=i;}}
        if !exists {
            accepted=slot>=0 && presence_change(db,user,room,0);
            if accepted {presence[slot]=room;}
        }
    }
    // The worker snapshots its subscriptions as each publication arrives: this one takes those after now.
    accepted = accepted && owned;
    if accepted { cable_join(conns,storage,index,room,stream,identifier); }
    var response: u8[>..] = []; response.append("{\"identifier\":"); json::format_string(response,identifier);
    response.append(if accepted { ",\"type\":\"confirm_subscription\"}" } else { ",\"type\":\"reject_subscription\"}" });
    http::ws_send(out,http::WS_TEXT,response); http::after_drain(out);
}
