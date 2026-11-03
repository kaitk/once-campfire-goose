namespace campfire;
import std;
import http;
import sqlite;
import database;
import messages;
import rich_html;
import html;
import cable;
import view_data;
import view_types;
import views_generated;
import storage;

fn message_actions(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], key: const u8[:], avatar_key: const u8[:], storage: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    if !starts_with(path,"/rooms/") { return false; }
    let tail = path[7..]; let slash = find(tail,"/"); if slash < 0 { return false; }
    let room, valid = parse_int(tail[..slash]); if !valid { return false; }
    let action = tail[slash..];
    if !starts_with(action,"/messages/") { return false; }
    let rest = action[10..]; let end = find(rest,"/");
    let id, parsed = parse_int(if end < 0 { rest } else { rest[..end] });
    if !parsed || end >= 0 && rest[end..] != "/edit" { return false; }
    var method: u8[>..] = []; method.append(req.method);
    if method == "POST" { var override: u8[>..] = []; if http::form_value(body,"_method",override) { method = str(if override == "patch" { "PATCH" } else if override == "delete" { "DELETE" } else { "POST" }); } }
    let writing = method == "PATCH" || method == "DELETE";
    if writing && !same_origin(req) { http::respond(out,422,"text/plain","Invalid origin"); return true; }
    var status: i32 = 404; var content: u8[>..] = []; var q = sqlite::Stmt {}; var keys: u8[][>..] = [];
    if writing { campfire_writer_enter(); }
    let failed = sqlite::run() {
        if writing { sqlite::exec(db,"BEGIN IMMEDIATE"); }
        let allowed = sql_number(db,"SELECT count(*) FROM messages m JOIN memberships mm ON mm.room_id=m.room_id JOIN users u ON u.id=mm.user_id WHERE m.id=? AND m.room_id=? AND u.id=? AND u.status=0 AND (m.creator_id=u.id OR u.role=1)",[sql_text(id),sql_text(room),sql_text(user)]) > 0;
        if allowed {
            if writing {
                var now: u8[>..] = []; campfire_sql_now(now);
                if method == "DELETE" {
                    let rows = sql_rows(db,"SELECT client_message_id FROM messages WHERE id=?",[sql_text(id)]);
                    for row in rows { for client in row { format(content,"<turbo-stream action=\"remove\" target=\"message_"); escape(content,client); content.append("\"></turbo-stream>"); } }
                    sql_rows(db,"DELETE FROM boosts WHERE message_id=?",[sql_text(id)]);
                    sql_rows(db,"DELETE FROM message_search_index WHERE rowid=?",[sql_text(id)]);
                    sql_rows(db,"DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",[sql_text(id)]);
                    sql_rows(db,"DELETE FROM messages WHERE id=?",[sql_text(id)]);
                    purge_attachments(db,"record_type='Message' AND name='attachment' AND record_id=?",[sql_text(id)],keys);
                    status = 200;
                } else {
                    var text: u8[>..] = [];
                    if http::form_value(body,"message[body]",text) && text.len > 0 && text.len <= 65536 {
                        var rich: u8[>..] = []; rich_sanitize(rich,text,false); let plain = rich_plain(rich);
                        sql_rows(db,"UPDATE action_text_rich_texts SET body=?,updated_at=? WHERE record_type='Message' AND record_id=?",[sql_text(rich),sql_text(now),sql_text(id)]);
                        sql_rows(db,"UPDATE message_search_index SET body=? WHERE rowid=?",[sql_text(plain),sql_text(id)]);
                        sql_rows(db,"UPDATE messages SET updated_at=? WHERE id=?",[sql_text(now),sql_text(id)]);
                        status = 200;
                    } else { status = 422; }
                }
                if status == 200 { sql_rows(db,"UPDATE rooms SET updated_at=? WHERE id=?",[sql_text(now),sql_text(room)]); }
            } else if method == "GET" { status = 200; }
            if status == 200 && method != "DELETE" {
                q = sqlite::prepare(db,"SELECT m.client_message_id,rt.body FROM messages m JOIN action_text_rich_texts rt ON rt.record_id=m.id AND rt.record_type='Message' WHERE m.id=?"); sqlite::bind_i64(q,1,id);
                if sqlite::step(q) {
                    let client = view_text(q,0); let rich = view_text(q,1);
                    if writing {
                        content.append("<turbo-stream action=\"replace\" target=\"presentation_message_"); escape(content,client);
                        content.append("\" maintain_scroll=\"true\"><template><div id=\"presentation_message_"); escape(content,client);
                        content.append("\" dir=\"auto\" data-reply-target=\"body\" data-messages-target=\"body\">");
                        content.append(text_presentation(db,rich,rich_plain(rich),key)); content.append("</div></template></turbo-stream>");
                    } else {
                        content.append("<turbo-frame id=\"edit_message_"); escape(content,client); content.append("\">");
                        if end >= 0 {
                            format(content,"<form data-controller=\"form\" action=\"/rooms/",room,"/messages/",id,"\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\"><lexxy-editor aria-label=\"Edit message\" name=\"message[body]\" value=\"");
                            escape(content,rich); content.append("\"></lexxy-editor><button type=\"submit\">Save changes</button></form>");
                        }
                        content.append("</turbo-frame>");
                    }
                }
            }
        }
        if writing { sqlite::exec(db,"COMMIT"); }
    };
    sqlite::finalize(q);
    if writing {
        let cleanup = sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db,"ROLLBACK"); } };
        campfire_writer_leave();
    }
    if failed.len > 0 { status = 500; }
    // The destroyed message's attachment: has_one_attached purges its blob once the deletion commits.
    if status == 200 && method == "DELETE" { delete_blob_files(storage,keys); }
    if status==200 && (method=="PATCH" || method=="GET" && end<0) {
        content.clear();
        let rendered=sqlite::run() {
            var bytes: u8[>..]=[]; var boosts: BoostView[>..]=[];
            var ctx=ViewContext {storage_key:key,..}; ctx.user=load_user(db,user,avatar_key,bytes);
            q=sqlite::prepare(db,"SELECT m.id,m.client_message_id,u.name,idx.body,rt.body,m.creator_id,m.created_at,m.updated_at,m.room_id,r.name,r.type FROM messages m JOIN rooms r ON r.id=m.room_id JOIN users u ON u.id=m.creator_id LEFT JOIN message_search_index idx ON idx.rowid=m.id LEFT JOIN action_text_rich_texts rt ON rt.record_id=m.id AND rt.record_type='Message' WHERE m.id=?"); sqlite::bind_i64(q,1,id);
            if sqlite::step(q) {
                let message=message_view(db,q,avatar_key,key,bytes,boosts);
                if writing {content.append("<turbo-stream action=\"replace\" target=\"");escape(content,message.dom_id);content.append("\"><template>");}
                render_message_html(content,ctx,message);
                if writing {content.append("</template></turbo-stream>");}
            }
        };
        sqlite::finalize(q); if rendered.len>0 {status=500;}
    }
    http::respond(out,status,if writing { "text/vnd.turbo-stream.html; charset=utf-8" } else { "text/html; charset=utf-8" },if status == 200 { content } else { "Unable to load message" });
    if writing && status == 200 { publish(room,http::later(out,60000),content); }
    return true;
}

