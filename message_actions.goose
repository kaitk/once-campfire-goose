namespace campfire;
import std;
import public_pages;
import http;
import etag;
import sqlite;
import database;
import messages;
import rich_html;
import html;
import cable;
import signed_id;
import view_data;
import view_types;
import view_helpers;
import views_generated;
import storage;
import route_support;
import admin_routes;
import browser_routes;
import webhooks;

// The formats a request accepts, as Rails reads its Accept header (or the path's extension): each
// acceptable format's letter in Accept order, h(tml), t(urbo stream), j(son) or *(any). No Accept
// header, or a browser's (*/* beside other types), is HTML alone.
fn request_accepts(req: const http::Request&, extension: const u8[:]) -> u8[>..] {
    var order: u8[>..] = [];
    if extension.len > 0 {
        order.append(if extension == "html" { "h" } else if extension == "json" { "j" } else if extension == "turbo_stream" { "t" } else { "" });
        return order;
    }
    let accept, has_accept = http::field_of(req, "Accept");
    let browser = has_accept && find(accept, "*/*") >= 0 && find(accept, ",") >= 0;
    if !has_accept || trim(accept).len == 0 || browser { order.push('h'); return order; }
    for part in split(accept, ',') {
        let semi = find(part, ";");
        let media = html_lower(trim(if semi < 0 { part } else { part[..semi] }));
        if media == "text/html" || media == "application/xhtml+xml" { order.push('h'); }
        else if media == "text/vnd.turbo-stream.html" { order.push('t'); }
        else if media == "application/json" || media == "text/x-json" || media == "application/jsonrequest" { order.push('j'); }
        else if media == "*/*" { order.push('*'); }
    }
    return order;
}

// messages/_presentation as `broadcast_replace_to ... target: [ message, :presentation ],
// attributes: { maintain_scroll: true }` sends it; empty when the message is gone.
fn presentation_stream(db: sqlite::Db, id: i64, avatar_key: const u8[:], storage_key: const u8[:]) -> u8[>..] {
    var out: u8[>..] = []; var bytes: u8[>..] = []; var boosts: BoostView[>..] = [];
    let message, found = load_message_view(db,id,avatar_key,storage_key,bytes,boosts);
    if !found { return out; }
    let target = prefixed_id(message.dom_id,"presentation");
    out.append("<turbo-stream maintain_scroll=\"true\" action=\"replace\" target=\""); escape(out,target);
    out.append("\"><template><div id=\""); escape(out,target);
    out.append("\" dir=\"auto\" data-reply-target=\"body\" data-messages-target=\"body\">\n  ");
    out.append(message.presentation); out.append("\n</div>\n</template></turbo-stream>");
    return out;
}

// The editor's form, as Lexxy's escaped attribute value carries it.
fn html5_attribute(out: u8[>..]&, value: const u8[:]) {
    var i: i64 = 0;
    while i < value.len {
        let c = value[i];
        if c == '&' { out.append("&amp;"); } else if c == '"' { out.append("&quot;"); }
        else if c == 0xC2 && i+1 < value.len && value[i+1] == 0xA0 { out.append("&nbsp;"); i += 1; }
        else { out.push(c); }
        i += 1;
    }
}

fn html5_text(out: u8[>..]&, value: const u8[:]) {
    var i: i64 = 0;
    while i < value.len {
        let c = value[i];
        if c == '&' { out.append("&amp;"); } else if c == '<' { out.append("&lt;"); } else if c == '>' { out.append("&gt;"); }
        else if c == 0xC2 && i+1 < value.len && value[i+1] == 0xA0 { out.append("&nbsp;"); i += 1; }
        else { out.push(c); }
        i += 1;
    }
}

// The mention partial (users/_mention), as render_action_text_attachment renders a User.
fn mention_editor_html(out: u8[>..]&, user: const UserView&, sgid: const u8[:]) {
    out.append("<span class=\"mention\" sgid=\""); escape(out,sgid); out.append("\"><a title=\""); escape(out,user.title);
    out.append("\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\""); escape(out,user.path);
    out.append("\"><img aria-hidden=\"true\" src=\""); escape(out,user.avatar_url); out.append("\" width=\"48\" height=\"48\" /></a> ");
    escape(out,user.name); out.append("</span>");
}

