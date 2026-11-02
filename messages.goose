namespace campfire;

import std;
import sqlite;
import http;
import pages;
import html;
import emoji;
import view_types;
import view_data;
import view_helpers;
import views_generated;
import checkpoints;
import rich_html;
import signed_id;
import database;

extern fn campfire_disconnected_before(out: u8[>..]&);
extern fn campfire_writer_enter();
extern fn campfire_writer_leave();
extern fn campfire_profile_clock() -> u64;
extern fn campfire_profile_record(times: const u64[:]);

// Bot::WebhookJob: delivers the message to the bot's webhook off the request path (webhooks.goose).
struct WebhookJob { bot: i64 = 0, message: i64 = 0 }
// The most webhook deliveries waiting; a message past it skips its webhooks.
let WEBHOOK_QUEUE: i64 = 4096;

struct WriterStatements {
    q: sqlite::Stmt = sqlite::Stmt {},
    insert: sqlite::Stmt = sqlite::Stmt {},
    rich: sqlite::Stmt = sqlite::Stmt {},
    index: sqlite::Stmt = sqlite::Stmt {},
    touch: sqlite::Stmt = sqlite::Stmt {},
    unread: sqlite::Stmt = sqlite::Stmt {},
    begin: sqlite::Stmt = sqlite::Stmt {},
    commit: sqlite::Stmt = sqlite::Stmt {},
    // The room's active bots with a webhook, other than the poster: all of them, or the one ?3 names.
    bots: sqlite::Stmt = sqlite::Stmt {},
    // Verifies the SGIDs of mention attachments.
    sgid_key: u8[64] = [0; 64],
}

fn prepare_writer(db: sqlite::Db, writer: WriterStatements&) {
    writer.q=sqlite::prepare(db,"SELECT r.type,u.name,r.name FROM rooms r JOIN memberships m ON m.room_id=r.id JOIN users u ON u.id=m.user_id WHERE r.id=? AND m.user_id=? AND u.status=0");
    writer.insert=sqlite::prepare(db,"INSERT INTO messages(room_id,creator_id,client_message_id,created_at,updated_at) VALUES(?,?,?,?,?)");
    writer.rich=sqlite::prepare(db,"INSERT INTO action_text_rich_texts(name,record_type,record_id,body,created_at,updated_at) VALUES('body','Message',?,?,?,?)");
    writer.index=sqlite::prepare(db,"INSERT INTO message_search_index(rowid,body) VALUES(?,?)");
    writer.touch=sqlite::prepare(db,"UPDATE rooms SET updated_at=? WHERE id=?");
    writer.unread=sqlite::prepare(db,"UPDATE memberships SET unread_at=?,updated_at=? WHERE room_id=? AND user_id<>? AND involvement<>'invisible' AND (connected_at IS NULL OR connected_at<?)");
    writer.begin=sqlite::prepare(db,"BEGIN IMMEDIATE");
    writer.commit=sqlite::prepare(db,"COMMIT");
    // A database without the webhooks table delivers none.
    let missing=sqlite::run() {
        writer.bots=sqlite::prepare(db,"SELECT u.id FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.room_id=?1 AND u.id<>?2 AND (?3=0 OR u.id=?3) AND u.role=2 AND u.status=0 AND EXISTS(SELECT 1 FROM webhooks w WHERE w.user_id=u.id) ORDER BY u.id");
    };
}

fn reset_writer(writer: const WriterStatements&) {
    sqlite::reset(writer.q);
    sqlite::reset(writer.insert);
    sqlite::reset(writer.rich);
    sqlite::reset(writer.index);
    sqlite::reset(writer.touch);
    sqlite::reset(writer.unread);
    sqlite::reset(writer.begin);
    sqlite::reset(writer.commit);
}

fn close_writer(writer: const WriterStatements&) {
    sqlite::finalize(writer.q);
    sqlite::finalize(writer.insert);
    sqlite::finalize(writer.rich);
    sqlite::finalize(writer.index);
    sqlite::finalize(writer.touch);
    sqlite::finalize(writer.unread);
    sqlite::finalize(writer.begin);
    sqlite::finalize(writer.commit);
    if writer.bots.id!=0 { sqlite::finalize(writer.bots); }
}

fn same_origin(req: const http::Request&) -> bool {
    let site, has_site = http::field_of(req, "Sec-Fetch-Site");
    if has_site && site != "same-origin" && site != "same-site" { return false; }
    let origin, has_origin = http::field_of(req, "Origin");
    if has_origin {
        let host, has_host = http::field_of(req, "Host");
        return has_host && origin == str("http://", host);
    }
    return true;
}

