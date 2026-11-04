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
import storage;
import media;
import view_attachments;
import admin_routes;
import https;

extern fn campfire_disconnected_before(out: u8[>..]&);
extern fn campfire_writer_enter();
extern fn campfire_writer_leave();
extern fn campfire_profile_clock() -> u64;
extern fn campfire_profile_record(times: const u64[:]);

// Work the delivery threads (webhooks.goose) do off the request path: Bot::WebhookJob (a, the bot;
// b, the message), Room::PushMessageJob (a, the message; b, its room; c, its creator), and one
// WebPush::Pool delivery (a, the push subscription; text, the notification) or test notification
// (a, the push subscription; text, the request's scheme and host).
struct DeliveryJob { kind: i64 = 0, a: i64 = 0, b: i64 = 0, c: i64 = 0, text: u8[] = [] }
let DELIVER_WEBHOOK: i64 = 1;
let PUSH_MESSAGE: i64 = 2;
let PUSH_NOTIFY: i64 = 3;
let PUSH_TEST: i64 = 4;
// The most deliveries waiting; work past it is skipped, and logged.
let DELIVERY_QUEUE: i64 = 4096;

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
    // Whether new messages are pushed: VAPID keys are set (push.goose).
    push: bool = false,
}

fn prepare_writer(db: sqlite::Db, writer: WriterStatements&) {
    writer.q=sqlite::prepare(db,"SELECT r.type,u.name,r.name FROM rooms r JOIN memberships m ON m.room_id=r.id JOIN users u ON u.id=m.user_id WHERE r.id=? AND m.user_id=? AND u.status=0");
    writer.insert=sqlite::prepare(db,"INSERT INTO messages(room_id,creator_id,client_message_id,created_at,updated_at) VALUES(?,?,?,?,?)");
    writer.rich=sqlite::prepare(db,"INSERT INTO action_text_rich_texts(name,record_type,record_id,body,created_at,updated_at) VALUES('body','Message',?,?,?,?)");
    writer.index=sqlite::prepare(db,"INSERT INTO message_search_index(rowid,body) VALUES(?,?)");
    writer.touch=sqlite::prepare(db,"UPDATE rooms SET updated_at=? WHERE id=?");
    writer.unread=sqlite::prepare(db,"UPDATE memberships SET unread_at=?,updated_at=? WHERE room_id=? AND user_id<>? AND involvement<>'invisible' AND (connected_at IS NULL OR connected_at<?) AND (unread_at IS NULL OR ?6<>0)");
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

// verify_authenticity_token for a write (https.goose).
fn same_origin(req: const http::Request&) -> bool { return request_same_origin(req); }

fn post_message(db: sqlite::Db, writer: const WriterStatements&, req: const http::Request&, body: const u8[:], user: i64,
                room_id: i64, now: const u8[:], key: const u8[:], ctx: ViewContext, bytes: u8[>..]&, context_start: u64, out: u8[>..]&,
                storage: const u8[:]) -> i32 {
    guard same_origin(req) else { return 422; }
    let kind, has_kind = http::field_of(req, "Content-Type");
    guard has_kind else { return 415; }
    if starts_with(kind, "multipart/form-data") {
        let status, message = post_attachment(db,writer,req,body,"message[attachment]",user,room_id,now,key,ctx,bytes,storage,out);
        return status;
    }
    guard starts_with(kind, "application/x-www-form-urlencoded") else { return 415; }
    var text: u8[>..] = [];
    var client_id: u8[>..] = [];
    guard http::form_value(body, "message[body]", text) && text.len > 0 && text.len <= 65536 else { return 422; }
    guard http::form_value(body, "message[client_message_id]", client_id) && client_id.len > 0 && client_id.len <= 256 else { return 422; }
    var rich_text: u8[>..]=[]; var mentions: i64[>..]=[];
    let host, has_host = http::field_of(req, "Host");
    let plain_text=message_body(db,text,writer.sgid_key,rich_text,mentions,host);
    let status, message_id, direct = create_message(db,writer,user,room_id,client_id,rich_text,plain_text,now,key,ctx,bytes,context_start,out);
    if status==200 && (direct || mentions.len>0) { deliver_webhooks_later(writer,room_id,user,message_id,direct,mentions); }
    return status;
}

// MessagesController#create with a multipart form, as the composer's FileUploader posts a file
// (message[attachment] and message[client_message_id]), or Messages::ByBotsController's
// attachment: Message.create_with_attachment!. The file is written and, unless it is a video or
// audio file, analyzed before the message's transaction, and deleted again if it doesn't commit;
// a video's or audio file's analysis and the thumbnail or preview (process_attachment) are a media
// thread's. A form without a file posts its body text.
fn post_attachment(db: sqlite::Db, writer: const WriterStatements&, req: const http::Request&, body: const u8[:], field: const u8[:], user: i64,
                   room_id: i64, now: const u8[:], key: const u8[:], ctx: ViewContext, bytes: u8[>..]&, storage: const u8[:], out: u8[>..]&) -> i32, i64 {
    let data, fields, found = http::find_part(req, body, field);
    guard found != http::PART_TYPE && found != http::PART_BAD else { return 400, 0; }
    let client, client_fields, has_client = http::find_part(req, body, "message[client_message_id]");
    var client_id: u8[>..] = [];
    if has_client == http::PART_FOUND && client.len > 0 && client.len <= 256 { client_id.append(client); } else { client_id = random_uuid(); }
    let part_name, raw_filename, disposed = http::disposition(fields);
    let filename = unquote_filename(raw_filename);
    if found != http::PART_FOUND || filename.len == 0 {
        // Rack drops a file input left empty; the form's text is the message.
        let text, text_fields, has_text = http::find_part(req, body, "message[body]");
        guard has_text == http::PART_FOUND && text.len > 0 && text.len <= 65536 else { return 422, 0; }
        var rich_text: u8[>..]=[]; var mentions: i64[>..]=[];
        let plain_text=message_body(db,text,writer.sgid_key,rich_text,mentions);
        let status, message_id, direct = create_message(db,writer,user,room_id,client_id,rich_text,plain_text,now,key,ctx,bytes,0,out);
        if status==200 && (direct || mentions.len>0) { deliver_webhooks_later(writer,room_id,user,message_id,direct,mentions); }
        return status, message_id;
    }
    let declared, typed = http::field_in(fields, "content-type");
    var upload = Upload { .. };
    guard stage_upload(storage, data, filename, declared, upload) else { return 500, 0; }
    let status, message_id, direct = create_message_upload(db,writer,user,room_id,client_id,"",sanitized_filename(upload.filename),now,key,ctx,bytes,0,out,upload,storage);
    if status == 200 && probed_content_type(upload.content_type) {
        // Analyzed (and a video previewed) before the answer, the broadcast and the webhooks.
        deferred_post = DeferredPost { message: message_id, blob: attachment_blob(db, message_id), room: room_id, creator: user, direct: direct };
    } else if status == 200 {
        process_attachment_later(db, message_id, upload);
        if direct { let mentions: i64[>..] = []; deliver_webhooks_later(writer,room_id,user,message_id,direct,mentions); }
    }
    return status, message_id;
}

fn attachment_blob(db: sqlite::Db, message_id: i64) -> i64 {
    return sql_number(db, "SELECT blob_id FROM active_storage_attachments WHERE record_type='Message' AND name='attachment' AND record_id=?", [sql_text(message_id)]);
}

// Message#process_attachment_thumbnail for an image, after the message commits, on a media thread:
// representation(:thumb). Rails makes it before answering; the create markup doesn't depend on it,
// and a thumbnail requested first waits for it. Videos and audio go through process_posted_later.
fn process_attachment_later(db: sqlite::Db, message_id: i64, upload: const Upload&) {
    guard variable_content_type(upload.content_type) else { return; }
    let blob = attachment_blob(db, message_id);
    if blob > 0 { process_later(MEDIA_VARIANT, blob, 0, thumb_variation(upload.content_type, upload.filename)); }
}

// The stored form of a posted body into rich, with the users it mentions, and its plain text.
// host is the request's, which a link preview's link and image must not point at.
fn message_body(db: sqlite::Db, text: const u8[:], sgid_key: const u8[:], rich: u8[>..]&, mentions: i64[>..]&, host: const u8[:] = "") -> u8[>..] {
    if find(text,"<action-text-attachment")<0 {
        rich_sanitize(rich,text,false);
        return rich_plain(rich);
    }
    rich_sanitize(rich,text,false,true,host);
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
        if !qput(DeliveryJob { kind: DELIVER_WEBHOOK, a: bot, b: message }) {
            write_stderr(str("Bot webhook queue is full: bot ",bot," skips message ",message,"\n"));
        }
    }
}

