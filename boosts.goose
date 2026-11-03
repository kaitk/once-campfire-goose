namespace campfire;
import std;
import http;
import http.compression;
import sqlite;
import database;
import html;
import messages;
import sessions;
import setup;
import cable;
import rich_html;
import browser_routes;
import route_support;
import admin_routes;
import webhooks;
import view_types;
import view_data;
import views_generated;
import storage;
import media;

// `Current.user.reachable_messages.find(id)`: the message's room when the user is a member of it, else 0.
// A bot's routes also name the room, which must be the message's.
fn reachable_message_room(db, user: i64, id: i64, room: i64 = 0) -> i64 {
    if room > 0 {
        return sql_number(db,"SELECT m.room_id FROM messages m JOIN memberships mm ON mm.room_id=m.room_id WHERE m.id=? AND mm.user_id=? AND m.room_id=?",
            [sql_text(id),sql_text(user),sql_text(room)]);
    }
    return sql_number(db,"SELECT m.room_id FROM messages m JOIN memberships mm ON mm.room_id=m.room_id WHERE m.id=? AND mm.user_id=?",[sql_text(id),sql_text(user)]);
}

// Creates (content given) or destroys (boost_id given) a boost by user on a reachable message, touching the
// message and its room as Boost's `belongs_to :message, touch: true` does. Returns the status, the room, the
// stream to broadcast to it, and the created boost.
fn write_boost(db: sqlite::Db, user: i64, message_id: i64, room_filter: i64, creating: bool, content: const u8[:], boost_id: i64,
               avatar_key: const u8[:]) -> i32, i64, u8[], i64 {
    var status: i32 = 404; var room: i64 = 0; var created: i64 = 0; var stream: u8[>..] = [];
    var now: u8[>..] = []; campfire_sql_now(now);
    let failed = write_transaction(db) {
        room = reachable_message_room(db,user,message_id,room_filter);
        if room > 0 {
            if creating {
                sql_rows(db,"INSERT INTO boosts(message_id,booster_id,content,created_at,updated_at) VALUES(?,?,?,?,?)",
                    [sql_text(message_id),sql_text(user),sql_text(content),sql_text(now),sql_text(now)]);
                created = sqlite::last_insert_rowid(db); status = 201;
            } else if sql_number(db,"SELECT count(*) FROM boosts WHERE id=? AND message_id=? AND booster_id=?",[sql_text(boost_id),sql_text(message_id),sql_text(user)]) > 0 {
                sql_rows(db,"DELETE FROM boosts WHERE id=?",[sql_text(boost_id)]); status = 204;
            }
            if status != 404 {
                sql_rows(db,"UPDATE messages SET updated_at=? WHERE id=?",[sql_text(now),sql_text(message_id)]);
                sql_rows(db,"UPDATE rooms SET updated_at=? WHERE id=?",[sql_text(now),sql_text(room)]);
            }
        }
    };
    if failed.len > 0 { for e in failed { write_stderr(str("boost write failed: ",e.message,"\n")); } return 500, 0, [], 0; }
    if status == 201 {
        // broadcast_create: messages/boosts/_boost appended to the message's boosts, keeping the scroll position.
        var bytes: u8[>..] = []; var html: u8[>..] = [];
        let rendered = sqlite::run() {
            let client = sql_value(db,"SELECT client_message_id FROM messages WHERE id=?",[sql_text(message_id)]);
            for boost in load_boosts(db,message_id,avatar_key,bytes) {
                if boost.id == created { let ctx = ViewContext { .. }; render_boost_html(html,ctx,boost); }
            }
            turbo_stream(stream,"append",str("boosts_message_",client),html,true);
        };
        if rendered.len > 0 { return 500, 0, [], 0; }
    } else if status == 204 {
        // broadcast_remove
        turbo_stream(stream,"remove",str("boost_",boost_id));
    }
    return status, room, stream, created;
}