// Rooms::RefreshesController#show: the first PAGE_SIZE messages created since `since` (in ms),
// appended, then the last PAGE_SIZE others updated since, replaced, as refreshes/show.turbo_stream
// renders them byte for byte (an empty refresh is "\n").
fn refresh_room(db, user: i64, room: i64, since: i64, key: const u8[:], ctx: ViewContext, bytes: u8[>..]&, out: u8[>..]&) -> i32 {
    if sql_number(db,"SELECT count(*) FROM memberships WHERE user_id=? AND room_id=?",[sql_text(user),sql_text(room)]) == 0 { return 404; }
    // Time.at(0, since, :millisecond), within the years SQLite's strftime formats.
    var seconds=since/1000; var ms=since%1000; if ms<0 { ms+=1000; seconds-=1; }
    if seconds < -62135596800 { seconds=-62135596800; ms=0; } else if seconds > 253402300799 { seconds=253402300799; ms=999; }
    var q = sqlite::Stmt {}; var boosts: BoostView[>..] = [];
    var created: u8[>..] = []; var updated: u8[>..] = [];
    let failed = sqlite::run() {
        q = sqlite::prepare(db,"WITH t(at) AS (SELECT strftime('%Y-%m-%d %H:%M:%S',?2,'unixepoch')||printf('.%03d000',?3)), created(id) AS (SELECT id FROM messages,t WHERE room_id=?1 AND created_at>t.at ORDER BY created_at LIMIT 40), changed(id) AS (SELECT id FROM messages,t WHERE room_id=?1 AND updated_at>t.at AND id NOT IN (SELECT id FROM created) ORDER BY created_at DESC LIMIT 40) SELECT m.id,m.client_message_id,u.name,idx.body,rt.body,m.creator_id,m.created_at,m.updated_at,m.room_id,r.name,r.type,m.id IN (SELECT id FROM created) FROM messages m JOIN rooms r ON r.id=m.room_id JOIN users u ON u.id=m.creator_id LEFT JOIN message_search_index idx ON idx.rowid=m.id LEFT JOIN action_text_rich_texts rt ON rt.record_id=m.id AND rt.record_type='Message' WHERE m.id IN (SELECT id FROM created) OR m.id IN (SELECT id FROM changed) ORDER BY m.created_at,m.id");
        sqlite::bind_i64(q,1,room); sqlite::bind_i64(q,2,seconds); sqlite::bind_i64(q,3,ms);
        while sqlite::step(q) {
            ctx.room.kind = if view_text(q,10) == "Rooms::Open" { "rooms_open" } else if view_text(q,10) == "Rooms::Closed" { "rooms_closed" } else { "rooms_direct" };
            let message = message_view(db,q,key,ctx.storage_key,bytes,boosts);
            if sqlite::column_i64(q,11) != 0 { render_message_html(created,ctx,message); }
            else {
                updated.append("  <turbo-stream action=\"replace\" target=\""); escape(updated,message.dom_id); updated.append("\"><template>");
                render_message_html(updated,ctx,message); updated.append("</template></turbo-stream>\n");
            }
        }
    };
    sqlite::finalize(q); for e in failed { sqlite::fail(e.code,e.message); }
    if created.len > 0 {
        out.append("<turbo-stream action=\"append\" target=\""); html_value(out, room_dom_id(ctx.room.kind, room, "messages"));
        out.append("\"><template>\n  "); out.append(created); out.append("\n</template></turbo-stream>");
    }
    out.push('\n'); out.append(updated); return 200;
}