// Creates the message in one transaction and renders out, its turbo stream; the status, the
// message, and whether its room is direct. The creator must be an active member of the room.
fn create_message(db: sqlite::Db, writer: const WriterStatements&, user: i64, room_id: i64, client_id: const u8[:],
                  rich_text: const u8[:], plain_text: const u8[:], now: const u8[:], key: const u8[:], ctx: ViewContext,
                  bytes: u8[>..]&, context_start: u64, out: u8[>..]&) -> i32, i64, bool {
    let none = Upload { .. };
    let status, message, direct = create_message_upload(db,writer,user,room_id,client_id,rich_text,plain_text,now,key,ctx,bytes,context_start,out,none,"");
    return status, message, direct;
}

// create_message, with the attachment's blob and attachment rows in the same transaction when
// upload has a key: such a message has no rich text body, and its plain text is the filename.
fn create_message_upload(db: sqlite::Db, writer: const WriterStatements&, user: i64, room_id: i64, client_id: const u8[:],
                  rich_text: const u8[:], plain_text: const u8[:], now: const u8[:], key: const u8[:], ctx: ViewContext,
                  bytes: u8[>..]&, context_start: u64, out: u8[>..]&, upload: const Upload&, storage: const u8[:]) -> i32, i64, bool {
    let attaching=upload.key.len>0;
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

                if attaching { let blob=save_upload(db,upload,"attachment","Message",message_id,now); }
                else {
                    sqlite::bind_i64(rich, 1, message_id);
                    sqlite::bind_text(rich, 2, rich_text);
                    sqlite::bind_text(rich, 3, now);
                    sqlite::bind_text(rich, 4, now);
                    while sqlite::step(rich) {}
                }

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
                // Room#unread_memberships: in a shared room, members already unread are left as they are.
                sqlite::bind_i64(unread, 6, if room_kind=="rooms_direct" { 1 } else { 0 });
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
    // Message's after_create_commit: room.receive(message), whose push_later is one queued job.
    if failed.len==0 && status==200 && writer.push { push_later(message_id,room_id,user); }
    timing[5]=campfire_profile_clock();
    // An attachment's file goes with a message that didn't commit.
    if attaching && (failed.len > 0 || status != 200) { delete_blob_file(storage, upload.key); }
    for e in failed { sqlite::fail(e.code, e.message); }
    if status==200 {
        render_created_message(db,message_id,room_id,saved_room,room_kind,client_id,now,rich_text,plain_text,attaching,key,ctx,bytes,out);
        timing[6]=campfire_profile_clock();
        campfire_profile_record([timing[1]-timing[0],timing[2]-timing[1],timing[3]-timing[2],timing[6]-timing[5],timing[4]-timing[3],timing[5]-timing[4]]);
    }
    return status, message_id, room_kind=="rooms_direct";
}

