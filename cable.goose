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
struct CableCommand {
    kind: i32, address: http::MailAddress, user: i64 = 0, room: i64 = 0,
    stream: i32 = 0, data: u8[]
}
// prefix caches the encoded `{"identifier":...,"message":` that starts each delivery.
struct CableSubscriber { live: bool = false, retiring: bool = false, room: i64, stream: i32, identifier: u8[:], prefix: u8[:] }
struct CableConnection {
    live: bool = false, address: http::MailAddress, user: i64,
    ready: bool = true, sequence: i64 = 0, offset: i64 = 0,
    // Publications before credited have been credited to the window; those from credited to sequence wait on a drain.
    credited: i64 = 0
}
// The broker owns body from enrollment to retirement, which waits until every enrolled worker drained or left.
struct CableDelivery { reply: http::MailAddress, body: http::Shared = http::Shared { .. }, length: i64 = 0, remaining: i64 = 0 }
let CABLE_WINDOW: i64 = 8;
let CABLE_ENROLLED: i32 = 65536;
let CABLE_JOIN: i32 = 1;
let CABLE_CREDIT: i32 = 2;
let CABLE_LEAVE: i32 = 3;
let CABLE_UNSUBSCRIBE: i32 = 4;
let CABLE_PUBLISH: i32 = 5;
let CABLE_ACK: i32 = 256;
// A delivery describes WebSocket frames: inline runs and ranges of shared bodies; with 128 set, the last frame ends its message.
let CABLE_FRAMED: i32 = 512;
let CABLE_INLINE: u8 = 0;
let CABLE_RANGE: u8 = 1;
// The most frame bytes one delivery describes, and the most bytes its description takes: the mailbox slot size.
let CABLE_BATCH: i64 = 32768;
let CABLE_MAIL: i64 = 8192;

fn cable_command(kind: i32, address: http::MailAddress) {
    qput(CableCommand { kind: kind, address: address, data: [], .. });
}

extern fn campfire_credit_push(box: u64, key: u64) -> bool;
extern fn campfire_credit_take(out: u8[>..]&);

// Credits a drain to the broker; only the credit that finds none pending wakes it.
fn cable_credit(address: http::MailAddress) {
    if campfire_credit_push(http::key_of(address.box), address.key) { cable_command(CABLE_CREDIT, http::MailAddress { .. }); }
}

fn publish(room: i64, reply: http::MailAddress, body: const u8[:]) {
    // Each publication owns one permit until final delivery, including queued acknowledgements.
    assert(qput(Publication { room: room, reply: reply, body: sql_text(body) }));
    cable_command(CABLE_PUBLISH, reply);
}

