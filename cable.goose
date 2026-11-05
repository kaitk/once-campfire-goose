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

extern fn campfire_clock_ms() -> i64;
extern fn campfire_access_note(kind: i64, user: i64, room: i64);
extern fn campfire_access_epoch() -> i64;
extern fn campfire_access_field(index: i64, field: i64) -> i64;

struct CablePermit { value: bool = true }
// notice, when not 0, is the message's creation in epoch ms: the publication also carries the room's unread
// notice, for the UnreadRoomsChannel subscriptions of the room's members.
struct Publication { room: i64, reply: http::MailAddress, body: u8[], notice: i64 = 0 }
// A transient event, typing or a read room: delivered at most once to each connection that holds a matching
// subscription when it arrives, outside the publication window, and dropped rather than queued for a slow one.
// key is a room's id * 4 + CABLE_TYPED, or a user's * 4 + CABLE_READ.
struct CableTransientEvent { key: i64, body: u8[] }
// A report to the broker: its kind, the reporting worker's address, and a publication sequence.
struct CableCommand { kind: i32, address: http::MailAddress, value: i64 = 0 }
let CABLE_WINDOW: i64 = 8;
// Every enrolled connection of the worker drained or left the publications before value.
let CABLE_CREDIT: i32 = 2;
// The worker has no cable connection left: the publications before value are credited, and later ones skip it.
let CABLE_EMPTY: i32 = 3;
let CABLE_PUBLISH: i32 = 5;
// The worker has cable connections again: its publications go to this address from sequence value.
let CABLE_REP: i32 = 6;
// The access log moved: the broker nudges every worker with connections to apply it.
let CABLE_ACCESS: i32 = 7;
// A transient event waits in its queue.
let CABLE_TRANSIENT: i32 = 8;
let CABLE_ACK: i32 = 256;
// Mail to a worker's address: records of publications for the worker to deliver.
let CABLE_PUBS: i32 = 257;
// A wake a worker gives one of its own connections, so that its loop calls it to write.
let CABLE_KICK: i32 = 258;
// Mail to a worker's address: one transient event, as key, shared body and its length.
let CABLE_TRANSIENT_MAIL: i32 = 259;
// Mail to a worker's address: apply the access log.
let CABLE_ACCESS_MAIL: i32 = 260;
let CABLE_ENROLLED: i32 = 65536;
// The most frame bytes one batch writes before waiting for its drain, unless CAMPFIRE_CABLE_BATCH sets it.
let CABLE_BATCH: i64 = 262144;
// The most cable connections a worker wakes per pass of its loop, unless CAMPFIRE_CABLE_PASS_READERS sets it.
let CABLE_PASS: i64 = 16;
// A publication record: sequence, room, shared body and its length. A mailbox slot holds four.
let CABLE_RECORD: i64 = 32;
let CABLE_MAIL: i64 = 128;
// A worker's ring of transient events, and the most mail a worker's box may hold for one to be sent to it,
// so that transient events never take the room publications and acknowledgements need.
let CABLE_TRANSIENTS: i64 = 64;
let CABLE_TRANSIENT_ROOM: i64 = 32;
// Transient event kinds, in a key's low two bits.
let CABLE_TYPED: i64 = 1;
let CABLE_READ: i64 = 2;
// Subscription streams past the room's messages (1), the rooms list (2), presence (3), none (4) and the
// user's rooms (5).
let CABLE_UNREADS: i32 = 6;
let CABLE_READS: i32 = 7;
let CABLE_TYPING: i32 = 8;
// Access log kinds (platform.c): a user's connections close and may reconnect, as Rails'
// reset_remote_connections; they close for good, as close_remote_connections; a user, or 0 for every user,
// gained a room; every connection closes and may reconnect, as at Action Cable's server restart (shutdown.goose).
let ACCESS_RESET: i64 = 1;
let ACCESS_CLOSE: i64 = 2;
let ACCESS_GRANT: i64 = 3;
let ACCESS_RESTART: i64 = 4;
let CABLE_ACCESS_LOG: i64 = 4096;
// A connection's revocation: by the access log (ACCESS_RESET or ACCESS_CLOSE), or its session is gone.
let CABLE_UNAUTHORIZED: i32 = 3;
// Typing events a connection may send at once, and the ms that return one.
let CABLE_TYPING_BURST: i64 = 5;
let CABLE_TYPING_MS: i64 = 200;
// A publication's room at or below this is CABLE_MEMBERS - room: every member of that room on their own rooms stream.
let CABLE_MEMBERS: i64 = -(1 << 40);

fn cable_command(kind: i32, address: http::MailAddress, value: i64 = 0) {
    qput(CableCommand { kind: kind, address: address, value: value });
}

// Reports the broker must not lose. They are rare, one per worker per publication, so a full queue only delays one.
fn cable_tell(kind: i32, address: http::MailAddress, value: i64) {
    while !qput(CableCommand { kind: kind, address: address, value: value }) { sleep_ms(1); }
}

fn publish(room: i64, reply: http::MailAddress, body: const u8[:], notice: i64 = 0) {
    // Each publication owns one permit until final delivery, including queued acknowledgements.
    assert(qput(Publication { room: room, reply: reply, body: sql_text(body), notice: notice }));
    cable_command(CABLE_PUBLISH, reply);
}