// The turbo stream Message#broadcast_create and messages/create render for a message just created
// by ctx.user, as of its creation (the record Rails holds in memory).
fn render_created_message(db: sqlite::Db, message_id: i64, room_id: i64, saved_room: const u8[:], room_kind: const u8[:], client_id: const u8[:],
                          now: const u8[:], rich_text: const u8[:], plain_text: const u8[:], attaching: bool, key: const u8[:], ctx: ViewContext,
                          bytes: u8[>..]&, out: u8[>..]&) {
    var message=MessageView { .. };
    message.id=message_id; message.room_id=room_id; message.room_name=view_keep(bytes,saved_room); message.creator=ctx.user;
    message.dom_id=view_keep(bytes,str("message_",message_id)); message.client_message_id=view_keep(bytes,client_id); message.created_ms=campfire_epoch_ms(now); message.updated_ms=message.created_ms; message.created_iso=view_keep(bytes,time_iso(now));
    message.at_path=view_keep(bytes,str("/rooms/",room_id,"/@",message_id)); message.edit_path=view_keep(bytes,str("/rooms/",room_id,"/messages/",message_id,"/edit"));
    message.boosts_path=view_keep(bytes,str("/messages/",message_id,"/boosts")); message.new_boost_path=view_keep(bytes,str(message.boosts_path,"/new"));
    if !attaching || !attachment_presentation(db,message_id,ctx.storage_key,bytes,message) { message.presentation=view_keep(bytes,text_presentation(db,rich_text,plain_text,key)); }
    message.all_emoji=all_emoji(plain_text);
    ctx.room.kind=view_keep(bytes,room_kind);
    render_post_html(out,ctx,message);
}

