namespace campfire;
import std;
import http;
import sqlite;
import database;
import html;
import messages;
import sessions;
import browser_routes;
import view_types;
import view_data;
import views_generated;
import checkpoints;

// Column i of a query row: rows hold variable-size values, which can only be iterated.
fn col(row, i: i64) -> u8[] {
    for value, k in row { if k == i { return copy(value); } }
    return [];
}

// Column i of row r.
fn rows_col(rows, r: i64, i: i64) -> u8[] {
    for row, k in rows { if k == r { return col(row,i); } }
    return [];
}

// The request's method after Rails' `_method` override, which forms send with POST.
fn method_of(req: const http::Request&, body: const u8[:]) -> u8[] {
    if req.method == "POST" {
        var override: u8[>..] = [];
        if http::form_value(body,"_method",override) {
            if override == "patch" || override == "PATCH" { return "PATCH"; }
            if override == "put" || override == "PUT" { return "PUT"; }
            if override == "delete" || override == "DELETE" { return "DELETE"; }
        }
    }
    return str(req.method);
}

// `redirect_to url`: Rails answers 302 with an absolute Location.
fn redirect_found(out: http::Reply, req: const http::Request&, path: const u8[:], cookie: const u8[:] = "") {
    http::start(out,302); http::field(out,"Location",str(request_base(req),path));
    if cookie.len > 0 { http::field(out,"Set-Cookie",cookie); }
    http::finish(out,http::TEXT,"Redirecting");
}

// `head status`
fn respond_empty(out: http::Reply, status: i32) {
    http::start(out,status); http::finish(out,http::NO_TYPE,"");
}

// `cookies.permanent[:last_room] = id` (remember_last_room_visited).
fn last_room_cookie(room: i64) -> u8[] {
    return str("last_room=",room,"; path=/; max-age=630720000; SameSite=Lax");
}

// Whether a form has any `name[...]` field: `params.require(name)` raises without one.
fn form_has_hash(body: const u8[:], name: const u8[:]) -> bool {
    let prefix = str(name,"[");
    for field in split(body,"&") {
        let eq = find(field,"="); let raw = if eq < 0 { field } else { field[..eq] };
        var key: u8[>..] = [];
        if http::decode(raw,key,true) && starts_with(key,prefix) { return true; }
    }
    return false;
}

// Every positive integer value of a repeated field such as `user_ids[]`, without duplicates.
fn form_ids(body: const u8[:], name: const u8[:]) -> i64[>..] {
    var ids: i64[>..] = [];
    for field in split(body,"&") {
        let eq = find(field,"="); if eq < 0 { continue; }
        var key: u8[>..] = []; var value: u8[>..] = [];
        if !http::decode(field[..eq],key,true) || key != name || !http::decode(field[eq+1..],value,true) { continue; }
        let id, valid = parse_int(trim(value)); if !valid || id <= 0 { continue; }
        var duplicate = false; for existing in ids { if existing == id { duplicate = true; } }
        if !duplicate && ids.len < 10000 { ids.push(id); }
    }
    return ids;
}

// An HTML page in the application layout, or turbo-rails' frame layout for a Turbo-Frame request.
fn respond_page(out: http::Reply, req: const http::Request&, ctx: ViewContext, status: i32 = 200) {
    var page: u8[>..] = [];
    let frame, framed = http::field_of(req,"Turbo-Frame");
    if framed {
        page.append("<html>\n  <head>\n    ");
        page.append(ctx.page_head);
        page.append("\n  </head>\n  <body>\n    ");
        page.append(ctx.page_content);
        page.append("\n  </body>\n</html>\n");
    } else { render_page_html(page,ctx); }
    http::respond_compressed(out,req,status,"text/html; charset=utf-8",page);
}

// ActiveSupport's JSON string encoding, which also escapes <, >, & and the line separators.
fn rails_json_string(out: u8[>..]&, text: const u8[:]) {
    let hex = "0123456789abcdef";
    out.push('"');
    var i: i64 = 0;
    while i < text.len {
        let c = text[i];
        if c == '"' { out.append("\\\""); }
        else if c == '\\' { out.append("\\\\"); }
        else if c == '\n' { out.append("\\n"); }
        else if c == '\r' { out.append("\\r"); }
        else if c == '\t' { out.append("\\t"); }
        else if c == 8 { out.append("\\b"); }
        else if c == 12 { out.append("\\f"); }
        else if c < 32 || c == '<' || c == '>' || c == '&' { out.append("\\u00"); out.push(hex[c >> 4]); out.push(hex[c & 15]); }
        else if c == 0xE2 && i + 2 < text.len && text[i+1] == 0x80 && (text[i+2] == 0xA8 || text[i+2] == 0xA9) {
            out.append(if text[i+2] == 0xA8 { "\\u2028" } else { "\\u2029" }); i += 2;
        }
        else { out.push(c); }
        i++;
    }
    out.push('"');
}