// Records an access change once it committed, under writer admission so that the log keeps commit order, and
// nudges the workers. Each cable worker applies it before it enrolls any later publication.
fn cable_revoke(user: i64, reconnect: bool) {
    campfire_access_note(if reconnect { ACCESS_RESET } else { ACCESS_CLOSE }, user, 0);
    cable_command(CABLE_ACCESS, http::MailAddress { .. });
}
fn cable_grant(user: i64, room: i64) {
    campfire_access_note(ACCESS_GRANT, user, room);
    cable_command(CABLE_ACCESS, http::MailAddress { .. });
}

// Records the access changes a transaction made, as triples of kind, user and room, once it committed and
// still under writer admission (write_access_transaction), and nudges the workers.
fn cable_note(changes: const i64[:]) {
    guard changes.len > 0 else { return; }
    for i in changes.len / 3 { campfire_access_note(changes[3*i], changes[3*i+1], changes[3*i+2]); }
    cable_command(CABLE_ACCESS, http::MailAddress { .. });
}

// Queues a transient event. A full queue drops it: typing and read notices never wait for room, nor take a
// publication permit or window slot, so they cannot hold back a message.
fn cable_transient(key: i64, body: const u8[:]) {
    if qput(CableTransientEvent { key: key, body: sql_text(body) }) { cable_command(CABLE_TRANSIENT, http::MailAddress { .. }); }
}

// Epoch ms as Ruby's Time#to_f prints it, to the ms.
fn cable_seconds(out: u8[>..]&, ms: i64) {
    format(out, ms / 1000, ".");
    let rest = ms % 1000;
    if rest < 100 { out.push('0'); }
    if rest < 10 { out.push('0'); }
    format(out, rest);
}

fn cable_put(out: u8[>..]&, value: i64) {
    for i in 8 { out.push((value >> (8*i)) as! u8); }
}