// RichTextHelper#editable_body, then Lexxy's value: each attachment rebuilt from its attachable, its
// rendered partial as the content (a JSON string unless the node has a url), on the stored markup
// serialized as Nokogiri does. False when it's blank (the editor then has no value).
fn editable_body(db: sqlite::Db, rich: const u8[:], avatar_key: const u8[:], sgid_key: const u8[:]) -> u8[>..], bool {
    var out: u8[>..] = []; var i: i64 = 0;
    while i < rich.len {
        if rich[i] != '<' {
            var end = i + 1; while end < rich.len && rich[end] != '<' { end += 1; }
            html5_text(out,html_decode(rich[i..end])); i = end; continue;
        }
        var attrs: RichAttr[>..] = []; let tag = rich_tag(rich,i,attrs); let name = html_lower(tag.name);
        if name.len == 0 { html5_text(out,rich[i..tag.end]); i = tag.end; continue; }
        if tag.closing { format(out,"</",name,">"); i = tag.end; continue; }
        if name == "action-text-attachment" {
            let close = find(rich[tag.end..],"</action-text-attachment>");
            let after = if close < 0 { tag.end } else { tag.end + close + 25 };
            let content_type = html_decode(rich_attribute(attrs,"content-type"));
            var partial: u8[>..] = []; var kind: u8[>..] = []; var keep = true;
            if find(content_type,OPENGRAPH_EMBED_TYPE) >= 0 {
                let embed = og_embed_from_node(attrs,""); og_embed_html(partial,embed); kind = str(OPENGRAPH_EMBED_TYPE);
            } else {
                let sgid = html_decode(rich_attribute(attrs,"sgid"));
                var bytes: u8[>..] = [];
                let user = load_user(db,mention_id(sgid),avatar_key,bytes);
                if user.id > 0 { mention_editor_html(partial,user,attachable_sgid(user.id,sgid_key)); kind = str(MENTION_TYPE); }
                else { keep = false; }
            }
            if keep {
                var content: u8[>..] = [];
                if trim(html_decode(rich_attribute(attrs,"url"))).len > 0 { content.append(partial); } else { json_rails(content,partial); }
                out.append("<action-text-attachment"); var typed = false; var contented = false;
                for a in attrs {
                    let attr = html_lower(a.name);
                    format(out," ",attr,"=\"");
                    if attr == "content-type" { html5_attribute(out,kind); typed = true; }
                    else if attr == "content" { html5_attribute(out,content); contented = true; }
                    else { html5_attribute(out,html_decode(a.value)); }
                    out.push('"');
                }
                if !typed { out.append(" content-type=\""); html5_attribute(out,kind); out.push('"'); }
                if !contented { out.append(" content=\""); html5_attribute(out,content); out.push('"'); }
                out.append("></action-text-attachment>");
            }
            i = after; continue;
        }
        format(out,"<",name);
        for a in attrs { format(out," ",html_lower(a.name),"=\""); html5_attribute(out,html_decode(a.value)); out.push('"'); }
        out.push('>'); i = tag.end;
    }
    return out, trim(out).len > 0;
}