thread_fn cable_broker(queued_ack: bool, window_size: i64) {
    var connections: CableConnection[>..] = [];
    // Each connection owns 16 contiguous slots; connection scans do not copy their payloads.
    var subscriptions: CableSubscriber[>..] = [];
    // The low 16 bits identify subscriptions; the high bit owns one completion credit.
    var targets: i32[>..] = [];
    reusable[] var storage: u8[>..] = [];
    var window: CableDelivery[>..] = [];
    for _ in window_size { window.push(CableDelivery { .. }); }
    var head: i64 = 0;
    var tail: i64 = 0;
    var acknowledged: i64 = 0;
    var body: u8[>..] = [];
    var chunk: u8[>..] = [];
    var completed: i64[>..] = [];
    var credits: u8[>..] = [];
    // Where the description's open inline run starts, or -1.
    var run: i64 = -1;
    fn inline(bytes: const u8[:]) {
        if run < 0 || chunk.len - run - 3 + bytes.len > 65535 {
            run = chunk.len; chunk.push(CABLE_INLINE); chunk.push(0); chunk.push(0);
        }
        chunk.append(bytes);
        let n = chunk.len - run - 3;
        chunk[run+1] = n as! u8; chunk[run+2] = (n >> 8) as! u8;
    }

    fn drop_connection(index: i64) {
        connections[index].live = false;
        for &target, slot in targets[index*window_size..(index+1)*window_size] {
            if target & CABLE_ENROLLED != 0 { window[slot].remaining--; }
            target = 0;
        }
        for &sub in subscriptions[index*16..index*16+16] {
            if sub.live || sub.retiring {
                storage.free_slice(sub.identifier); storage.free_slice(sub.prefix);
                sub.live = false; sub.retiring = false;
            }
        }
    }
    fn matches(sub: const CableSubscriber&, user: i64, room: i64) -> bool {
        return sub.live && (if room==0 { sub.stream==2 } else if room<0 { sub.stream==5 && user == -room } else { sub.stream==1 && sub.room==room });
    }
    fn apply_command(command: const CableCommand&) {
        if command.kind == CABLE_CREDIT {
            credits.clear(); campfire_credit_take(credits);
            var at: i64 = 0;
            while at < credits.len {
                let address = http::MailAddress { box: http::handle_of(cable_le(credits, at, 8) as u64), key: cable_le(credits, at+8, 8) as u64 };
                for &c in connections { if c.live && c.address == address { c.ready = true; break; } }
                at += 16;
            }
            return;
        }
        var index: i64 = -1;
        for &c, i in connections { if c.live && c.address == command.address { index = i; break; } }
        if command.kind == CABLE_JOIN {
            if index < 0 {
                for &c, i in connections { if !c.live { index = i; break; } }
                if index < 0 {
                    index = connections.len;
                    connections.push(CableConnection { address: command.address, user: command.user, .. });
                    for _ in 0..16 { subscriptions.push(CableSubscriber { .. }); }
                    for _ in 0..window_size { targets.push(0); }
                }
                connections[index] = CableConnection { live: true, address: command.address, user: command.user, sequence: tail, credited: tail, .. };
            }
            var duplicate = false;
            var slot: i64 = -1;
            var count: i64 = 0;
            for sub, i in subscriptions[index*16..index*16+16] {
                if sub.live || sub.retiring { count++; }
                if sub.live && sub.identifier == command.data { duplicate = true; }
                if !sub.live && !sub.retiring { slot = i; }
            }
            if !duplicate && count < 16 {
                let id = storage.alloc_slice(command.data.len); copy_into(id, command.data);
                chunk.clear(); chunk.append("{\"identifier\":"); json::format_string(chunk, command.data); chunk.append(",\"message\":");
                let prefix = storage.alloc_slice(chunk.len); copy_into(prefix, chunk);
                let sub = CableSubscriber { live: true, room: command.room, stream: command.stream, identifier: id, prefix: prefix, .. };
                subscriptions[index*16+slot] = sub;
            }
        } else if index >= 0 && command.kind == CABLE_LEAVE {
            drop_connection(index);
        } else if index >= 0 && command.kind == CABLE_UNSUBSCRIBE {
            for &sub, si in subscriptions[index*16..index*16+16] {
                if sub.live && sub.identifier == command.data {
                    let current = connections[index].sequence & (window_size-1);
                    let mask = targets[index*window_size+current];
                    let partial = connections[index].offset != 0 && (mask & (1 << si)) != 0 && (mask & ((1 << si)-1)) == 0;
                    sub.live = false; sub.retiring = partial;
                    // An already-started WebSocket message must finish before its identifier can be reused.
                    if !partial { storage.free_slice(sub.identifier); storage.free_slice(sub.prefix); }
                    for &target, slot in targets[index*window_size..(index+1)*window_size] {
                        if !partial || slot != current { target &= ~(1 << si); }
                    }
                }
            }
        }
    }
    loop {
        let first = qget<CableCommand>();
        apply_command(first);
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
                let slot = tail & (window_size-1);
                window[slot].reply = pending.reply;
                window[slot].remaining = 0;
                body.clear();
                for &c, ci in connections {
                    var mask: i32 = 0;
                    if c.live {
                        for sub, si in subscriptions[ci*16..ci*16+16] {
                            if matches(sub, c.user, pending.room) { mask |= 1 << si; }
                        }
                    }
                    if mask != 0 { mask |= CABLE_ENROLLED; window[slot].remaining++; }
                    targets[ci*window_size+slot] = mask;
                }
                window[slot].body = http::Shared { .. }; window[slot].length = 0;
                if window[slot].remaining != 0 {
                    json::format_string(body, pending.body);
                    let shared, failed = http::shared_put(body, 1);
                    assert(failed == 0);
                    window[slot].body = shared; window[slot].length = body.len;
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
            for &c, ci in connections {
                c.sequence = max(c.sequence, head); c.credited = max(c.credited, head);
                if !c.live || c.sequence == tail && c.credited == tail { continue; }
                if !c.ready {
                    if !http::mail_live(c.address) { drop_connection(ci); }
                    continue;
                }
                // The drained batch's final sends keep their completion credits until now.
                while c.credited < c.sequence {
                    let slot = c.credited & (window_size-1);
                    if targets[ci*window_size+slot] & CABLE_ENROLLED != 0 { window[slot].remaining--; targets[ci*window_size+slot] = 0; }
                    c.credited++;
                }
                while c.sequence < tail {
                    let slot = c.sequence & (window_size-1);
                    let mask = targets[ci*window_size+slot];
                    if mask & 65535 != 0 { break; }
                    if mask & CABLE_ENROLLED != 0 { window[slot].remaining--; targets[ci*window_size+slot] = 0; }
                    c.sequence++; c.credited = c.sequence; c.offset = 0;
                }
                // Coalesce frames up to CABLE_BATCH; only a message larger than that is fragmented.
                chunk.clear(); completed.clear();
                var sequence = c.sequence;
                var offset = c.offset;
                var mask: i32 = if sequence < tail { targets[ci*window_size+(sequence & (window_size-1))] } else { 0 };
                var whole = true;
                var wire: i64 = 0;
                run = -1;
                while sequence < tail {
                    let slot = sequence & (window_size-1);
                    if mask & 65535 == 0 {
                        sequence++; offset = 0;
                        if sequence < tail { mask = targets[ci*window_size+(sequence & (window_size-1))]; }
                        continue;
                    }
                    var subscription: i64 = 0;
                    while mask & (1 << subscription) == 0 { subscription++; }
                    let sub .= subscriptions[ci*16+subscription];
                    let prefix = sub.prefix;
                    let length = prefix.len + window[slot].length + 1;
                    let room = CABLE_BATCH - wire - 4;
                    // Besides inline identifier bytes, a frame's description takes at most 31 bytes.
                    let space = CABLE_MAIL - chunk.len - 31;
                    if wire > 0 && (length - offset > room || space < max(prefix.len - offset, 0)) { break; }
                    var end = min(length, offset + room);
                    // A long identifier's inline bytes must fit the description.
                    if offset < prefix.len { end = min(end, offset + space); }
                    whole = end == length;
                    let size = end - offset;
                    var frame: u8[..4] = [];
                    frame.push(((if offset == 0 { 1 } else { 0 }) | (if whole { 128 } else { 0 })) as! u8);
                    if size < 126 { frame.push(size as! u8); }
                    else { frame.push(126); frame.push((size >> 8) as! u8); frame.push(size as! u8); }
                    inline(frame);
                    if offset < prefix.len { inline(prefix[offset..min(end, prefix.len)]); }
                    let start = max(offset, prefix.len) - prefix.len;
                    let stop = min(end, prefix.len + window[slot].length) - prefix.len;
                    if start < stop {
                        chunk.push(CABLE_RANGE);
                        for i in 8 { chunk.push((window[slot].body.h >> (8*i)) as! u8); }
                        for i in 4 { chunk.push((start >> (8*i)) as! u8); }
                        for i in 4 { chunk.push((stop >> (8*i)) as! u8); }
                        run = -1;
                    }
                    wire += frame.len + size;
                    if whole { inline("}"); } else { offset = end; break; }
                    completed.push(slot*16+subscription); mask &= ~(1 << subscription); offset = 0;
                }
                if chunk.len == 0 { continue; }
                let sent = http::mail_send(c.address, CABLE_FRAMED | (if whole { 128 } else { 0 }), chunk);
                if sent == http::STALE { drop_connection(ci); continue; }
                if sent == http::SENT {
                    c.ready = false; c.sequence = sequence; c.offset = offset;
                    for done in completed {
                        let subscription = done & 15;
                        targets[ci*window_size+(done >> 4)] &= ~(1 << subscription);
                        let sub .= subscriptions[ci*16+subscription];
                        if sub.retiring { storage.free_slice(sub.identifier); storage.free_slice(sub.prefix); subscriptions[ci*16+subscription].retiring = false; }
                    }
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

// Sends a broker delivery's frames: its inline runs, and its ranges of bodies the broker keeps until this drains.
fn cable_frame(out: http::Reply, data: const u8[:]) {
    var at: i64 = 0;
    while at < data.len {
        if data[at] == CABLE_INLINE {
            let n = cable_le(data, at+1, 2);
            http::send(out, data[at+3..at+3+n]); at += 3+n;
        } else {
            let body = http::Shared { h: cable_le(data, at+1, 8) };
            assert(http::send_shared(out, body, cable_le(data, at+9, 4), cable_le(data, at+13, 4))); at += 17;
        }
    }
    http::after_drain(out);
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

fn cable_message(db: sqlite::Db, user: i64, key: const u8[:], data: const u8[:], presence: i64[:], out: http::Reply) {
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let root, error = json::parse(data, nodes, strings);
    if error.len > 0 { return; }
    let command = cable_string(root, "command"); let identifier = cable_string(root, "identifier");
    if identifier.len == 0 || identifier.len > 2048 { return; }
    var params_nodes: json::Node[>..]=[]; var params_strings: u8[>..]=[];
    let params,bad_params=json::parse(identifier,params_nodes,params_strings);
    let presence_channel=cable_string(params,"channel")=="PresenceChannel";
    let presence_room=signed_integer(json::member(params,"room_id"));
    let address = http::later(out, 3000);
    if command == "unsubscribe" {
        if presence_channel {for &room in presence {if room==presence_room {presence_change(db,user,room,2);room=0;}}}
        qput(CableCommand { kind:CABLE_UNSUBSCRIBE,address:address,data:sql_text(identifier),.. }); return;
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
    if accepted { accepted = qput(CableCommand { kind:CABLE_JOIN,address:address,user:user,room:room,stream:stream,data:sql_text(identifier) }); }
    var response: u8[>..] = []; response.append("{\"identifier\":"); json::format_string(response,identifier);
    response.append(if accepted { ",\"type\":\"confirm_subscription\"}" } else { ",\"type\":\"reject_subscription\"}" });
    http::ws_send(out,http::WS_TEXT,response); http::after_drain(out);
}