// The broker's view of one worker: its address, and how far its publications were sent and credited.
// A live worker is enrolled in every publication from credited to the tail.
struct CableLink {
    rep: http::MailAddress = http::MailAddress { .. },
    live: bool = false,
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
        if command.kind == CABLE_PUBLISH || command.kind == CABLE_TRANSIENT { return; }
        if command.kind == CABLE_ACCESS {
            // A full box only delays it: each worker also applies the log before it enrolls a publication.
            for link in links { if link.live { http::mail_send(link.rep, CABLE_ACCESS_MAIL, ""); } }
            return;
        }
        var index: i64 = -1;
        for &link, i in links { if link.rep.box == command.address.box { index = i; break; } }
        if command.kind == CABLE_REP {
            if index < 0 { index = links.len; links.push(CableLink { .. }); }
            let link .= links[index];
            // A worker that had no connection enrolls in later publications only.
            if !link.live { link.live = true; link.credited = tail; link.sent = tail; }
            link.rep = command.address;
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
        // Transient events go to each worker with connections whose box has room to spare, or are dropped there.
        for _ in 0..64 {
            let event, exists = qpoll<CableTransientEvent>();
            if !exists { break; }
            var live: i64 = 0;
            for link in links { if link.live { live++; } }
            if live == 0 { continue; }
            let shared, failed = http::shared_put(event.body, live);
            if failed != 0 { continue; }
            mail.clear(); cable_put(mail, event.key); cable_put(mail, shared.h); cable_put(mail, event.body.len);
            for link in links {
                if !link.live { continue; }
                let queued = http::mail_queued(link.rep);
                if queued < 0 || queued >= CABLE_TRANSIENT_ROOM || http::mail_send(link.rep, CABLE_TRANSIENT_MAIL, mail) != http::SENT {
                    http::shared_release(shared);
                }
            }
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
                    let length = body.len;
                    // The unread notice follows the message in the same body; the length's top 16 bits are its own.
                    if pending.notice > 0 {
                        format(body, "{\"roomId\":", pending.room, ",\"at\":"); cable_seconds(body, pending.notice); body.push('}');
                    }
                    let shared, failed = http::shared_put(body, 1);
                    assert(failed == 0);
                    entry.body = shared; entry.length = length | ((body.len - length) << 48);
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
                while link.live && link.sent < tail {
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
                    // The worker's loop ended.
                    else { credit(link, tail); link.live = false; }
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
    // Listed for a kick, or given one that has not arrived.
    kicked: bool = false,
    // Given a kick of the current pass that has not arrived, when shard.pass caps them.
    woken: bool = false,
    // The next publication to write, and the bytes of its current message already written.
    sequence: i64 = 0, offset: i64 = 0,
    // Publications before credited are released; those from credited to sequence wait on a drain.
    credited: i64 = 0,
    // When the connection last wrote, and whether it holds a paced batch back until its timer.
    wrote_ms: i64 = 0, paced: bool = false,
    // The live subscriptions, by slot.
    mask: i32 = 0,
    subs: CableSubscriber[16] = [CableSubscriber { .. }; 16],
    // The access log's epoch before the connection authenticated: earlier entries were in force already.
    epoch: i64 = 0,
    // Revoked (CABLE_UNAUTHORIZED or an access kind): it holds no subscription, and its exchange closes it.
    revoked: i32 = 0,
    // The next transient event to consider.
    transient: i64 = 0,
}
// A publication the worker holds: its readers share body, which the broker keeps until the worker credits it.
// body holds length bytes of the message, then notice bytes of the room's unread notice, if any.
struct CableEntry { room: i64 = 0, body: http::Shared = http::Shared { .. }, length: i64 = 0, notice: i64 = 0, remaining: i64 = 0 }
// A transient event the worker holds, until a later one takes its place in the ring.
struct CableTransient { key: i64 = 0, body: http::Shared = http::Shared { .. }, length: i64 = 0 }
// One worker's cable state. Publications arrive in sequence; entries[sequence & (window-1)] holds each until
// every connection of the worker enrolled in it drained or left. Subscriptions are snapshotted when the
// worker receives a publication: later subscribers do not inherit it.
struct CableShard {
    window: i64 = 8,
    // The most frame bytes one batch writes.
    batch: i64 = 262144,
    // Under load, a connection writes at most once per pace ms unless pace_frames publications wait; 0 is off.
    pace: i64 = 0, pace_frames: i64 = 16,
    // The next sequence expected, the first not done by every enrolled connection, and the last credit reported.
    next: i64 = 0, done: i64 = 0, reported: i64 = 0,
    // The live connections.
    count: i64 = 0, gens: i64 = 0, probe: i64 = 0,
    // The worker's address, which takes its publications.
    box: http::MailAddress = http::MailAddress { .. },
    entries: CableEntry[512] = [CableEntry { .. }; 512],
    // The most connections one pump wakes, or 0 for all, and those it woke whose kick has not arrived.
    pass: i64 = 0, woken: i64 = 0,
    // The access log entries applied.
    epoch: i64 = 0,
    // The ring of transient events, and the next one's number.
    transients: CableTransient[64] = [CableTransient { .. }; 64],
    transient: i64 = 0,
    // Connections to kick, as pairs of index and generation: kicks[first..listed]. It never shrinks.
    first: i64 = 0, listed: i64 = 0,
    kicks: i64[>..] = [],
}

fn cable_owns(conns: const CableLocal[:], index: i64, gen: i64) -> bool {
    return index >= 0 && index < conns.len && conns[index].live && conns[index].gen == gen;
}

fn cable_matches(sub: const CableSubscriber&, user: i64, room: i64, members: const i64[:]) -> bool {
    if room <= CABLE_MEMBERS {
        if !sub.live || sub.stream != 5 { return false; }
        for member in members { if member == user { return true; } }
        return false;
    }
    return sub.live && (if room==0 { sub.stream==2 } else if room<0 { sub.stream==5 && user == -room } else { sub.stream==1 && sub.room==room });
}

fn cable_transient_matches(sub: const CableSubscriber&, user: i64, key: i64) -> bool {
    let id = key >> 2;
    return sub.live && (if key & 3 == CABLE_TYPED { sub.stream == CABLE_TYPING && sub.room == id } else { sub.stream == CABLE_READS && user == id });
}

// The rooms of each user with an UnreadRoomsChannel subscription on this worker, for its unread notices:
// pairs[..2*used], sorted by user, then room. Each user's first pair is (user, -subscriptions), then one per
// room. Loaded at subscription; the access log keeps them current. Each worker thread has its own. It never
// shrinks: what it no longer uses stays for reuse.
struct CableRooms { used: i64 = 0, pairs: i64[>..] = [] }
var cable_rooms = CableRooms { .. };

// The first pair not below (user, room).
fn cable_room_at(user: i64, room: i64) -> i64 {
    let pairs .= cable_rooms.pairs;
    var lo: i64 = 0;
    var hi = cable_rooms.used;
    while lo < hi {
        let mid = (lo + hi) / 2;
        if pairs[2*mid] < user || pairs[2*mid] == user && pairs[2*mid+1] < room { lo = mid + 1; } else { hi = mid; }
    }
    return lo;
}

fn cable_member(user: i64, room: i64) -> bool {
    let at = cable_room_at(user, room);
    return at < cable_rooms.used && cable_rooms.pairs[2*at] == user && cable_rooms.pairs[2*at+1] == room;
}

fn cable_member_add(user: i64, room: i64) {
    let at = cable_room_at(user, room);
    if at < cable_rooms.used && cable_rooms.pairs[2*at] == user && cable_rooms.pairs[2*at+1] == room { return; }
    if 2*cable_rooms.used == cable_rooms.pairs.len { cable_rooms.pairs.push(0); cable_rooms.pairs.push(0); }
    cable_rooms.used++;
    var i = 2*cable_rooms.used - 1;
    while i > 2*at + 1 { cable_rooms.pairs[i] = cable_rooms.pairs[i-2]; i--; }
    cable_rooms.pairs[2*at] = user; cable_rooms.pairs[2*at+1] = room;
}

// The index of user's first pair's subscription count, or -1 when its rooms are not here.
fn cable_cached(user: i64) -> i64 {
    let at = cable_room_at(user, -(1 << 62));
    return if at < cable_rooms.used && cable_rooms.pairs[2*at] == user && cable_rooms.pairs[2*at+1] <= 0 { 2*at+1 } else { -1 };
}

// The users whose rooms are here.
fn cable_cached_users() -> i64[>..] {
    var users: i64[>..] = [];
    for i in cable_rooms.used { if cable_rooms.pairs[2*i+1] <= 0 { users.push(cable_rooms.pairs[2*i]); } }
    return users;
}

// Forgets user's rooms, as when the user lost access.
fn cable_member_drop(user: i64) {
    let first = cable_room_at(user, -(1 << 62));
    var end = first;
    while end < cable_rooms.used && cable_rooms.pairs[2*end] == user { end++; }
    let n = end - first;
    if n > 0 {
        for i in 2*first..2*(cable_rooms.used - n) { cable_rooms.pairs[i] = cable_rooms.pairs[i + 2*n]; }
        cable_rooms.used -= n;
    }
}

// An UnreadRoomsChannel subscription of user's ended.
fn cable_member_release(user: i64) {
    let at = cable_cached(user);
    guard at >= 0 else { return; }
    cable_rooms.pairs[at]++;
    if cable_rooms.pairs[at] >= 0 { cable_member_drop(user); }
}

// The members of the room a CABLE_MEMBERS publication names, as committed when the worker receives it.
fn cable_members(db: sqlite::Db, room: i64, members: i64[>..]&) {
    members.clear();
    let failed = sqlite::run() {
        for row in sql_rows(db,"SELECT user_id FROM memberships WHERE room_id=?",[sql_text(CABLE_MEMBERS - room)]) {
            for value in row { let id, valid = parse_int(value); if valid { members.push(id); } }
        }
    };
    for e in failed { write_stderr(str("cable members lookup failed: ",e.message,"\n")); }
}

// Credits the broker with the publications every enrolled connection drained or left.
fn cable_credit(shard: CableShard&) {
    while shard.done < shard.next && shard.entries[shard.done & (shard.window-1)].remaining == 0 { shard.done++; }
    if shard.count > 0 && shard.done > shard.reported {
        shard.reported = shard.done;
        cable_tell(CABLE_CREDIT, shard.box, shard.done);
    }
}

// Adds an upgraded connection, which takes the publications its worker receives from now on.
// epoch is the access log's, read before the connection authenticated.
fn cable_open(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, address: http::MailAddress, worker: http::MailAddress,
               user: i64, epoch: i64) -> i64 {
    var index: i64 = -1;
    for &c, i in conns { if !c.live { index = i; break; } }
    if index < 0 {
        index = conns.len;
        conns.push(CableLocal { .. });
        for _ in 0..shard.window { targets.push(0); }
    }
    shard.gens++;
    let c .= conns[index];
    c.live = true; c.gen = shard.gens; c.address = address; c.user = user; c.ready = true; c.kicked = false; c.woken = false;
    c.sequence = shard.next; c.offset = 0; c.credited = shard.next; c.mask = 0;
    c.epoch = epoch; c.revoked = 0; c.transient = shard.transient; c.paced = false;
    shard.count++;
    if shard.count == 1 { shard.box = worker; cable_tell(CABLE_REP, worker, shard.next); }
    return index;
}

// Ends every subscription of a connection that leaves or loses access.
fn cable_drop_subscriptions(shard: CableShard&, c: CableLocal&, storage: u8[>..]&) {
    for &sub in c.subs {
        if sub.live && sub.stream == CABLE_UNREADS { cable_member_release(c.user); }
        if sub.live || sub.retiring {
            storage.free_slice(sub.identifier); storage.free_slice(sub.prefix);
            sub.live = false; sub.retiring = false;
        }
    }
    c.mask = 0;
}

// Revokes a connection: it is enrolled in nothing more, its unsent deliveries are cancelled, and its exchange,
// woken unless it is the caller, sends Action Cable's disconnect and closes. The broker's credits follow.
fn cable_revoke_connection(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&, index: i64, kind: i32, wake: bool) {
    let w = shard.window;
    guard conns[index].live && conns[index].revoked == 0 else { return; }
    for &target, slot in targets[index*w..(index+1)*w] {
        if target & CABLE_ENROLLED != 0 { shard.entries[slot].remaining--; }
        target = 0;
    }
    cable_drop_subscriptions(shard, conns[index], storage);
    conns[index].revoked = kind;
    conns[index].sequence = shard.next; conns[index].credited = shard.next;
    if wake && http::wake(conns[index].address, CABLE_KICK) != http::SENT { cable_leave(shard, conns, targets, storage, index, conns[index].gen); }
}

// Applies the access log entries the worker has not: revoked users' connections from before the entry close,
// and granted rooms join the cached rooms of their users. A worker that fell a whole log behind resets every
// connection, whose clients then subscribe afresh. One atomic load when nothing changed.
fn cable_access(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&) {
    var epoch = campfire_access_epoch();
    guard epoch != shard.epoch else { return; }
    while shard.epoch < epoch {
        let e = shard.epoch;
        let kind = campfire_access_field(e, 0);
        let user = campfire_access_field(e, 1);
        let room = campfire_access_field(e, 2);
        if kind < 0 || user < 0 || room < 0 || campfire_access_epoch() - e > CABLE_ACCESS_LOG {
            epoch = campfire_access_epoch();
            for i in conns.len { cable_revoke_connection(shard, conns, targets, storage, i, ACCESS_RESET as! i32, true); }
            cable_rooms.used = 0;
            shard.epoch = epoch;
            break;
        }
        if kind == ACCESS_GRANT {
            for cached in cable_cached_users() { if user == 0 || cached == user { cable_member_add(cached, room); } }
        } else if kind == ACCESS_RESTART {
            // Every connection, whenever it opened: none opens once the server stops.
            for i in conns.len { cable_revoke_connection(shard, conns, targets, storage, i, ACCESS_RESTART as! i32, true); }
        } else {
            // The rooms cached for the user may include those it lost; the next subscription loads them again.
            cable_member_drop(user);
            for i in conns.len {
                if conns[i].user == user && conns[i].epoch <= e { cable_revoke_connection(shard, conns, targets, storage, i, kind as! i32, true); }
            }
        }
        shard.epoch++;
    }
    cable_credit(shard);
}

// Action Cable's disconnect message: for a connection refused at the start, one whose session is gone (on
// the heartbeat, as Rails' check_session), or one the access log revoked, which reconnects unless closed for good;
// at a shutdown, ActionCable::Server::Base#restart's.
fn cable_disconnect_message(kind: i32, connected: bool) -> const u8[:] {
    if kind == ACCESS_RESTART as! i32 { return "{\"type\":\"disconnect\",\"reason\":\"server_restart\",\"reconnect\":true}"; }
    if !connected { return "{\"type\":\"disconnect\",\"reason\":\"unauthorized\",\"reconnect\":false}"; }
    if kind == CABLE_UNAUTHORIZED { return "{\"type\":\"disconnect\",\"reason\":\"unauthorized\",\"reconnect\":true}"; }
    if kind == ACCESS_CLOSE { return "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":false}"; }
    return "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":true}";
}

// The active user whose session token this is, or 0.
fn cable_session_user(db: sqlite::Db, token: const u8[:]) -> i64 {
    var user: i64 = 0;
    let failed = sqlite::run() {
        user = sql_number(db, "SELECT u.id FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token=? AND u.status=0", [sql_text(token)]);
    };
    return if failed.len == 0 { user } else { -1 };
}

// Removes a connection that closed: its unsent deliveries are cancelled and their publications credited.
fn cable_leave(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&, index: i64, gen: i64) {
    guard cable_owns(conns, index, gen) else { return; }
    let w = shard.window;
    let c .= conns[index];
    c.live = false; c.mask = 0;
    // Its kick will not arrive, so it must not hold back the next pass.
    if c.woken { c.woken = false; shard.woken--; }
    for &target, slot in targets[index*w..(index+1)*w] {
        if target & CABLE_ENROLLED != 0 { shard.entries[slot].remaining--; }
        target = 0;
    }
    cable_drop_subscriptions(shard, c, storage);
    shard.count--;
    if shard.count == 0 {
        // With no connection left, every publication the worker holds is done.
        shard.done = shard.next; shard.reported = shard.next;
        cable_tell(CABLE_EMPTY, shard.box, shard.next);
    }
    cable_credit(shard);
}

// Enrolls the worker's matching subscriptions in each publication of a broker mail, and lists the ready
// readers for a kick.
fn cable_receive(db: sqlite::Db, shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&, data: const u8[:]) {
    // Every access change logged before these publications were queued applies to them.
    cable_access(shard, conns, targets, storage);
    let w = shard.window;
    var at: i64 = 0;
    var members: i64[>..] = [];
    while at + CABLE_RECORD <= data.len {
        let sequence = cable_le(data, at, 8);
        let room = cable_le(data, at+8, 8);
        let body = http::Shared { h: cable_le(data, at+16, 8) };
        let packed = cable_le(data, at+24, 8);
        let length = packed & ((1 << 48) - 1);
        let notice = packed >> 48;
        at += CABLE_RECORD;
        if sequence > shard.next {
            // The broker enrolled the worker afresh, after it had no connection: it skips what it was never sent.
            if shard.done == shard.next { shard.done = sequence; }
            else { for k in shard.next..sequence { shard.entries[k & (w-1)] = CableEntry { .. }; } }
            shard.next = sequence;
        }
        let slot = sequence & (w-1);
        var enrolled: i64 = 0;
        if room <= CABLE_MEMBERS { cable_members(db,room,members); }
        for &c, ci in conns {
            var mask: i32 = 0;
            if c.live {
                var live = c.mask;
                var si: i64 = 0;
                // Whether the room is the user's, asked once per connection that subscribes to unread notices.
                var member: i32 = if notice > 0 && room > 0 { -1 } else { 0 };
                while live != 0 {
                    if live & 1 != 0 {
                        let sub .= c.subs[si];
                        if cable_matches(sub, c.user, room, members) { mask |= 1 << si; }
                        else if member != 0 && sub.stream == CABLE_UNREADS {
                            if member < 0 { member = if cable_member(c.user, room) { 1 } else { 0 }; }
                            if member > 0 { mask |= 1 << si; }
                        }
                    }
                    live >>= 1; si++;
                }
            }
            if mask != 0 {
                mask |= CABLE_ENROLLED; enrolled++;
                if c.ready && !c.kicked && !c.paced { c.kicked = true; cable_list(shard, ci); cable_list(shard, c.gen); }
            }
            targets[ci*w+slot] = mask;
        }
        shard.entries[slot] = CableEntry { room: room, body: body, length: length, notice: notice, remaining: enrolled };
        shard.next = sequence + 1;
    }
}

// Takes a transient event into the ring, in place of the oldest, and lists the ready connections it matches
// for a kick. Those not ready take it when they next write, unless the ring passed it.
fn cable_receive_transient(shard: CableShard&, conns: CableLocal[>..]&, data: const u8[:]) {
    guard data.len >= 24 else { return; }
    let key = cable_le(data, 0, 8);
    let body = http::Shared { h: cable_le(data, 8, 8) };
    let length = cable_le(data, 16, 8);
    let t .= shard.transients[shard.transient & (CABLE_TRANSIENTS-1)];
    if t.body.h != 0 { http::shared_release(t.body); }
    t.key = key; t.body = body; t.length = length;
    shard.transient++;
    for &c, ci in conns {
        if !c.live || c.revoked != 0 || !c.ready || c.kicked || c.paced { continue; }
        var live = c.mask;
        var si: i64 = 0;
        var matched = false;
        while live != 0 && !matched {
            if live & 1 != 0 && cable_transient_matches(c.subs[si], c.user, key) { matched = true; }
            live >>= 1; si++;
        }
        if matched { c.kicked = true; cable_list(shard, ci); cable_list(shard, c.gen); }
    }
}

fn cable_list(shard: CableShard&, value: i64) {
    if shard.listed < shard.kicks.len { shard.kicks[shard.listed] = value; } else { shard.kicks.push(value); }
    shard.listed++;
}

// Wakes the listed connections in order. With shard.pass set, it wakes that many at most, and the rest only
// once every one it woke was serviced or left: the loop delivers kicks asked for while it delivers others on
// its next call, so it writes shard.pass connections at a time and polls for requests in between. A kick it
// sent always ends in a call (the WAKE, or an earlier event) or a leave, so the next pass is never lost.
fn cable_pump(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&) {
    guard shard.woken == 0 else { return; }
    var k = shard.first;
    var sent: i64 = 0;
    while k < shard.listed && (shard.pass == 0 || sent < shard.pass) {
        let index = shard.kicks[k];
        let gen = shard.kicks[k+1];
        k += 2;
        if cable_owns(conns, index, gen) && conns[index].kicked {
            // A live exchange always takes a wake: this one ended.
            if http::wake(conns[index].address, CABLE_KICK) != http::SENT { cable_leave(shard, conns, targets, storage, index, gen); }
            else if shard.pass > 0 { conns[index].woken = true; shard.woken++; sent++; }
        }
    }
    shard.first = k;
    if shard.first == shard.listed { shard.first = 0; shard.listed = 0; }
    else if shard.first * 2 >= shard.listed {
        let rest = shard.listed - shard.first;
        for i in rest { shard.kicks[i] = shard.kicks[shard.first+i]; }
        shard.first = 0; shard.listed = rest;
    }
}

// A connection's loop called it: a kick of the current pass arrived, or no longer needs to.
fn cable_arrived(shard: CableShard&, c: CableLocal&) {
    c.kicked = false;
    if c.woken { c.woken = false; shard.woken--; }
}

// Checks one connection's address per call, in turn: a connection whose exchange ended unseen leaves.
fn cable_probe(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&) {
    guard conns.len > 0 else { return; }
    shard.probe = (shard.probe + 1) % conns.len;
    let index = shard.probe;
    if conns[index].live && !http::mail_live(conns[index].address) { cable_leave(shard, conns, targets, storage, index, conns[index].gen); }
}

// Writes a WebSocket text frame's header, of the first or a continuation frame, and returns the frame's size.
inline fn cable_frame(out: http::Reply, size: i64, first: bool, whole: bool) -> i64 {
    var frame: u8[..10] = [];
    frame.push(((if first { 1 } else { 0 }) | (if whole { 128 } else { 0 })) as! u8);
    if size < 126 { frame.push(size as! u8); }
    else if size < 65536 { frame.push(126); frame.push((size >> 8) as! u8); frame.push(size as! u8); }
    else { frame.push(127); for i in 8 { frame.push((size >> (8*(7-i))) as! u8); } }
    http::send(out, frame);
    return frame.len + size;
}

// Writes the connection's next batch once its last one drained: frames in publication order from the
// shared bodies, coalesced up to shard.batch. Only a message larger than that is fragmented. Returns the ms
// to wait before writing a batch that pacing holds back, or 0.
fn cable_service(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&, index: i64, out: http::Reply) -> i64 {
    let w = shard.window;
    let c .= conns[index];
    guard c.live && c.revoked == 0 && c.ready && out.stream.open else { return 0; }
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
    // A connection that wrote within the last pace ms waits for its timer, unless enough publications wait.
    if shard.pace > 0 && c.sequence < shard.next {
        let now = campfire_clock_ms();
        let due = c.wrote_ms + shard.pace - now;
        if due > 0 && shard.next - c.sequence < shard.pace_frames { c.paced = true; return due; }
        c.wrote_ms = now;
    }
    c.paced = false;
    var wire: i64 = 0;
    // Transient events go first, whole, between messages; a connection the ring passed loses the oldest.
    if c.offset == 0 {
        c.transient = max(c.transient, shard.transient - CABLE_TRANSIENTS);
        while c.transient < shard.transient {
            let t = shard.transients[c.transient & (CABLE_TRANSIENTS-1)];
            c.transient++;
            var live = c.mask;
            var si: i64 = 0;
            while live != 0 {
                if live & 1 != 0 && cable_transient_matches(c.subs[si], c.user, t.key) {
                    let prefix = c.subs[si].prefix;
                    wire += cable_frame(out, prefix.len + t.length + 1, true, true);
                    http::send(out, prefix);
                    if t.length > 0 { assert(http::send_shared(out, t.body, 0, t.length)); }
                    http::send(out, "}");
                }
                live >>= 1; si++;
            }
        }
    }
    while c.sequence < shard.next {
        let slot = c.sequence & (w-1);
        let mask = targets[index*w+slot];
        if mask & 65535 == 0 { c.sequence++; c.offset = 0; continue; }
        var subscription: i64 = 0;
        while mask & (1 << subscription) == 0 { subscription++; }
        let sub .= c.subs[subscription];
        let prefix = sub.prefix;
        let entry = shard.entries[slot];
        // An unread notice subscription takes the notice after the message.
        let unread = sub.stream == CABLE_UNREADS;
        let base = if unread { entry.length } else { 0 };
        let payload = if unread { entry.notice } else { entry.length };
        let length = prefix.len + payload + 1;
        // A frame's header takes 4 bytes, or 10 once its payload may reach 64 KiB.
        let room = shard.batch - wire - (if shard.batch - wire > 65539 { 10 } else { 4 });
        if wire > 0 && length - c.offset > room { break; }
        let end = min(length, c.offset + room);
        let whole = end == length;
        let size = end - c.offset;
        wire += cable_frame(out, size, c.offset == 0, whole);
        if c.offset < prefix.len { http::send(out, prefix[c.offset..min(end, prefix.len)]); }
        let start = max(c.offset, prefix.len) - prefix.len;
        let stop = min(end, prefix.len + payload) - prefix.len;
        if start < stop { assert(http::send_shared(out, entry.body, base + start, base + stop)); }
        if !whole { c.offset = end; break; }
        http::send(out, "}");
        targets[index*w+slot] = mask & ~(1 << subscription);
        if sub.retiring { storage.free_slice(sub.identifier); storage.free_slice(sub.prefix); sub.retiring = false; }
        c.offset = 0;
    }
    if wire > 0 { http::after_drain(out); c.ready = false; }
    return 0;
}

// Adds a subscription. Returns CABLE_JOINED, or CABLE_DUPLICATE for one the connection holds already, or
// CABLE_REFUSED past 16 subscriptions or once the connection was revoked.
let CABLE_REFUSED: i32 = 0;
let CABLE_JOINED: i32 = 1;
let CABLE_DUPLICATE: i32 = 2;
fn cable_join(conns: CableLocal[>..]&, storage: u8[>..]&, index: i64, room: i64, stream: i32, identifier: const u8[:]) -> i32 {
    let c .= conns[index];
    guard c.revoked == 0 else { return CABLE_REFUSED; }
    var duplicate = false;
    var slot: i64 = -1;
    var count: i64 = 0;
    for sub, i in c.subs {
        if sub.live || sub.retiring { count++; }
        if sub.live && sub.identifier == identifier { duplicate = true; }
        if !sub.live && !sub.retiring { slot = i; }
    }
    if duplicate { return CABLE_DUPLICATE; }
    if count >= 16 { return CABLE_REFUSED; }
    let id = storage.alloc_slice(identifier.len); copy_into(id, identifier);
    var encoded: u8[>..] = [];
    encoded.append("{\"identifier\":"); json::format_string(encoded, identifier); encoded.append(",\"message\":");
    let prefix = storage.alloc_slice(encoded.len); copy_into(prefix, encoded);
    c.subs[slot] = CableSubscriber { live: true, room: room, stream: stream, identifier: id, prefix: prefix, .. };
    c.mask |= 1 << slot;
    return CABLE_JOINED;
}

// Cancels a subscription's unsent deliveries; an already-started WebSocket message finishes before its
// identifier can be reused.
fn cable_unsubscribe(shard: CableShard&, conns: CableLocal[>..]&, targets: i32[>..]&, storage: u8[>..]&, index: i64, identifier: const u8[:]) {
    let w = shard.window;
    let c .= conns[index];
    for &sub, si in c.subs {
        if sub.live && sub.identifier == identifier {
            if sub.stream == CABLE_UNREADS { cable_member_release(c.user); }
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
        return member, room, if channel == "PresenceChannel" { 3 } else if channel == "TypingNotificationsChannel" { CABLE_TYPING } else { 4 };
    }
    // Both stream only the user's own notices: "user_<id>_unreads" and "user_<id>_reads".
    if channel == "UnreadRoomsChannel" { return true, 0, CABLE_UNREADS; }
    if channel == "ReadRoomsChannel" { return true, 0, CABLE_READS; }
    return channel == "HeartbeatChannel", 0, 4;
}

// PresenceChannel#broadcast_read_room: the user's ReadRoomsChannel subscriptions mark the room read.
fn cable_read_room(user: i64, room: i64) {
    var now: u8[>..] = []; campfire_sql_now(now);
    var body: u8[>..] = [];
    format(body, "{\"room_id\":", room, ",\"at\":"); cable_seconds(body, campfire_epoch_ms(now)); body.push('}');
    cable_transient(user * 4 + CABLE_READ, body);
}

// TypingNotificationsChannel#start and #stop: broadcast_to the room, action and the user's id and name. A
// connection sends at most CABLE_TYPING_BURST at once and one per CABLE_TYPING_MS after; the rest are dropped.
// typing[0] is when its next one is due, as a generic cell rate algorithm keeps it.
fn cable_typing(db: sqlite::Db, user: i64, room: i64, action: const u8[:], typing: i64[:]) {
    let now = campfire_clock_ms();
    let due = max(typing[0], now);
    guard due - now <= (CABLE_TYPING_BURST - 1) * CABLE_TYPING_MS else { return; }
    typing[0] = due + CABLE_TYPING_MS;
    var name: u8[>..] = [];
    let failed = sqlite::run() { name.append(sql_value(db, "SELECT name FROM users WHERE id=?", [sql_text(user)])); };
    guard failed.len == 0 else { return; }
    var body: u8[>..] = [];
    format(body, "{\"action\":\"", action, "\",\"user\":{\"id\":", user, ",\"name\":"); json::format_string(body, name); body.append("}}");
    cable_transient(room * 4 + CABLE_TYPED, body);
}

// Loads the rooms of a user without any here, for its unread notices: the access log keeps them current.
fn cable_load_rooms(db: sqlite::Db, user: i64) -> bool {
    guard cable_cached(user) < 0 else { return true; }
    var rooms: i64[>..] = [];
    let failed = sqlite::run() {
        for row in sql_rows(db, "SELECT room_id FROM memberships WHERE user_id=? ORDER BY room_id", [sql_text(user)]) {
            for cell in row { let n, ok = parse_int(cell); if ok { rooms.push(n); } }
        }
    };
    guard failed.len == 0 else { return false; }
    cable_member_add(user, 0);
    for room in rooms { cable_member_add(user, room); }
    return true;
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

fn cable_message(db: sqlite::Db, user: i64, key: const u8[:], data: const u8[:], presence: i64[:], typing: i64[:],
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
    var owned = cable_owns(conns, index, gen);
    if command == "unsubscribe" {
        if presence_channel {for &room in presence {if room==presence_room {presence_change(db,user,room,2);room=0;}}}
        if owned { cable_unsubscribe(shard,conns,targets,storage,index,identifier); }
        return;
    }
    if command=="message" {
        var action_nodes: json::Node[>..]=[]; var action_strings: u8[>..]=[];
        let info,error=json::parse(cable_string(root,"data"),action_nodes,action_strings);
        let action=cable_string(info,"action");
        if presence_channel {
            if action!="absent" && action!="present" && action!="refresh" {return;}
            for room in presence {
                if room==presence_room && room>0 {
                    presence_change(db,user,room,if action=="absent" {2} else if action=="present" {0} else {1});
                    if action=="present" { cable_read_room(user,room); }
                }
            }
        } else if (action=="start" || action=="stop") && owned && conns[index].revoked==0 {
            // Only a TypingNotificationsChannel subscription the connection holds performs these.
            var room: i64 = 0;
            for sub in conns[index].subs { if sub.live && sub.stream==CABLE_TYPING && sub.identifier==identifier { room=sub.room; } }
            if room>0 { cable_typing(db,user,room,action,typing); }
        }
        return;
    }
    if command != "subscribe" { return; }
    // Access changes logged so far apply first: a revoked connection subscribes to nothing, and the rooms
    // cached for unread notices are current.
    if owned { cable_access(shard,conns,targets,storage); owned = cable_owns(conns,index,gen) && conns[index].revoked==0; }
    var accepted = false; var room: i64 = 0; var stream: i32 = 0;
    let failed = sqlite::run() { let yes, r, s = cable_subscribe(db,user,identifier,key); accepted=yes; room=r; stream=s; };
    accepted = accepted && failed.len == 0 && owned;
    if accepted && stream == CABLE_UNREADS { accepted = cable_load_rooms(db,user); }
    // The worker snapshots its subscriptions as each publication arrives: this one takes those after now.
    var joined = CABLE_REFUSED;
    if accepted { joined = cable_join(conns,storage,index,room,stream,identifier); accepted = joined != CABLE_REFUSED; }
    if stream == CABLE_UNREADS {
        let at = cable_cached(user);
        if at >= 0 && joined == CABLE_JOINED { cable_rooms.pairs[at]--; }
        else if at >= 0 && cable_rooms.pairs[at] == 0 { cable_member_drop(user); }
    }
    if accepted && presence_channel {
        var exists=false; var slot: i64=-1;
        for value,i in presence {if value==room {exists=true;} if value==0 {slot=i;}}
        if !exists {
            accepted=slot>=0 && presence_change(db,user,room,0);
            if accepted {presence[slot]=room;}
            else if joined == CABLE_JOINED { cable_unsubscribe(shard,conns,targets,storage,index,identifier); }
        }
        if accepted { cable_read_room(user,room); }
    }
    var response: u8[>..] = []; response.append("{\"identifier\":"); json::format_string(response,identifier);
    response.append(if accepted { ",\"type\":\"confirm_subscription\"}" } else { ",\"type\":\"reject_subscription\"}" });
    http::ws_send(out,http::WS_TEXT,response); http::after_drain(out);
}