// render_created_message for an attachment's message read back once Message#process_attachment
// has run: its room, whether that is direct, and its creation time in epoch ms; room 0 when the
// message is gone. ctx holds the storage key; its user is the creator, loaded here.
fn render_posted_attachment(db: sqlite::Db, message_id: i64, key: const u8[:], ctx: ViewContext, bytes: u8[>..]&, out: u8[>..]&) -> i64, bool, i64 {
    for row in sql_rows(db, "SELECT m.room_id,m.creator_id,coalesce(m.client_message_id,''),m.created_at,r.type,coalesce(r.name,''),coalesce((SELECT body FROM message_search_index WHERE rowid=m.id),'') FROM messages m JOIN rooms r ON r.id=m.room_id WHERE m.id=?", [sql_text(message_id)]) {
        let room, room_valid = parse_int(cell(row, 0)); let creator, creator_valid = parse_int(cell(row, 1));
        guard room_valid && creator_valid else { return 0, false, 0; }
        let room_type = cell(row, 4);
        let room_kind = if room_type=="Rooms::Open" { "rooms_open" } else if room_type=="Rooms::Closed" { "rooms_closed" } else { "rooms_direct" };
        ctx.user = load_user(db, creator, key, bytes);
        render_created_message(db,message_id,room,cell(row,5),room_kind,cell(row,2),cell(row,3),"",cell(row,6),true,key,ctx,bytes,out);
        return room, room_kind=="rooms_direct", campfire_epoch_ms(cell(row, 3));
    }
    return 0, false, 0;
}

// A post whose video or audio attachment Message#process_attachment must finish before Rails
// answers and broadcasts it, which post_attachment leaves to its caller (process_posted_later).
struct DeferredPost { message: i64 = 0, blob: i64 = 0, room: i64 = 0, creator: i64 = 0, direct: bool = false }
var deferred_post = DeferredPost { .. };

fn take_deferred_post() -> DeferredPost {
    let taken = deferred_post;
    deferred_post = DeferredPost { .. };
    return taken;
}

// Set when this worker's request handed its post to a media thread, whose publication then holds
// a cable permit of its own: the worker returns the one it took for the request.
var posted_media = false;

fn take_posted_media() -> bool {
    let taken = posted_media;
    posted_media = false;
    return taken;
}