// A stored timestamp as Rails renders a UTC time in JSON: 2026-01-02T03:04:05.678Z.
fn json_time(stored: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    if stored.len < 19 { out.append(stored); return out; }
    out.append(stored[..10]); out.push('T'); out.append(stored[11..19]); out.push('.');
    var digits: i64 = 0;
    if stored.len > 20 && stored[19] == '.' {
        for c in stored[20..] { if digits < 3 && c >= '0' && c <= '9' { out.push(c); digits++; } }
    }
    while digits < 3 { out.push('0'); digits++; }
    out.push('Z'); return out;
}

// `turbo_stream_action_tag`: one stream action, with a template when it carries markup.
fn turbo_stream(out: u8[>..]&, action: const u8[:], target: const u8[:], content: const u8[:] = "", maintain_scroll: bool = false) {
    out.append("<turbo-stream action=\""); out.append(action); out.append("\" target=\""); escape(out,target); out.push('"');
    if maintain_scroll { out.append(" maintain_scroll=\"true\""); }
    out.push('>');
    if action != "remove" { out.append("<template>"); out.append(content); out.append("</template>"); }
    out.append("</turbo-stream>");
}

// The message columns message_view reads.
let MESSAGE_VIEW_SQL = "SELECT m.id,m.client_message_id,u.name,idx.body,rt.body,m.creator_id,m.created_at,m.updated_at,m.room_id,r.name,r.type FROM messages m JOIN rooms r ON r.id=m.room_id LEFT JOIN users u ON u.id=m.creator_id LEFT JOIN message_search_index idx ON idx.rowid=m.id LEFT JOIN action_text_rich_texts rt ON rt.record_id=m.id AND rt.record_type='Message' AND rt.name='body' WHERE m.id=?";

// A message as messages/_message presents it, with its boosts.
fn load_message_view(db: sqlite::Db, id: i64, avatar_key: const u8[:], storage_key: const u8[:], bytes: u8[>..]&, boosts: BoostView[>..]&) -> MessageView, bool {
    var q = sqlite::Stmt {}; var message = MessageView { .. }; var found = false;
    let failed = sqlite::run() {
        q = sqlite::prepare(db,MESSAGE_VIEW_SQL); sqlite::bind_i64(q,1,id);
        if sqlite::step(q) { message = message_view(db,q,avatar_key,storage_key,bytes,boosts); found = true; }
    };
    sqlite::finalize(q); for e in failed { sqlite::fail(e.code,e.message); }
    return message, found;
}

// The room kind's param key, from its stored type.
fn room_param_key(kind: const u8[:]) -> const u8[:] {
    return if kind == "Rooms::Open" { "rooms_open" } else if kind == "Rooms::Closed" { "rooms_closed" } else { "rooms_direct" };
}

// `users/sidebars/rooms/_shared` for a room, as broadcasts render it (never unread).
fn shared_room_html(id: i64, name: const u8[:], kind: const u8[:]) -> u8[>..] {
    var room = RoomView { .. }; room.id = id; room.name = name; room.display_name = name;
    room.param_key = room_param_key(kind); room.kind = room.param_key;
    room.classes = "align-center gap room btn txt-nowrap";
    var out: u8[>..] = []; let ctx = ViewContext { .. }; render_shared_room_html(out,ctx,room); return out;
}

// Runs a write transaction under the process's writer lock, the way existing writes do.
fn write_transaction<F>(db: sqlite::Db) -> sqlite::Error[] {
    campfire_writer_enter();
    let failed = sqlite::run() {
        sqlite::exec(db,"BEGIN IMMEDIATE");
        F();
        sqlite::exec(db,"COMMIT");
    };
    let cleanup = sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db,"ROLLBACK"); } };
    if failed.len == 0 { checkpoint_after_write(db); }
    campfire_writer_leave();
    return failed;
}