// Messages::BoostsController: /messages/:message_id/boosts (index, new, create) and /boosts/:id (destroy).
fn boost_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], avatar_key: const u8[:], storage_key: const u8[:],
               stream_key: const u8[:], vapid: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    if !starts_with(path,"/messages/") { return false; }
    let rest = path[10..]; let slash = find(rest,"/"); if slash < 0 { return false; }
    let message_id, valid = parse_int(rest[..slash]); let tail = rest[slash..];
    if !valid || !starts_with(tail,"/boosts") { return false; }
    let fresh = tail == "/boosts/new";
    var boost_id: i64 = 0;
    if tail != "/boosts" && !fresh {
        if !starts_with(tail,"/boosts/") { return false; }
        let id, numeric = parse_int(tail[8..]);
        if !numeric || id <= 0 { http::respond(out,404,"text/plain","Not found"); return true; }
        boost_id = id;
    }
    let method = effective_method(req,body);
    let reading = method == "GET" || method == "HEAD";
    // Only index, new, create and destroy have actions (show, edit and update are action_not_found).
    let routed = if boost_id > 0 { method == "DELETE" } else if fresh { reading } else { reading || method == "POST" };
    if !routed { http::respond(out,404,"text/plain","Not found"); return true; }
    if !reading && !same_origin(req) { http::respond(out,422,"text/plain","Invalid origin"); return true; }
    if reading {
        var status: i32 = 404; var bytes: u8[>..] = []; var boosts: BoostView[>..] = []; var content: u8[>..] = [];
        var ctx = ViewContext { .. };
        let failed = sqlite::run() {
            if reachable_message_room(db,user,message_id) > 0 {
                ctx = load_view_context(db,user,avatar_key,stream_key,vapid,req,bytes,storage_key);
                let message, found = load_message_view(db,message_id,avatar_key,storage_key,bytes,boosts);
                if found {
                    if fresh { render_new_boost_html(content,ctx,message); } else { render_boosts_html(content,ctx,message); }
                    status = 200;
                }
            }
        };
        if failed.len > 0 { for e in failed { write_stderr(str("boosts page failed: ",e.message,"\n")); } http::respond(out,500,"text/plain","Database error"); }
        else if status == 200 { ctx.page_content = content; respond_page(out,req,ctx); }
        else { http::respond(out,404,"text/plain","Not found"); }
        return true;
    }
    var content: u8[>..] = [];
    if method == "POST" {
        // params.require(:boost).permit(:content); a missing content would violate the column's NOT NULL.
        if !form_has_prefix(body,"boost[") { http::respond(out,400,"text/plain","Bad request"); return true; }
        if !http::form_value(body,"boost[content]",content) { http::respond(out,422,"text/plain","Boost content is required"); return true; }
    }
    let status, room, stream, created = write_boost(db,user,message_id,0,method == "POST",content,boost_id,avatar_key);
    if status == 201 { redirect_to_path(out,req,str("/messages/",message_id,"/boosts")); }
    else if status == 204 { respond_empty(out,204); }
    else { http::respond(out,status,"text/plain",if status == 404 { "Not found" } else { "Database error" }); }
    if (status == 201 || status == 204) && stream.len > 0 { publish(room,http::later(out,60000),stream); }
    return true;
}

// users/_user.json.jbuilder
fn user_json(out: u8[>..]&, db, id: i64, avatar_key: const u8[:], base: const u8[:]) {
    var bytes: u8[>..] = []; let person = load_user(db,id,avatar_key,bytes);
    let role = sql_number(db,"SELECT role FROM users WHERE id=?",[sql_text(id)]);
    format(out,"{\"id\":",id,",\"name\":"); json_rails(out,person.name);
    out.append(",\"role\":"); json_rails(out,if role == 1 { "administrator" } else if role == 2 { "bot" } else { "member" });
    out.append(",\"avatar_url\":"); json_rails(out,str(base,person.avatar_url)); out.push('}');
}

// messages/_message.json.jbuilder
fn message_json(out: u8[>..]&, db, id: i64, avatar_key: const u8[:], storage_key: const u8[:], base: const u8[:]) {
    let rows = sql_rows(db,"SELECT m.room_id,m.creator_id,m.created_at,idx.body,rt.body,rt.id IS NOT NULL FROM messages m LEFT JOIN message_search_index idx ON idx.rowid=m.id LEFT JOIN action_text_rich_texts rt ON rt.record_id=m.id AND rt.record_type='Message' AND rt.name='body' WHERE m.id=?",[sql_text(id)]);
    for row in rows {
        let room, room_ok = parse_int(cell(row,0)); let creator, creator_ok = parse_int(cell(row,1));
        format(out,"{\"id\":",id,",\"created_at\":"); json_rails(out,json_time(cell(row,2)));
        out.append(",\"body\":{\"plain_text\":"); json_rails(out,cell(row,3));
        var rendered: u8[>..] = [];
        if cell(row,5) == "1" { rendered.append("<div class=\"lexxy-content\">\n  "); rich_sanitize(rendered,expanded_rich_text(db,cell(row,4),avatar_key)); rendered.append("\n</div>\n"); }
        out.append(",\"html\":"); json_rails(out,rendered);
        out.append("},\"creator\":"); user_json(out,db,creator,avatar_key,base);
        format(out,",\"room\":{\"id\":",room,"},\"url\":"); json_rails(out,str(base,"/rooms/",room,"/messages/",id)); out.push('}');
    }
}