// messages/edit.html.erb
fn render_message_edit(out: u8[>..]&, ctx: const ViewContext&, message: const MessageView&, room: i64, value: const u8[:], has_value: bool) {
    let path = str("/rooms/",room,"/messages/",message.id);
    let delete_form = prefixed_id(message.dom_id,"delete_form");
    out.append("<turbo-frame id=\""); escape(out,prefixed_id(message.dom_id,"edit"));
    out.append("\">\n  <div class=\"message__body position-relative\" data-controller=\"scroll-into-view\">\n    <div class=\"message__body-content message__body-content--editing gap\">\n");
    if message.has_attachment {
        out.append("        "); out.append(message.presentation);
        out.append("\n\n        <div class=\"message__edit-btns flex align-center justify-space-between gap full-width pad-block-start-half\">\n          <button name=\"button\" type=\"submit\" class=\"btn btn--negative center margin-block-end\" form=\"");
        escape(out,delete_form); out.append("\" data-turbo-confirm=\"Are you sure you want to delete this message?\">\n            ");
        out.append(image_html("trash.svg",[html_attr("aria-hidden","true")]));
        out.append("\n            <span class=\"for-screen-reader\">Delete message</span>\n</button>        </div>\n");
    } else {
        out.append("        <div class=\"composer--edit composer--rich-text\">\n          <form id=\""); escape(out,prefixed_id(message.dom_id,"form"));
        out.append("\" data-controller=\"form\" data-action=\"lexxy:file-accept-&gt;form#preventAttachment keydown.esc-&gt;form#cancel keydown.ctrl+enter-&gt;form#submit:prevent keydown.meta+enter-&gt;form#submit:prevent\" action=\"");
        escape(out,path); out.append("\" accept-charset=\"UTF-8\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\" />\n            <div class=\"full-width input input--actor min-width fill-white\">\n              <lexxy-editor rows=\"1\" class=\"input lexxy-content\" aria-multiline=\"true\" aria-label=\"Edit message\" autofocus=\"autofocus\" permitted-attachment-types=\"application/vnd.campfire.mention application/vnd.actiontext.opengraph-embed\" data-action=\"lexxy:change-&gt;typing-notifications#start keydown-&gt;composer#submitByKeyboard:capture\" data-direct-upload-url=\"");
        escape(out,str(ctx.base_url,"/rails/active_storage/direct_uploads")); out.append("\" data-blob-url-template=\"");
        escape(out,str(ctx.base_url,"/rails/active_storage/blobs/redirect/:signed_id/:filename")); out.append("\" id=\"message_body\" input=\"message_body_trix_input_");
        escape(out,message.dom_id); out.append("\" name=\"message[body]\"");
        if has_value { out.append(" value=\""); escape(out,value); out.push('"'); }
        out.append(">\n                <lexxy-prompt trigger=\"@\" name=\"mention\" src=\""); escape(out,mention_prompt_url(room));
        out.append("\" remote-filtering=\"true\" empty-results=\"No matches\"></lexxy-prompt>\n</lexxy-editor>            </div>\n\n            <a data-form-target=\"cancel\" hidden=\"hidden\" href=\"");
        escape(out,path); out.append("\">Close editor and discard changes</a>\n\n            <div class=\"message__edit-btns flex align-center justify-space-between gap full-width pad-block-start-half\">\n              <button name=\"button\" type=\"submit\" class=\"btn btn--reversed\">\n                ");
        out.append(image_html("check.svg",[html_attr("aria-hidden","true")]));
        out.append("\n                <span class=\"for-screen-reader\">Save changes</span>\n</button>\n              <button name=\"button\" type=\"submit\" class=\"btn btn--negative\" form=\"");
        escape(out,delete_form); out.append("\" data-turbo-confirm=\"Are you sure you want to delete this message?\">\n                ");
        out.append(image_html("trash.svg",[html_attr("aria-hidden","true")]));
        out.append("\n                <span class=\"for-screen-reader\">Delete message</span>\n</button>            </div>\n</form>        </div>\n");
    }
    out.append("    </div>\n\n    <div class=\"message__actions flex flex-wrap\">\n      <a class=\"message__action-btn message__edit-close-btn txt-small btn btn--borderless\" href=\"");
    escape(out,path); out.append("\">\n        "); out.append(image_html("remove.svg",[html_attr("class","colorize--black"),html_attr("aria-hidden","true")]));
    out.append("\n        <span class=\"for-screen-reader\">Close editor and discard changes</span>\n</a>    </div>\n\n    <form id=\"");
    escape(out,delete_form); out.append("\" data-turbo-frame=\""); escape(out,prefixed_id(message.dom_id,"edit"));
    out.append("\" action=\""); escape(out,path); out.append("\" accept-charset=\"UTF-8\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"delete\" />\n  </div>\n</turbo-frame>\n");
}