fn post_message(db: sqlite::Db, writer: const WriterStatements&, req: const http::Request&, body: const u8[:], user: i64,
                room_id: i64, now: const u8[:], key: const u8[:], ctx: ViewContext, bytes: u8[>..]&, context_start: u64, out: u8[>..]&) -> i32 {
    guard same_origin(req) else { return 422; }
    let kind, has_kind = http::field_of(req, "Content-Type");
    guard has_kind && starts_with(kind, "application/x-www-form-urlencoded") else { return 415; }
    var text: u8[>..] = [];
    var client_id: u8[>..] = [];
    guard http::form_value(body, "message[body]", text) && text.len > 0 && text.len <= 65536 else { return 422; }
    guard http::form_value(body, "message[client_message_id]", client_id) && client_id.len > 0 && client_id.len <= 256 else { return 422; }
    var rich_text: u8[>..]=[]; var mentions: i64[>..]=[];
    let plain_text=message_body(db,text,writer.sgid_key,rich_text,mentions);
    let status, message_id, direct = create_message(db,writer,user,room_id,client_id,rich_text,plain_text,now,key,ctx,bytes,context_start,out);
    if status==200 && (direct || mentions.len>0) { deliver_webhooks_later(writer,room_id,user,message_id,direct,mentions); }
    return status;
}

// The stored form of a posted body into rich, with the users it mentions, and its plain text.
fn message_body(db: sqlite::Db, text: const u8[:], sgid_key: const u8[:], rich: u8[>..]&, mentions: i64[>..]&) -> u8[>..] {
    if find(text,"<action-text-attachment")<0 {
        rich_sanitize(rich,text,false);
        return rich_plain(rich);
    }
    rich_sanitize(rich,text,false,true);
    return mention_plain(db,rich,sgid_key,mentions);
}

// The plain text of a stored body with mention attachments, each written as @Name
// (attachable_plain_text_representation), and the users they mention, each once.
fn mention_plain(db: sqlite::Db, rich: const u8[:], sgid_key: const u8[:], mentions: i64[>..]&) -> u8[>..] {
    var text: u8[>..]=[]; var i: i64=0; var begin: i64=0;
    while i<rich.len {
        if rich[i]!='<' { i+=1; continue; }
        var attrs: RichAttr[>..]=[]; let tag=rich_tag(rich,i,attrs);
        if tag.closing || tag.name!="action-text-attachment" || html_decode(rich_attribute(attrs,"content-type"))!=MENTION_TYPE { i=tag.end; continue; }
        text.append(rich[begin..i]);
        let user=verify_sgid(html_decode(rich_attribute(attrs,"sgid")),sgid_key);
        if user>0 {
            let name=sql_value(db,"SELECT name FROM users WHERE id=?",[sql_text(user)]);
            if name.len>0 { text.push('@'); escape(text,name); }
            var seen=false; for id in mentions { if id==user { seen=true; } }
            if !seen { mentions.push(user); }
        }
        let end=find(rich[tag.end..],"</action-text-attachment>");
        i=if end<0 { tag.end } else { tag.end+end+25 }; begin=i;
    }
    text.append(rich[begin..]);
    return rich_plain(text);
}

// Enqueues a Bot::WebhookJob for each eligible bot, as MessagesController#deliver_webhooks_to_bots
// does: each active bot of a direct room, or each mentioned one, but not the message's creator.
// A full queue skips the deliveries, logged; the message stands.
fn deliver_webhooks_later(writer: const WriterStatements&, room: i64, creator: i64, message: i64, direct: bool, mentions: const i64[:]) {
    guard writer.bots.id!=0 else { return; }
    var bots: i64[>..]=[];
    let q=writer.bots;
    let rounds=if direct { 1 } else { mentions.len };
    let failed=sqlite::run() {
        for round in rounds {
            sqlite::reset(q);
            sqlite::bind_i64(q,1,room); sqlite::bind_i64(q,2,creator); sqlite::bind_i64(q,3,if direct { 0 } else { mentions[round] });
            while sqlite::step(q) { bots.push(sqlite::column_i64(q,0)); }
        }
    };
    sqlite::reset(q);
    for e in failed { write_stderr(str("Bot webhooks for message ",message," not enqueued: ",e.message,"\n")); }
    for bot in bots {
        if !qput(WebhookJob { bot: bot, message: message }) {
            write_stderr(str("Bot webhook queue is full: bot ",bot," skips message ",message,"\n"));
        }
    }
}