// messages/boosts/_boost.json.jbuilder
fn boost_json(out: u8[>..]&, db, id: i64, avatar_key: const u8[:], base: const u8[:]) {
    let rows = sql_rows(db,"SELECT b.content,b.created_at,b.booster_id,b.message_id,m.room_id FROM boosts b JOIN messages m ON m.id=b.message_id WHERE b.id=?",[sql_text(id)]);
    for row in rows {
        let booster, booster_ok = parse_int(cell(row,2));
        format(out,"{\"id\":",id,",\"content\":"); json_rails(out,cell(row,0));
        out.append(",\"created_at\":"); json_rails(out,json_time(cell(row,1)));
        out.append(",\"booster\":"); user_json(out,db,booster,avatar_key,base);
        out.append(",\"message\":{\"id\":"); out.append(cell(row,3)); out.append(",\"url\":"); json_rails(out,str(base,"/rooms/",cell(row,4),"/messages/",cell(row,3))); out.append("}}");
    }
}

// `String#blank?`
fn blank(text: const u8[:]) -> bool {
    for c in text { if c != ' ' && c != '\t' && c != '\n' && c != '\r' && c != 11 && c != 12 { return false; } }
    return true;
}

// A bot key: User#bot_key's <id>-<token> (`authenticate_bot` splits on "-" and uses the first two
// parts), or the bare 64-character token earlier bot lists showed (id 0). Tokens are alphanumeric.
fn bot_key(key: const u8[:]) -> i64, const u8[:], bool {
    let dash = find(key,"-");
    var token = if dash < 0 { key } else { key[dash+1..] };
    let more = find(token,"-"); if more >= 0 { token = token[..more]; }
    if token.len == 0 || token.len > 64 || dash < 0 && token.len != 64 { return 0, "", false; }
    for c in token { if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') { return 0, "", false; } }
    if dash < 0 { return 0, token, true; }
    let id, numbered = parse_int(key[..dash]);
    if !numbered || id <= 0 { return 0, "", false; }
    return id, token, true;
}

// The bot API under /rooms/:room_id/:bot_key/messages (Messages::ByBotsController and
// Messages::Boosts::ByBotsController). Bodies are the raw request body. A key that names no active bot
// leaves the request to session authentication, as `require_authentication` does.
fn bot_route(db: sqlite::Db, writer: const WriterStatements&, req: const http::Request&, body: const u8[:], avatar_key: const u8[:], storage_key: const u8[:], storage: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    if !starts_with(path,"/rooms/") { return false; }
    let rest = path[7..]; let first = find(rest,"/"); if first < 0 { return false; }
    let after_room = rest[first+1..]; let second = find(after_room,"/"); if second < 0 { return false; }
    let key = after_room[..second];
    let tail = after_room[second..];
    if !starts_with(tail,"/messages") { return false; }
    let room, room_valid = parse_int(rest[..first]); if !room_valid { return false; }
    let bot_id, token, keyed = bot_key(key); if !keyed { return false; }
    var bot: i64 = 0;
    let lookup = sqlite::run() {
        bot = if bot_id > 0 { sql_number(db,"SELECT id FROM users WHERE id=? AND bot_token=? AND role=2 AND status=0",[sql_text(bot_id),sql_text(token)]) }
              else { sql_number(db,"SELECT id FROM users WHERE bot_token=? AND role=2 AND status=0",[sql_text(token)]) };
    };
    if lookup.len > 0 { http::respond(out,500,"text/plain","Database error"); return true; }
    if bot == 0 { return false; }
    // /messages, /messages/:id, /messages/:message_id/boosts, /messages/:message_id/boosts/:id
    var message_id: i64 = 0; var boosts = false; var boost_id: i64 = 0; var shape_ok = true;
    if tail != "/messages" {
        if !starts_with(tail,"/messages/") { return false; }
        let parts = split(tail[10..],"/");
        let id, ok = parse_int(parts[0]); shape_ok = ok && id > 0 && parts.len <= 3; message_id = id;
        if shape_ok && parts.len >= 2 { boosts = parts[1] == "boosts"; shape_ok = boosts; }
        if shape_ok && parts.len == 3 { let b, b_ok = parse_int(parts[2]); boost_id = b; shape_ok = b_ok && b > 0; }
    }
    let method = req.method;
    let routed = shape_ok && (if message_id == 0 { method == "GET" || method == "HEAD" || method == "POST" }
        else if !boosts { method == "PUT" || method == "PATCH" || method == "DELETE" }
        else if boost_id == 0 { method == "POST" } else { method == "DELETE" });
    if !routed { respond_empty(out,404); return true; }
    let base = request_base(req);
    var member = false;
    let membership = sqlite::run() { member = sql_number(db,"SELECT count(*) FROM memberships WHERE room_id=? AND user_id=?",[sql_text(room),sql_text(bot)]) > 0; };
    if membership.len > 0 { http::respond(out,500,"text/plain","Database error"); return true; }
    if !member { respond_empty(out,404); return true; }

    if message_id == 0 && method != "POST" {
        bot_index(db,req,room,key,bot,avatar_key,storage_key,base,out); return true;
    }
    if message_id == 0 {
        // create: `ensure_body_or_attachment_present`, then MessagesController#create.
        let kind, has_kind = http::field_of(req,"Content-Type");
        let attaching = has_kind && starts_with(kind,"multipart/form-data");
        if blank(body) { respond_empty(out,422); return true; }
        if body.len > 65536 && !attaching { respond_empty(out,413); return true; }
        var status: i32 = 404; var html: u8[>..] = []; var id: i64 = 0; var posted_ms: i64 = 0;
        let failed = sqlite::run() {
          if attaching {
            // params[:attachment]: curl -F "attachment=@file", as accounts/bots/_bot shows.
            var bytes: u8[>..] = []; var ctx = ViewContext { storage_key: storage_key, .. }; ctx.user = load_user(db,bot,avatar_key,bytes);
            var now: u8[>..] = []; campfire_sql_now(now);
            let created, message = post_attachment(db,writer,req,body,"attachment",bot,room,now,avatar_key,ctx,bytes,storage,html);
            status = created; id = message; posted_ms = campfire_epoch_ms(now);
          } else {
            var adapted = copy(req); adapted.fields = "Content-Type: application/x-www-form-urlencoded\r\n";
            let client = random_token(); var escaped: u8[>..] = []; escape(escaped,body);
            var form: u8[>..] = []; form.append("message%5Bbody%5D="); form_encode(form,escaped); form.append("&message%5Bclient_message_id%5D="); form_encode(form,client);
            var bytes: u8[>..] = []; var ctx = ViewContext { storage_key: storage_key, .. }; ctx.user = load_user(db,bot,avatar_key,bytes);
            var now: u8[>..] = []; campfire_sql_now(now);
            status = post_message(db,writer,adapted,form,bot,room,now,avatar_key,ctx,bytes,0,html,storage); posted_ms = campfire_epoch_ms(now);
            id = sql_number(db,"SELECT id FROM messages WHERE client_message_id=? AND creator_id=?",[sql_text(client),sql_text(bot)]);
          }
        };
        if failed.len > 0 { status = 500; }
        // A video or audio file is processed before the answer and the broadcast, which a media
        // thread then makes; with its queue full, they go at once.
        let deferred = take_deferred_post();
        if status == 200 && deferred.message > 0 && process_posted_later(deferred,POSTED_BOT,http::later(out,MEDIA_POST_WAIT_MS),http::Coding.Identity,base) {
        } else if status == 200 {
            if deferred.message > 0 && deferred.direct { let mentions: i64[>..] = []; deliver_webhooks_later(writer,room,bot,id,true,mentions); }
            http::start(out,201); http::field(out,"Location",str(base,"/messages/",id)); http::finish(out,http::NO_TYPE,"");
            publish(room,http::later(out,60000),html,posted_ms);
        } else { http::respond(out,status,"text/plain","Unable to post bot message"); }
        return true;
    }
    if boosts {
        var content: u8[>..] = [];
        if boost_id == 0 {
            // set_message, then `ensure_content_present`.
            var reachable = false;
            let check = sqlite::run() { reachable = reachable_message_room(db,bot,message_id,room) > 0; };
            if check.len > 0 { http::respond(out,500,"text/plain","Database error"); return true; }
            if !reachable { respond_empty(out,404); return true; }
            if blank(body) { respond_empty(out,422); return true; }
            content.append(body);
        }
        let status, target, stream, created = write_boost(db,bot,message_id,room,boost_id == 0,content,boost_id,avatar_key);
        if status == 201 {
            var json: u8[>..] = [];
            let rendered = sqlite::run() { boost_json(json,db,created,avatar_key,base); };
            if rendered.len > 0 { json.clear(); }
            http::respond(out,201,"application/json; charset=utf-8",json);
        } else if status == 204 { respond_empty(out,204); }
        else if status == 404 { respond_empty(out,404); }
        else { http::respond(out,500,"text/plain","Database error"); }
        if (status == 201 || status == 204) && stream.len > 0 { publish(target,http::later(out,60000),stream); }
        return true;
    }
    // update and destroy: the room's message, which the bot must be able to administer (it created it).
    var status: i32 = 404; var stream: u8[>..] = []; var client: u8[>..] = []; var keys: u8[][>..] = [];
    var text: u8[>..] = []; escape(text,body);
    if text.len > 65536 { respond_empty(out,413); return true; }
    var now: u8[>..] = []; campfire_sql_now(now);
    let failed = write_transaction(db) {
        let rows = sql_rows(db,"SELECT creator_id,client_message_id FROM messages WHERE id=? AND room_id=?",[sql_text(message_id),sql_text(room)]);
        for row in rows {
            client = str(cell(row,1));
            if cell(row,0) != str(bot) { status = 403; }
            else if method == "DELETE" {
                sql_rows(db,"DELETE FROM boosts WHERE message_id=?",[sql_text(message_id)]);
                sql_rows(db,"DELETE FROM message_search_index WHERE rowid=?",[sql_text(message_id)]);
                sql_rows(db,"DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",[sql_text(message_id)]);
                sql_rows(db,"DELETE FROM messages WHERE id=?",[sql_text(message_id)]);
                purge_attachments(db,"record_type='Message' AND name='attachment' AND record_id=?",[sql_text(message_id)],keys);
                sql_rows(db,"UPDATE rooms SET updated_at=? WHERE id=?",[sql_text(now),sql_text(room)]);
                status = 204;
            } else {
                var rich: u8[>..] = []; rich_sanitize(rich,text,false); let plain = rich_plain(rich);
                if sql_number(db,"SELECT count(*) FROM action_text_rich_texts WHERE record_type='Message' AND record_id=? AND name='body'",[sql_text(message_id)]) > 0 {
                    sql_rows(db,"UPDATE action_text_rich_texts SET body=?,updated_at=? WHERE record_type='Message' AND record_id=? AND name='body'",[sql_text(rich),sql_text(now),sql_text(message_id)]);
                } else {
                    sql_rows(db,"INSERT INTO action_text_rich_texts(name,record_type,record_id,body,created_at,updated_at) VALUES('body','Message',?,?,?,?)",[sql_text(message_id),sql_text(rich),sql_text(now),sql_text(now)]);
                }
                sql_rows(db,"DELETE FROM message_search_index WHERE rowid=?",[sql_text(message_id)]);
                sql_rows(db,"INSERT INTO message_search_index(rowid,body) VALUES(?,?)",[sql_text(message_id),sql_text(plain)]);
                sql_rows(db,"UPDATE messages SET updated_at=? WHERE id=?",[sql_text(now),sql_text(message_id)]);
                sql_rows(db,"UPDATE rooms SET updated_at=? WHERE id=?",[sql_text(now),sql_text(room)]);
                status = 200;
            }
        }
    };
    if failed.len > 0 { for e in failed { write_stderr(str("bot message write failed: ",e.message,"\n")); } http::respond(out,500,"text/plain","Database error"); return true; }
    if status == 403 || status == 404 { respond_empty(out,status); return true; }
    if status == 204 {
        delete_blob_files(storage,keys);
        turbo_stream(stream,"remove",str("message_",client));
        respond_empty(out,204);
    } else {
        var json: u8[>..] = [];
        let rendered = sqlite::run() {
            message_json(json,db,message_id,avatar_key,storage_key,base);
            var bytes: u8[>..] = []; var boosts_view: BoostView[>..] = [];
            var ctx = ViewContext { storage_key: storage_key, .. }; ctx.user = load_user(db,bot,avatar_key,bytes);
            let message, found = load_message_view(db,message_id,avatar_key,storage_key,bytes,boosts_view);
            if found { var html: u8[>..] = []; render_message_html(html,ctx,message); turbo_stream(stream,"replace",message.dom_id,html); }
        };
        if rendered.len > 0 { http::respond(out,500,"text/plain","Database error"); return true; }
        http::respond(out,200,"application/json; charset=utf-8",json);
    }
    if stream.len > 0 { publish(room,http::later(out,60000),stream); }
    return true;
}

// Messages::ByBotsController#index: a page of 40 messages (before or after a message, else the last), with
// the room's message count and a link to the next page.
fn bot_index(db: sqlite::Db, req: const http::Request&, room: i64, key: const u8[:], bot: i64, avatar_key: const u8[:], storage_key: const u8[:],
             base: const u8[:], out: http::Reply) {
    var before_raw: u8[>..] = []; var after_raw: u8[>..] = [];
    let before_text, has_before = http::query_of(req.target,"before"); if has_before { http::decode(before_text,before_raw,true); }
    let after_text, has_after = http::query_of(req.target,"after"); if has_after { http::decode(after_text,after_raw,true); }
    let before_present = !blank(before_raw); let after_present = !blank(after_raw);
    var status: i32 = 200; var json: u8[>..] = []; var total: i64 = 0; var link: u8[>..] = [];
    let failed = sqlite::run() {
        var anchor: u8[>..] = [];
        if before_present || after_present {
            let id, valid = parse_int(trim(if before_present { before_raw } else { after_raw }));
            anchor = sql_value(db,"SELECT created_at FROM messages WHERE id=? AND room_id=?",[sql_text(if valid { id } else { 0 }),sql_text(room)]);
            if anchor.len == 0 { status = 404; }
        }
        if status == 200 {
            let rows = if before_present {
                sql_rows(db,"SELECT id FROM (SELECT id,created_at FROM messages WHERE room_id=? AND created_at<? ORDER BY created_at DESC LIMIT 40) ORDER BY created_at",[sql_text(room),sql_text(anchor)])
            } else if after_present {
                sql_rows(db,"SELECT id FROM messages WHERE room_id=? AND created_at>? ORDER BY created_at LIMIT 40",[sql_text(room),sql_text(anchor)])
            } else {
                sql_rows(db,"SELECT id FROM (SELECT id,created_at FROM messages WHERE room_id=? ORDER BY created_at DESC LIMIT 40) ORDER BY created_at",[sql_text(room)])
            };
            json.push('[');
            for row, i in rows {
                let id, valid = parse_int(cell(row,0));
                if i > 0 { json.push(','); }
                message_json(json,db,id,avatar_key,storage_key,base);
            }
            json.push(']');
            total = sql_number(db,"SELECT count(*) FROM messages WHERE room_id=?",[sql_text(room)]);
            if rows.len > 0 {
                if after_present {
                    let last = rows_col(rows,rows.len-1,0);
                    if sql_number(db,"SELECT count(*) FROM messages WHERE room_id=? AND created_at>(SELECT created_at FROM messages WHERE id=?)",[sql_text(room),sql_text(last)]) > 0 {
                        link = str("<",base,"/rooms/",room,"/",key,"/messages?after=",last,">; rel=\"next\"");
                    }
                } else {
                    let first = rows_col(rows,0,0);
                    if sql_number(db,"SELECT count(*) FROM messages WHERE room_id=? AND created_at<(SELECT created_at FROM messages WHERE id=?)",[sql_text(room),sql_text(first)]) > 0 {
                        link = str("<",base,"/rooms/",room,"/",key,"/messages?before=",first,">; rel=\"next\"");
                    }
                }
            }
        }
    };
    if failed.len > 0 { http::respond(out,500,"text/plain","Database error"); return; }
    if status != 200 { http::respond(out,404,"text/plain","Not found"); return; }
    http::start(out,200);
    http::field(out,"X-Total-Count",str(total));
    if link.len > 0 { http::field(out,"Link",link); }
    http::field(out,"Content-Type","application/json; charset=utf-8");
    http::finish(out,http::NO_TYPE,json);
}