// MessagesController#show, #edit, #update and #destroy (/rooms/:room_id/messages/:id[/edit]).
fn message_actions(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], key: const u8[:], avatar_key: const u8[:], storage: const u8[:],
                   stream_key: const u8[:], vapid: const u8[:], sgid_key: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    if !starts_with(path,"/rooms/") { return false; }
    let tail = path[7..]; let slash = find(tail,"/"); if slash < 0 { return false; }
    let room, valid = parse_int(tail[..slash]); if !valid { return false; }
    let action = tail[slash..];
    if !starts_with(action,"/messages/") { return false; }
    let rest = action[10..]; let end = find(rest,"/");
    let editing = end >= 0;
    if editing && !starts_with(rest[end..],"/edit") { return false; }
    // The id, or "edit", may carry a format: /rooms/1/messages/2.json
    var segment = if editing { rest[end+1..] } else { rest };
    if editing && segment != "edit" && !starts_with(segment,"edit.") { return false; }
    let dot = find(segment,".");
    let extension = if dot >= 0 { segment[dot+1..] } else { segment[..0] };
    let id_text = if editing { rest[..end] } else if dot >= 0 { rest[..dot] } else { rest };
    let id, parsed = parse_int(id_text);
    if !parsed || find(id_text,".") >= 0 || find(extension,"/") >= 0 { return false; }
    let method = effective_method(req,body);
    let reading = method == "GET" || method == "HEAD";
    let routed = if editing { reading } else { reading || method == "PATCH" || method == "PUT" || method == "DELETE" };
    if !routed { routing_error(out,req); return true; }
    if !reading && !same_origin(req) { public_exception(out,req,422); return true; }
    let accepts = request_accepts(req,extension);

    // RoomScoped#set_room, set_message and ensure_can_administer.
    var found: i32 = 0;
    let checked = sqlite::run() {
        if sql_number(db,"SELECT count(*) FROM memberships WHERE room_id=? AND user_id=?",[sql_text(room),sql_text(user)]) == 0 { found = 404; }
        else if sql_number(db,"SELECT count(*) FROM messages WHERE id=? AND room_id=?",[sql_text(id),sql_text(room)]) == 0 { found = 404; }
        else if (editing || !reading) && sql_number(db,"SELECT count(*) FROM messages m JOIN users u ON u.id=? WHERE m.id=? AND (u.role=1 OR m.creator_id=u.id)",[sql_text(user),sql_text(id)]) == 0 { found = 403; }
        else { found = 200; }
    };
    if checked.len > 0 { public_exception(out,req,500); return true; }
    if found == 404 { public_exception(out,req,404); return true; }
    if found == 403 { respond_head(out,req,403); return true; }

    if reading {
        // show and edit render HTML in the application layout (`layout false, only: :index` sets it
        // for every other action, so a Turbo-Frame request gets it too).
        if find(accepts,"h") < 0 && find(accepts,"*") < 0 { public_exception(out,req,406); return true; }
        var content: u8[>..] = []; var bytes: u8[>..] = []; var boosts: BoostView[>..] = []; var ctx = ViewContext { .. };
        let rendered = sqlite::run() {
            ctx = load_view_context(db,user,avatar_key,stream_key,vapid,req,bytes,key);
            let message, exists = load_message_view(db,id,avatar_key,key,bytes,boosts);
            if exists {
                if editing {
                    let rich = sql_value(db,"SELECT body FROM action_text_rich_texts WHERE record_type='Message' AND record_id=? AND name='body'",[sql_text(id)]);
                    let value, has_value = editable_body(db,rich,avatar_key,sgid_key);
                    render_message_edit(content,ctx,message,room,value,has_value);
                } else { render_message_html(content,ctx,message); content.push('\n'); }
            }
        };
        if rendered.len > 0 { for e in rendered { write_stderr(str("message page failed: ",e.message,"\n")); } public_exception(out,req,500); return true; }
        ctx.page_content = content; var page: u8[>..] = []; render_page_html(page,ctx);
        respond_rack(out,req,200,"text/html; charset=utf-8",page);
        return true;
    }

    var status: i32 = 200; var stream: u8[>..] = []; var keys: u8[][>..] = [];
    var text: u8[>..] = []; var has_text = false;
    if method != "DELETE" {
        // params.require(:message).permit(:body, :attachment, :client_message_id)
        if !form_has_prefix(body,"message[") { public_exception(out,req,400); return true; }
        has_text = http::form_value(body,"message[body]",text);
        if text.len > 65536 { http::respond(out,413,"text/plain","Message too long"); return true; }
    }
    let host, has_host = http::field_of(req,"Host");
    var now: u8[>..] = []; campfire_sql_now(now);
    let failed = write_transaction(db) {
        if method == "DELETE" {
            turbo_stream(stream,"remove",str("message_",id));
            sql_rows(db,"DELETE FROM boosts WHERE message_id=?",[sql_text(id)]);
            sql_rows(db,"DELETE FROM message_search_index WHERE rowid=?",[sql_text(id)]);
            sql_rows(db,"DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",[sql_text(id)]);
            sql_rows(db,"DELETE FROM messages WHERE id=?",[sql_text(id)]);
            purge_attachments(db,"record_type='Message' AND name='attachment' AND record_id=?",[sql_text(id)],keys);
        } else if has_text {
            var rich: u8[>..] = []; var mentions: i64[>..] = [];
            var plain = message_body(db,text,sgid_key,rich,mentions,host);
            // plain_text_body: the body's text, or the attachment's filename.
            if plain.len == 0 { plain = sql_value(db,"SELECT b.filename FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='Message' AND a.name='attachment' AND a.record_id=?",[sql_text(id)]); }
            if sql_number(db,"SELECT count(*) FROM action_text_rich_texts WHERE record_type='Message' AND record_id=? AND name='body'",[sql_text(id)]) > 0 {
                sql_rows(db,"UPDATE action_text_rich_texts SET body=?,updated_at=? WHERE record_type='Message' AND record_id=? AND name='body'",[sql_text(rich),sql_text(now),sql_text(id)]);
            } else {
                sql_rows(db,"INSERT INTO action_text_rich_texts(name,record_type,record_id,body,created_at,updated_at) VALUES('body','Message',?,?,?,?)",[sql_text(id),sql_text(rich),sql_text(now),sql_text(now)]);
            }
            sql_rows(db,"DELETE FROM message_search_index WHERE rowid=?",[sql_text(id)]);
            sql_rows(db,"INSERT INTO message_search_index(rowid,body) VALUES(?,?)",[sql_text(id),sql_text(plain)]);
            sql_rows(db,"UPDATE messages SET updated_at=? WHERE id=?",[sql_text(now),sql_text(id)]);
        }
        sql_rows(db,"UPDATE rooms SET updated_at=? WHERE id=?",[sql_text(now),sql_text(room)]);
    };
    if failed.len > 0 { for e in failed { write_stderr(str("message write failed: ",e.message,"\n")); } public_exception(out,req,500); return true; }
    if method == "DELETE" {
        // Message#destroy purges the attachment once it commits, then destroy.turbo_stream.erb.
        delete_blob_files(storage,keys);
        if find(accepts,"t") >= 0 || find(accepts,"*") >= 0 { http::respond(out,200,"text/vnd.turbo-stream.html; charset=utf-8",str(stream,"\n")); }
        else { public_exception(out,req,406); }
    } else {
        let rendered = sqlite::run() { stream = presentation_stream(db,id,avatar_key,key); };
        if rendered.len > 0 { stream.clear(); }
        // respond_to html: redirect to the message; json: `render :show`, which has no JSON template.
        var chosen: u8 = 0;
        for c in accepts { if chosen == 0 && (c == 'h' || c == 'j' || c == '*') { chosen = c; } }
        if chosen == 'h' || chosen == '*' { redirect_to_path(out,req,str("/rooms/",room,"/messages/",id)); }
        else if chosen == 'j' { public_exception(out,req,500); }
        else { public_exception(out,req,406); }
    }
    if stream.len > 0 { publish(room,http::later(out,60000),stream); }
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