// Creates the message in one transaction and renders out, its turbo stream; the status, the
// message, and whether its room is direct. The creator must be an active member of the room.
fn create_message(db: sqlite::Db, writer: const WriterStatements&, user: i64, room_id: i64, client_id: const u8[:],
                  rich_text: const u8[:], plain_text: const u8[:], now: const u8[:], key: const u8[:], ctx: ViewContext,
                  bytes: u8[>..]&, context_start: u64, out: u8[>..]&) -> i32, i64, bool {
    let q=writer.q;
    let insert=writer.insert;
    let rich=writer.rich;
    let index=writer.index;
    let touch=writer.touch;
    let unread=writer.unread;
    var message_id: i64 = 0;
    var saved_room: u8[>..]=[]; var room_kind: u8[..13]=[];
    var status: i32 = 404;
    var disconnected_before: u8[>..] = [];
    campfire_disconnected_before(disconnected_before);
    var timing: u64[7]=[0;7]; timing[0]=context_start; timing[1]=campfire_profile_clock();
    campfire_writer_enter();
    timing[2]=campfire_profile_clock();
    let failed = sqlite::run() {
        while sqlite::step(writer.begin) {}
        {

            sqlite::bind_i64(q, 1, room_id);
            sqlite::bind_i64(q, 2, user);
            if sqlite::step(q) {
                let room_type = text_column(q, 0);
                saved_room=text_column(q,2);
                room_kind=if room_type=="Rooms::Open" { "rooms_open" } else if room_type=="Rooms::Closed" { "rooms_closed" } else { "rooms_direct" };

                sqlite::bind_i64(insert, 1, room_id);
                sqlite::bind_i64(insert, 2, user);
                sqlite::bind_text(insert, 3, client_id);
                sqlite::bind_text(insert, 4, now);
                sqlite::bind_text(insert, 5, now);
                while sqlite::step(insert) {}
                message_id = sqlite::last_insert_rowid(db);

                sqlite::bind_i64(rich, 1, message_id);
                sqlite::bind_text(rich, 2, rich_text);
                sqlite::bind_text(rich, 3, now);
                sqlite::bind_text(rich, 4, now);
                while sqlite::step(rich) {}

                sqlite::bind_i64(index, 1, message_id);
                sqlite::bind_text(index, 2, plain_text);
                while sqlite::step(index) {}

                sqlite::bind_text(touch, 1, now);
                sqlite::bind_i64(touch, 2, room_id);
                while sqlite::step(touch) {}

                sqlite::bind_text(unread, 1, now);
                sqlite::bind_text(unread, 2, now);
                sqlite::bind_i64(unread, 3, room_id);
                sqlite::bind_i64(unread, 4, user);
                sqlite::bind_text(unread, 5, disconnected_before);
                while sqlite::step(unread) {}
                status = 200;
            }
        };
        timing[3]=campfire_profile_clock();
        while sqlite::step(writer.commit) {}
        timing[4]=campfire_profile_clock();
    };
    reset_writer(writer);
    if failed.len > 0 {
        let rollback_errors = sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db, "ROLLBACK"); } };
    }
    if failed.len==0 && status==200 { checkpoint_after_write(db); }
    campfire_writer_leave();
    timing[5]=campfire_profile_clock();
    for e in failed { sqlite::fail(e.code, e.message); }
    if status==200 {
        var message=MessageView { .. };
        message.id=message_id; message.room_id=room_id; message.room_name=view_keep(bytes,saved_room); message.creator=ctx.user;
        message.dom_id=view_keep(bytes,str("message_",client_id)); message.created_ms=campfire_epoch_ms(now); message.updated_ms=message.created_ms; message.created_iso=view_keep(bytes,time_iso(now));
        message.at_path=view_keep(bytes,str("/rooms/",room_id,"/@",message_id)); message.edit_path=view_keep(bytes,str("/rooms/",room_id,"/messages/",message_id,"/edit"));
        message.boosts_path=view_keep(bytes,str("/messages/",message_id,"/boosts")); message.new_boost_path=view_keep(bytes,str(message.boosts_path,"/new"));
        message.presentation=view_keep(bytes,text_presentation(db,rich_text,plain_text,key)); message.all_emoji=all_emoji(plain_text);
        ctx.room.kind=view_keep(bytes,room_kind);
        render_post_html(out,ctx,message);
        timing[6]=campfire_profile_clock();
        campfire_profile_record([timing[1]-timing[0],timing[2]-timing[1],timing[3]-timing[2],timing[6]-timing[5],timing[4]-timing[3],timing[5]-timing[4]]);
    }
    return status, message_id, room_kind=="rooms_direct";
}
