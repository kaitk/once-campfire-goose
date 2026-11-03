namespace campfire;
import std;
import http;
import json;
import sqlite;
import database;
import html;
import messages;
import sessions;
import signed_id;
import cable;
import browser_routes;
import route_support;
import admin_routes;
import webhooks;
import view_types;
import view_data;
import view_helpers;
import views_generated;

fn involvement_known(value: const u8[:]) -> bool {
    return value == "invisible" || value == "nothing" || value == "mentions" || value == "everything";
}

// Rooms::InvolvementsHelper: the involvement the bell switches to next.
fn next_involvement(direct: bool, current: const u8[:]) -> const u8[:] {
    if direct { return if current == "everything" { "nothing" } else { "everything" }; }
    return if current == "mentions" { "everything" } else if current == "everything" { "nothing" } else if current == "nothing" { "invisible" } else { "mentions" };
}

fn involvement_label(value: const u8[:]) -> const u8[:] {
    return if value == "everything" { "Notifying about all messages" } else if value == "nothing" { "Notifications are off" }
        else if value == "invisible" { "Notifications are off and room invisible in sidebar" } else { "Notifying about @ mentions" };
}

// rooms/involvements/show: the bell's frame with `button_to_change_involvement`.
fn involvement_frame(out: u8[>..]&, room: i64, kind: const u8[:], involvement: const u8[:]) {
    let key = room_param_key(kind); let label = str("involvement_label_",key,"_",room);
    format(out,"<turbo-frame data-controller=\"turbo-frame\" data-action=\"notifications:ready@window-&gt;turbo-frame#load\" data-turbo-frame-url-param=\"/rooms/",room,"/involvement\" id=\"involvement_",key,"_",room,"\">\n  ");
    format(out,"<form class=\"button_to\" method=\"post\" action=\"/rooms/",room,"/involvement?involvement=",next_involvement(kind == "Rooms::Direct",involvement),"\"><input type=\"hidden\" name=\"_method\" value=\"put\" />");
    out.append("<button role=\"checkbox\" aria-checked=\"true\" aria-labelledby=\""); out.append(label); out.append("\" tabindex=\"0\" class=\"btn "); escape(out,involvement);
    out.append("\" type=\"submit\">"); out.append(image_html(str("notification-bell-",involvement,".svg"),[html_attr("aria-hidden","true"),html_attr("size",20)]));
    out.append("<span class=\"for-screen-reader\" id=\""); out.append(label); out.append("\">"); out.append(involvement_label(involvement)); out.append("</span></button></form>\n</turbo-frame>");
}

// `link_back_to(destination)`
fn link_back_to(out: u8[>..]&, destination: const u8[:]) {
    out.append("<a class=\"btn\" href=\""); escape(out,destination); out.append("\">");
    out.append(image_html("arrow-left.svg",[html_attr("aria-hidden","true"),html_attr("size",20)]));
    out.append("<span class=\"for-screen-reader\">Go Back</span></a>");
}

// `last_room_visited`: the room in the last_room cookie when the user is still in it, else their first room.
fn last_room_visited(db, user: i64, req: const http::Request&) -> i64 {
    let cookie, has_cookie = http::cookie_of(req,"last_room"); let id, valid = parse_int(cookie);
    return sql_number(db,"SELECT r.id FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? ORDER BY (r.id=?) DESC,r.created_at,r.id LIMIT 1",
        [sql_text(user),sql_text(if has_cookie && valid { id } else { 0 })]);
}

// `ensure_permission_to_create_rooms`
fn may_create_rooms(db, user: i64) -> bool {
    if sql_number(db,"SELECT role FROM users WHERE id=?",[sql_text(user)]) == 1 { return true; }
    let settings = sql_value(db,"SELECT settings FROM accounts LIMIT 1",[]);
    var nodes: json::Node[>..] = []; var strings: u8[>..] = []; let root, error = json::parse(settings,nodes,strings);
    let restricted, valid = json::as_bool(json::member(root,"restrict_room_creation_to_administrators"));
    return !(valid && restricted);
}

// `User.active.ordered`, as views of them.
fn active_users(db: sqlite::Db, key: const u8[:], bytes: u8[>..]&) -> UserView[>..] {
    var users: UserView[>..] = []; var q = sqlite::Stmt {};
    let failed = sqlite::run() {
        q = sqlite::prepare(db,"SELECT id,name,bio,updated_at,role FROM users WHERE status=0 ORDER BY LOWER(name),id");
        while sqlite::step(q) { users.push(user_view(q,0,key,bytes)); }
    };
    sqlite::finalize(q); for e in failed { sqlite::fail(e.code,e.message); } return users;
}

fn ascii_lower(text: const u8[:]) -> u8[>..] {
    var out: u8[>..] = []; for c in text { out.push(if c >= 'A' && c <= 'Z' { c + 32 } else { c }); } return out;
}

// rooms/closeds/_user
fn closed_room_user(out: u8[>..]&, user: const UserView&, administer: bool, creating: bool, current: i64, selected: bool) {
    out.append("<li class=\"flex align-center gap margin-none\" data-value=\""); escape(out,ascii_lower(user.name)); out.append("\">\n  <figure class=\"avatar flex-item-no-shrink\" style=\"--avatar-size: 4ch;\">\n    <a title=\"");
    escape(out,user.title); out.append("\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\""); escape(out,user.path); out.append("\"><img aria-hidden=\"true\" loading=\"lazy\" src=\"");
    escape(out,user.avatar_url); out.append("\" width=\"48\" height=\"48\" /></a>\n  </figure>\n\n  <div class=\"min-width\">\n    <div class=\"overflow-ellipsis fill-shade\"><strong>");
    escape(out,user.name); out.append("</strong></div>\n  </div>\n\n  <hr class=\"separator\" aria-hidden=\"true\">");
    if administer {
        if user.id == current && creating {
            format(out,"\n      <input type=\"hidden\" name=\"user_ids[]\" value=\"",user.id,"\" />\n      <img class=\"colorize--black flex-item-no-shrink\" aria-hidden=\"true\" src=\"");
            escape(out,asset_path("check.svg")); out.append("\" width=\"20\" height=\"20\" />");
        } else {
            format(out,"\n      <label class=\"switch flex-item-no-shrink\">\n        <input type=\"checkbox\" name=\"user_ids[]\" value=\"",user.id,"\" class=\"switch__input\"");
            if selected { out.append(" checked=\"checked\""); }
            out.append(" />\n        <span class=\"switch__btn round\"></span>\n        <span class=\"for-screen-reader\">Give "); escape(out,user.name); out.append(" access to this room</span>\n      </label>");
        }
    }
    out.append("\n</li>");
}

// `user_filter_search_tag`
fn user_filter_search_html(out: u8[>..]&) {
    out.append("\n    <input type=\"search\" id=\"search\" autocorrect=\"off\" autocomplete=\"off\" data-1p-ignore=\"true\" class=\"input input--transparent full-width\" placeholder=\"Filter…\" data-action=\"input-&gt;filter#filter\" />");
}

// rooms/opens/_user
fn open_room_user(out: u8[>..]&, user: const UserView&, administer: bool) {
    out.append("<li class=\"flex align-center gap margin-none\" data-value=\""); escape(out,ascii_lower(user.name)); out.append("\">\n  <figure class=\"avatar flex-item-no-shrink\" style=\"--avatar-size: 4ch;\">\n    <a title=\"");
    escape(out,user.title); out.append("\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\""); escape(out,user.path); out.append("\"><img aria-hidden=\"true\" loading=\"lazy\" src=\"");
    escape(out,user.avatar_url); out.append("\" width=\"48\" height=\"48\" /></a>\n  </figure>\n\n  <div class=\"min-width\">\n    <div class=\"overflow-ellipsis fill-shade\"><strong>");
    escape(out,user.name); out.append("</strong></div>\n  </div>\n\n  <hr class=\"separator\" aria-hidden=\"true\">");
    if administer {
        out.append("\n    <img class=\"colorize--black flex-item-no-shrink\" aria-hidden=\"true\" src=\""); escape(out,asset_path("check.svg")); out.append("\" width=\"20\" height=\"20\" />");
    }
    out.append("\n</li>\n");
}

// rooms/{closeds,opens}/{new,edit} in rooms/layouts/_{new,edit}: the room's name, who has access, the switch
// between Everyone and a closed room's members and, for its administrators, the delete button.
fn room_form(db, ctx: ViewContext&, bytes: u8[>..]&, req: const http::Request&, user: i64, room: i64, name: const u8[:], has_name: bool,
             administer: bool, avatar_key: const u8[:], open: bool) -> u8[>..] {
    let creating = room == 0;
    let kind = if open { "opens" } else { "closeds" }; let other = if open { "closeds" } else { "opens" };
    var nav: u8[>..] = []; nav.append("\n  <div class=\"flex-item-justify-start\">\n    ");
    let last = last_room_visited(db,user,req); let back: u8[>..] = if last > 0 { str("/rooms/",last) } else { str("/") }; link_back_to(nav,back); nav.append("\n  </div>");
    ctx.page_nav = view_keep(bytes,nav);
    var selected_ids: i64[>..] = [];
    if !creating && !open { for row in sql_rows(db,"SELECT user_id FROM memberships WHERE room_id=?",[sql_text(room)]) { let id, valid = parse_int(cell(row,0)); selected_ids.push(id); } }
    var selected: UserView[>..] = []; var unselected: UserView[>..] = [];
    for person in active_users(db,avatar_key,bytes) {
        var member = false; for id in selected_ids { if id == person.id { member = true; } }
        if member { selected.push(person); } else { unselected.push(person); }
    }
    var out: u8[>..] = [];
    if creating { format(out,"\n<section class=\"panel txt-align-center\" style=\"view-transition-name: new-room\">\n  <form action=\"/rooms/",kind,"\" accept-charset=\"UTF-8\" method=\"post\">"); }
    else { format(out,"\n<section class=\"panel txt-align-center\" style=\"view-transition-name: edit-room-",room,"\">\n  <form action=\"/rooms/",kind,"/",room,"\" accept-charset=\"UTF-8\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\" />"); }
    out.append("\n  <div class=\"flex align-center gap\">");
    if administer {
        out.append("\n      "); out.append(translation_button_html(ctx,"room_name"));
        out.append("\n\n      <label class=\"flex-item-grow txt-large\">\n        <input name=\"room[name]\" id=\"room_name\" class=\"input full-width\" required=\"required\" autofocus=\"autofocus\" placeholder=\"Name the room\" data-turbo-permanent=\"true\" data-action=\"keydown.enter-&gt;form#submit:prevent\" type=\"text\"");
        if has_name { out.append(" value=\""); escape(out,name); out.push('"'); }
        out.append(" />\n        <span class=\"for-screen-reader\">Name this room</span>\n      </label>");
    } else {
        out.append("\n      <h1 class=\"flex-item-grow txt-x-large\">\n        "); escape(out,name); out.append("\n      </h1>");
    }
    out.append("\n  </div>\n\n  <hr class=\"margin-block borderless\">\n\n  <section class=\"room-access margin-block pad-inline fill-shade border-radius\">\n    <menu class=\"flex flex-column gap margin-none pad overflow-y constrain-height\" data-controller=\"filter\" data-filter-active-class=\"filter--active\" data-filter-selected-class=\"selected\">");
    if administer || open {
        out.append("\n      <li class=\"flex align-center gap margin-none\">\n        <figure class=\"avatar flex-item-no-shrink\" style=\"--avatar-border-radius: 0; --avatar-size: 4ch;\">\n          <img aria-hidden=\"true\" class=\"colorize--black\" style=\"background-color: transparent\" src=\"");
        escape(out,asset_path("everyone.svg"));
        out.append("\" />\n          <span class=\"for-screen-reader\">Everyone</span>\n        </figure>\n\n        <div class=\"min-width\">\n          <div class=\"overflow-ellipsis fill-shade\"><strong>Everyone</strong></div>\n        </div>\n\n        <hr class=\"separator\" aria-hidden=\"true\">");
        if administer {
            out.append("\n\n        <a class=\"btn--faux flex-inline\" tabindex=\"-1\" data-turbo-action=\"replace\" href=\"");
            if creating { format(out,"/rooms/",other,"/new"); } else { format(out,"/rooms/",other,"/",room,"/edit"); }
            out.append("\">\n          <label for=\"room_type\" class=\"switch\">\n            <input type=\"checkbox\" id=\"room_type\" class=\"switch__input\"");
            if open { out.append(" checked=\"checked\""); }
            out.append(">\n            <span class=\"switch__btn round\"></span>\n            <span class=\"for-screen-reader\">");
            out.append(if open { "Give only some access to this room" } else { "Give everyone access to this room" });
            out.append("</span>\n          </label>\n</a>");
        }
        out.append("\n      </li>\n\n      <hr class=\"separator full-width\" style=\"--border-style: solid\">");
    }
    if selected.len + unselected.len > 20 { user_filter_search_html(out); }
    out.append("\n\n    <div data-filter-target=\"list\" contents>");
    if open {
        for person in unselected { out.append("\n      "); open_room_user(out,person,administer); }
    } else {
        for person in selected { out.append("\n      "); closed_room_user(out,person,administer,creating,user,true); }
        if selected.len > 0 && unselected.len > 0 { out.append("\n        <hr class=\"separator full-width\" style=\"--border-style: solid\">"); }
        for person in unselected { out.append("\n      "); closed_room_user(out,person,administer,creating,user,false); }
    }
    out.append("\n    </div>\n</menu>\n  </section>");
    if administer {
        out.append("\n  <button name=\"button\" type=\"submit\" class=\"btn btn--reversed txt-large center\"><img aria-hidden=\"true\" src=\"");
        escape(out,asset_path("check.svg")); out.append("\" width=\"20\" height=\"20\" /><span class=\"for-screen-reader\">Save</span></button>");
    }
    out.append("\n</form>\n</section>");
    if !creating && administer {
        // `button_to_delete_room`
        format(out,"\n  <section class=\"panel txt-align-center\">\n    <form class=\"button_to\" method=\"post\" action=\"",request_base(req),"/rooms/",room,"\"><input type=\"hidden\" name=\"_method\" value=\"delete\" /><button class=\"btn btn--negative max-width\" aria-label=\"Delete ");
        escape(out,name); out.append("\" data-turbo-confirm=\"Are you sure you want to delete this room and all messages in it? This can’t be undone.\" type=\"submit\">");
        out.append(image_html("trash.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); out.append("<span class=\"overflow-ellipsis\">"); escape(out,name); out.append("</span></button></form>\n  </section>");
    }
    return out;
}

// users/show
fn user_page(db, ctx: ViewContext&, bytes: u8[>..]&, req: const http::Request&, viewer: i64, id: i64, avatar_key: const u8[:]) -> u8[>..], bool {
    let rows = sql_rows(db,"SELECT name,COALESCE(email_address,''),COALESCE(bio,''),status,role FROM users WHERE id=?",[sql_text(id)]);
    if rows.len == 0 { return [], false; }
    let name = rows_col(rows,0,0); let email = rows_col(rows,0,1); let bio = rows_col(rows,0,2);
    let status, status_ok = parse_int(rows_col(rows,0,3)); let role, role_ok = parse_int(rows_col(rows,0,4));
    let person = load_user(db,id,avatar_key,bytes);
    let administer = ctx.user.administrator; let me = viewer == id;
    ctx.title = view_keep(bytes,name);
    var nav: u8[>..] = []; nav.append("  <div class=\"flex-item-justify-start\">\n    ");
    // `link_back`: the referrer, unless it is this page.
    let referer, has_referer = http::field_of(req,"Referer");
    let back: u8[>..] = if has_referer && referer.len > 0 && referer != str(request_base(req),req.target) { str(referer) } else { str("/") };
    link_back_to(nav,back);
    nav.append("\n  </div>\n\n  <div class=\"flex align-center gap flex-item-justify-end\">\n");
    if me {
        nav.append("      <a class=\"btn\" href=\"/users/me/profile\">\n        "); nav.append(image_html("pencil.svg",[html_attr("aria-hidden","true")]));
        nav.append("\n        <span class=\"for-screen-reader\">Edit my profile</span>\n</a>");
    }
    nav.append("  </div>\n");
    ctx.page_nav = view_keep(bytes,nav);
    var out: u8[>..] = [];
    out.append("<section class=\"panel txt-align-center\">\n  <div class=\"flex flex-column gap "); if status == 2 { out.append("banned"); }
    out.append("\">\n    <div class=\"avatar txt-xx-large center\" style=\"background: white\">\n      <img alt=\"Profile avatar\" class=\"avatar\" src=\""); escape(out,person.avatar_url); out.append("\" />\n    </div>\n\n");
    if role == 2 {
        out.append("      <div class=\"pad-double--inline push--inline push--block-start\">\n");
        if status == 0 {
            out.append("          "); out.append(block_button_to(direct_user_url(id),[html_attr("class","btn btn--primary full-width txt--large")],image_html("messages.svg",[]))); out.push('\n');
        } else { out.append("          <div>"); escape(out,name); out.append(" is no longer on this account</div>\n"); }
        out.append("      </div>\n");
    } else if status != 1 {
        out.append("        <div class=\"flex flex-column gap\" style=\"--row-gap: calc(var(--block-space) / 3)\">\n          <h1 class=\"txt-x-large txt-tight-lines margin-none\">"); escape(out,name); out.append("</h1>\n");
        if administer { out.append("            <div><a href=\"mailto:"); escape(out,email); out.append("\">"); escape(out,email); out.append("</a></div>\n"); }
        out.append("          <div>"); escape(out,bio); out.append("</div>\n        </div>\n\n");
        if status == 0 {
            var ping: u8[>..] = []; ping.append("\n              "); ping.append(image_html("messages.svg",[html_attr("aria-hidden","true"),html_attr("aria-label",str("Ping ",name))])); ping.push('\n');
            out.append("          <div class=\"pad-inline-double margin-inline margin-block-start\">\n            ");
            out.append(block_button_to(direct_user_url(id),[html_attr("class","btn btn--reversed full-width txt-large")],ping)); out.append("          </div>\n\n");
            if administer {
                // users/profiles/_transfer, with this server's own session transfer links.
                let expiry = sql_value(db,"SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now','+4 hours')",[]);
                let url = str(request_base(req),"/session/transfers/",sign_id(id,"campfire/session_transfer",avatar_key,expiry));
                out.append("            <hr class=\"margin-block-start borderless\">\n\n            \n<fieldset>\n  <legend class=\"gap\">\n");
                out.append("    "); out.append(image_html("laptop.svg",[html_attr("aria-hidden","true"),html_attr("class","colorize--black"),html_attr("size",36)]));
                out.append("\n    "); out.append(image_html("transfer.svg",[html_attr("aria-hidden","true"),html_attr("class","colorize--black"),html_attr("size",36)]));
                out.append("\n    "); out.append(image_html("mobile-phone.svg",[html_attr("aria-hidden","true"),html_attr("class","colorize--black"),html_attr("size",36)])); out.push('\n');
                out.append("  </legend>\n\n\n  <div class=\"flex flex-column gap\">\n");
                if me { out.append("      <label for=\"session_transfer_url\" class=\"for-screen-reader\">Use this link to login automatically on another device</label>\n"); }
                else {
                    out.append("      <div class=\"flex align-center gap justify-center\">\n        "); out.append(image_html("crown.svg",[html_attr("aria-hidden","true"),html_attr("class","flex-item-no-shrink colorize--black"),html_attr("size",16)]));
                    out.append("\n        <label for=\"session_transfer_url\">Share to get them back into their account</label>\n      </div>\n");
                }
                out.append("\n    <input type=\"text\" class=\"input\" value=\""); escape(out,url); out.append("\" id=\"session_transfer_url\" readonly>\n\n    <div class=\"flex align-center center gap\">\n      <a class=\"btn\" href=\"");
                escape(out,str(url,"/qr")); out.append("\">\n        <span class=\"for-screen-reader\">Show auto-login QR code</span>\n        ");
                out.append(image_html("qr-code.svg",[html_attr("aria-hidden","true"),html_attr("class","colorize--black"),html_attr("size",20)])); out.append("\n</a>\n      ");
                var copy_body: u8[>..] = []; copy_body.append("\n        <span class=\"for-screen-reader\">Copy auto-login link</span>\n        ");
                copy_body.append(image_html("copy-paste.svg",[html_attr("aria-hidden","true"),html_attr("class","flex-item-no-shrink colorize--black"),html_attr("size",20)])); copy_body.push('\n');
                out.append(block_button_to_copy_to_clipboard(url,copy_body)); out.append("\n      ");
                var share_body: u8[>..] = []; share_body.append("\n        <span class=\"for-screen-reader\">Share auto-login link</span>\n        ");
                share_body.append(image_html("share.svg",[html_attr("aria-hidden","true"),html_attr("class","flex-item-no-shrink colorize--black"),html_attr("size",20)])); share_body.push('\n');
                out.append(block_web_share_session_button(url,"Your sign-in link","This is your own private sign-in URL, DO NOT SHARE IT. Use it to sign-in on another device or if you get locked out.",share_body));
                out.append("    </div>\n  </div>\n</fieldset>\n\n");
            }
        }
        if administer && !me {
            // users/_ban_button
            out.append("\n          <div class=\"margin-block-start\">\n              ");
            var ban: u8[>..] = []; ban.append("\n    ");
            if status == 0 {
                ban.append(image_html("cancel.svg",[html_attr("aria-hidden","true"),html_attr("aria-label",str("Ban ",name))])); ban.append("\n    <span>Ban "); escape(ban,name); ban.append("</span>\n");
                out.append(block_button_to(str("/users/",id,"/ban"),[html_attr("class","btn full-width"),html_attr("data-turbo-confirm","Are you sure you want to ban this user? This will log them out, delete their messages, and block their IP addresses.")],ban));
            } else {
                ban.append(image_html("cancel.svg",[html_attr("aria-hidden","true"),html_attr("aria-label",str("Remove Ban ",name))])); ban.append("\n    <span>Remove ban</span>\n");
                var form: u8[>..] = []; form.append(block_button_to(str("/users/",id,"/ban"),[html_attr("class","btn btn--negative full-width"),html_attr("data-turbo-confirm","Are you sure you want to remove the ban on this user?")],ban));
                let at = find(form,"><button"); out.append(form[..at+1]); out.append("<input type=\"hidden\" name=\"_method\" value=\"delete\" />"); out.append(form[at+1..]);
            }
            out.append("\n          </div>\n");
        }
    } else {
        out.append("        <div>\n          <h1 class=\"txt-x-large margin-none\">"); escape(out,name); out.append("</h1>\n          <div>"); escape(out,name); out.append(" is no longer on this account</div>\n        </div>\n");
    }
    out.append("  </div>\n</section>\n");
    return out, true;
}

// Deletes a room with its memberships, messages and their boosts, rich texts, search entries and
// attachments (RoomsController#destroy, which Room::DestroyJob completes in Rails). Each message's
// attachment and rich-text embeds are purged as `dependent: :destroy` purges them; the blobs' keys
// go to `keys`, for their files to be deleted after the transaction commits.
fn delete_room(db, room: i64, keys: u8[][>..]&) {
    let filter = "SELECT id FROM messages WHERE room_id=?";
    sql_rows(db,"DELETE FROM memberships WHERE room_id=?",[sql_text(room)]);
    purge_attachments(db,str("(record_type='Message' AND name='attachment' AND record_id IN (",filter,")) OR (record_type='ActionText::RichText' AND record_id IN (SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id IN (",filter,")))"),[sql_text(room),sql_text(room)],keys);
    sql_rows(db,str("DELETE FROM boosts WHERE message_id IN (",filter,")"),[sql_text(room)]);
    sql_rows(db,str("DELETE FROM message_search_index WHERE rowid IN (",filter,")"),[sql_text(room)]);
    sql_rows(db,str("DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id IN (",filter,")"),[sql_text(room)]);
    sql_rows(db,"DELETE FROM messages WHERE room_id=?",[sql_text(room)]);
    sql_rows(db,"DELETE FROM rooms WHERE id=?",[sql_text(room)]);
}

// Room-scoped and user pages: involvement, settings, destroy, Rooms::ClosedsController, users#show and
// searches#clear. Returns false, after a few comparisons, for every other path.
fn room_page_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], avatar_key: const u8[:], storage_key: const u8[:],
                   stream_key: const u8[:], vapid: const u8[:], storage: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    var room: i64 = 0; var action: u8[>..] = [];
    if starts_with(path,"/rooms/") {
        let rest = path[7..];
        if starts_with(rest,"closeds") { return closed_route(db,user,req,body,avatar_key,storage_key,stream_key,vapid,out); }
        let slash = find(rest,"/"); let tail = if slash < 0 { "" } else { rest[slash..] };
        if tail != "" && tail != "/involvement" && tail != "/settings" { return false; }
        if tail == "" && req.method != "DELETE" && req.method != "POST" { return false; }
        let id, valid = parse_int(if slash < 0 { rest } else { rest[..slash] });
        if !valid || id <= 0 { return false; }
        room = id; action = str(tail);
    } else if path == "/searches/clear" {
        action = str("clear");
    } else if starts_with(path,"/users/") {
        let id, valid = parse_int(path[7..]);
        if !valid || id <= 0 { return false; }
        room = id; action = str("user");
    } else { return false; }
    let method = effective_method(req,body);
    let reading = method == "GET" || method == "HEAD";
    if action == "" && method != "DELETE" { return false; }
    if action == "/settings" {
        // Rails routes rooms/settings#show, but has no Rooms::SettingsController: both reference ports answer 500.
        if !reading { http::respond(out,404,"text/plain","Not found"); }
        else { http::respond(out,500,"text/plain","uninitialized constant Rooms::SettingsController"); }
        return true;
    }
    let routed = if action == "/involvement" { reading || method == "PUT" || method == "PATCH" }
        else if action == "clear" { method == "DELETE" } else if action == "user" { reading } else { true };
    if !routed { http::respond(out,404,"text/plain","Not found"); return true; }
    if !reading && !same_origin(req) { http::respond(out,422,"text/plain","Invalid origin"); return true; }

    if action == "user" {
        var bytes: u8[>..] = []; var content: u8[>..] = []; var found = false; var ctx = ViewContext { .. };
        let failed = sqlite::run() {
            ctx = load_view_context(db,user,avatar_key,stream_key,vapid,req,bytes,storage_key);
            let page, exists = user_page(db,ctx,bytes,req,user,room,avatar_key); content = copy(page); found = exists;
        };
        if failed.len > 0 { http::respond(out,500,"text/plain","Database error"); }
        else if !found { http::respond(out,404,"text/plain","Not found"); }
        else { ctx.page_content = content; respond_page(out,req,ctx); }
        return true;
    }
    if action == "clear" {
        // searches#clear (set_messages first: nothing to check without a query).
        let failed = write_transaction(db) { sql_rows(db,"DELETE FROM searches WHERE user_id=?",[sql_text(user)]); };
        if failed.len > 0 { http::respond(out,500,"text/plain","Database error"); } else { redirect_to_path(out,req,"/searches"); }
        return true;
    }
    if action == "/involvement" {
        if reading {
            var status: i32 = 404; var content: u8[>..] = []; var bytes: u8[>..] = []; var ctx = ViewContext { .. };
            let failed = sqlite::run() {
                let rows = sql_rows(db,"SELECT r.type,COALESCE(m.involvement,'') FROM memberships m JOIN rooms r ON r.id=m.room_id WHERE m.room_id=? AND m.user_id=?",[sql_text(room),sql_text(user)]);
                for row in rows {
                    ctx = load_view_context(db,user,avatar_key,stream_key,vapid,req,bytes,storage_key);
                    let kind = str(cell(row,0)); let stored = cell(row,1); let current: u8[>..] = if involvement_known(stored) { str(stored) } else { str("mentions") };
                    involvement_frame(content,room,kind,current); status = 200;
                }
            };
            if failed.len > 0 { http::respond(out,500,"text/plain","Database error"); }
            else if status != 200 { http::respond(out,404,"text/plain","Not found"); }
            else { ctx.page_content = content; respond_page(out,req,ctx); }
            return true;
        }
        // update: params[:involvement] from the query or the form.
        var value: u8[>..] = [];
        let raw, in_query = http::query_of(req.target,"involvement");
        if in_query { http::decode(raw,value,true); } else { http::form_value(body,"involvement",value); }
        // A value outside the enum raises ArgumentError in Rails (a 500); this answers 422 and changes nothing.
        if !involvement_known(value) { http::respond(out,422,"text/plain","Invalid involvement"); return true; }
        var status: i32 = 404; var previous: u8[>..] = []; var kind: u8[>..] = []; var name: u8[>..] = [];
        var now: u8[>..] = []; campfire_sql_now(now);
        let failed = write_transaction(db) {
            let rows = sql_rows(db,"SELECT COALESCE(m.involvement,''),r.type,COALESCE(r.name,'') FROM memberships m JOIN rooms r ON r.id=m.room_id WHERE m.room_id=? AND m.user_id=?",[sql_text(room),sql_text(user)]);
            for row in rows {
                previous = str(cell(row,0)); kind = str(cell(row,1)); name = str(cell(row,2));
                sql_rows(db,"UPDATE memberships SET involvement=?,updated_at=? WHERE room_id=? AND user_id=?",[sql_text(value),sql_text(now),sql_text(room),sql_text(user)]);
                status = 302;
            }
        };
        if failed.len > 0 { http::respond(out,500,"text/plain","Database error"); return true; }
        if status != 302 { http::respond(out,404,"text/plain","Not found"); return true; }
        // broadcast_visibility_changes, to the user's own rooms stream.
        var stream: u8[>..] = [];
        if kind != "Rooms::Direct" {
            if value == "invisible" { turbo_stream(stream,"remove",str("list_",room_param_key(kind),"_",room)); }
            else if previous == "invisible" { turbo_stream(stream,"prepend","shared_rooms",shared_room_html(room,name,kind)); }
        }
        redirect_to_path(out,req,str("/rooms/",room,"/involvement"));
        if stream.len > 0 { publish(-user,http::later(out,60000),stream); }
        return true;
    }
    // RoomsController#destroy: members only; administrators and the room's creator may delete it. Rails'
    // Room::DestroyJob resets the former members' connections after the sidebar removal; here the room and its
    // messages go at once and nothing can publish to its id again, so their connections stay and get the removal.
    var status: i32 = 0; var kind: u8[>..] = []; var keys: u8[][>..] = [];
    let failed = write_transaction(db) {
        let rows = sql_rows(db,"SELECT r.type,r.creator_id FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=?",[sql_text(room),sql_text(user)]);
        if rows.len == 0 { status = 302; }
        else if rows_col(rows,0,1) != str(user) && sql_number(db,"SELECT role FROM users WHERE id=?",[sql_text(user)]) != 1 { status = 403; }
        else { kind = rows_col(rows,0,0); delete_room(db,room,keys); status = 200; }
    };
    if failed.len > 0 { http::respond(out,500,"text/plain","Database error"); return true; }
    if status == 403 { respond_empty(out,403); return true; }
    // A room the user can't reach sends them back to the root, as `set_room` does.
    redirect_to_path(out,req,"/");
    if status == 200 {
        delete_blob_files(storage,keys);
        var stream: u8[>..] = []; turbo_stream(stream,"remove",str("list_",room_param_key(kind),"_",room));
        publish(0,http::later(out,60000),stream);
    }
    return true;
}

// Rooms::ClosedsController: new, create, show, edit and update.
fn closed_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], avatar_key: const u8[:], storage_key: const u8[:],
                stream_key: const u8[:], vapid: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    let method = effective_method(req,body);
    let reading = method == "GET" || method == "HEAD";
    var room: i64 = 0; var edit = false; var fresh = false;
    if path == "/rooms/closeds/new" { fresh = true; }
    else if starts_with(path,"/rooms/closeds/") {
        let rest = path[15..]; let slash = find(rest,"/");
        let id, valid = parse_int(if slash < 0 { rest } else { rest[..slash] });
        if !valid || id <= 0 || slash >= 0 && rest[slash..] != "/edit" { return false; }
        room = id; edit = slash >= 0;
    } else if path != "/rooms/closeds" { return false; }
    // The collection's other methods are rooms_route's (rooms#show and #destroy with the id "closeds").
    let routed = if fresh || edit { reading } else if room > 0 { reading || method == "PATCH" || method == "PUT" || method == "DELETE" } else { method == "POST" };
    if !routed { http::respond(out,404,"text/plain","Not found"); return true; }
    if !reading && !same_origin(req) { http::respond(out,422,"text/plain","Invalid origin"); return true; }
    // RoomsController#destroy, whose set_room and ensure_can_administer the subclass's own before_actions
    // replaced with ones that skip it: Rails raises on the missing room.
    if room > 0 && !edit && method == "DELETE" { http::respond(out,500,"text/plain","undefined method 'destroy' for nil"); return true; }

    if reading {
        var status: i32 = 200; var bytes: u8[>..] = []; var content: u8[>..] = []; var ctx = ViewContext { .. };
        let failed = sqlite::run() {
            if fresh {
                if !may_create_rooms(db,user) { status = 403; }
                else {
                    ctx = load_view_context(db,user,avatar_key,stream_key,vapid,req,bytes,storage_key); ctx.title = "New chat room";
                    content = room_form(db,ctx,bytes,req,user,0,"New room",true,true,avatar_key,false);
                }
            } else {
                // set_room: the user's rooms other than directs, else back to the root.
                let rows = sql_rows(db,"SELECT r.name IS NOT NULL,COALESCE(r.name,''),r.creator_id FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=? AND r.type<>'Rooms::Direct'",[sql_text(room),sql_text(user)]);
                if rows.len == 0 { status = 302; }
                else if !edit { status = 301; }
                else {
                    ctx = load_view_context(db,user,avatar_key,stream_key,vapid,req,bytes,storage_key);
                    ctx.title = view_keep(bytes,str("Edit settings for ",rows_col(rows,0,1)));
                    let administer = ctx.user.administrator || rows_col(rows,0,2) == str(user);
                    content = room_form(db,ctx,bytes,req,user,room,rows_col(rows,0,1),rows_col(rows,0,0) == "1",administer,avatar_key,false);
                }
            }
        };
        if failed.len > 0 { for e in failed { write_stderr(str("closed room page failed: ",e.message,"\n")); } http::respond(out,500,"text/plain","Database error"); }
        else if status == 403 { respond_empty(out,403); }
        else if status == 302 { redirect_to_path(out,req,"/"); }
        // show: remember_last_room_visited, then redirect to the room.
        else if status == 301 {
            http::start(out,302); http::field(out,"Location",str(request_base(req),"/rooms/",room)); http::field(out,"Set-Cookie",last_room_cookie(room));
            http::finish(out,http::TEXT,"Redirecting");
        }
        else { ctx.page_content = content; respond_page(out,req,ctx); }
        return true;
    }
    // create and update: params.require(:room).permit(:name), and the grantees' ids.
    let has_room = form_has_prefix(body,"room[");
    var name: u8[>..] = []; let has_name = http::form_value(body,"room[name]",name);
    let grantees = form_ids(body,"user_ids[]");
    var status: i32 = 0; var members: i64[>..] = [];
    var now: u8[>..] = []; campfire_sql_now(now);
    // Grants for the cable workers' unread notices; each revoked member's connections reset, as
    // Membership's after_destroy_commit does.
    var changes: i64[>..] = [];
    let failed = write_access_transaction(db,changes) {
        if room == 0 {
            if !may_create_rooms(db,user) { status = 403; }
            else if !has_room { status = 400; }
            else {
                // Rooms::Closed.create_for(room_params, users: grantees)
                if has_name { sql_rows(db,"INSERT INTO rooms(name,type,creator_id,created_at,updated_at) VALUES(?,'Rooms::Closed',?,?,?)",[sql_text(name),sql_text(user),sql_text(now),sql_text(now)]); }
                else { sql_rows(db,"INSERT INTO rooms(type,creator_id,created_at,updated_at) VALUES('Rooms::Closed',?,?,?)",[sql_text(user),sql_text(now),sql_text(now)]); }
                room = sqlite::last_insert_rowid(db);
                for id in grantees {
                    sql_rows(db,"INSERT OR IGNORE INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT ?,id,'mentions',?,? FROM users WHERE id=?",[sql_text(room),sql_text(now),sql_text(now),sql_text(id)]);
                    changes.push(ACCESS_GRANT); changes.push(id); changes.push(room);
                }
                status = 201;
            }
        } else {
            let rows = sql_rows(db,"SELECT r.creator_id FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=? AND r.type<>'Rooms::Direct'",[sql_text(room),sql_text(user)]);
            if rows.len == 0 { status = 302; }
            else if rows_col(rows,0,0) != str(user) && sql_number(db,"SELECT role FROM users WHERE id=?",[sql_text(user)]) != 1 { status = 403; }
            else if !has_room { status = 400; }
            else {
                // force_room_type and `update!(room_params)`, then `memberships.revise(granted:, revoked:)`.
                if has_name { sql_rows(db,"UPDATE rooms SET name=?,type='Rooms::Closed',updated_at=? WHERE id=?",[sql_text(name),sql_text(now),sql_text(room)]); }
                else { sql_rows(db,"UPDATE rooms SET type='Rooms::Closed',updated_at=? WHERE id=?",[sql_text(now),sql_text(room)]); }
                for id in grantees {
                    sql_rows(db,"INSERT OR IGNORE INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT ?,id,'mentions',?,? FROM users WHERE id=?",[sql_text(room),sql_text(now),sql_text(now),sql_text(id)]);
                    changes.push(ACCESS_GRANT); changes.push(id); changes.push(room);
                }
                var keep: u8[>..] = []; keep.append("0"); for id in grantees { format(keep,",",id); }
                for row in sql_rows(db,str("SELECT user_id FROM memberships WHERE room_id=? AND user_id NOT IN (",keep,")"),[sql_text(room)]) {
                    let member, valid = parse_int(cell(row,0)); if valid { changes.push(ACCESS_RESET); changes.push(member); changes.push(0); }
                }
                sql_rows(db,str("DELETE FROM memberships WHERE room_id=? AND user_id NOT IN (",keep,")"),[sql_text(room)]);
                status = 200;
            }
        }
        if status == 200 || status == 201 { name = (sql_value(db,"SELECT COALESCE(name,'') FROM rooms WHERE id=?",[sql_text(room)])); }
    };
    if failed.len > 0 { for e in failed { write_stderr(str("closed room write failed: ",e.message,"\n")); } http::respond(out,500,"text/plain","Database error"); return true; }
    if status == 403 || status == 400 { respond_empty(out,status); return true; }
    if status == 302 { redirect_to_path(out,req,"/"); return true; }
    redirect_to_path(out,req,str("/rooms/",room));
    // broadcast_create_room / broadcast_update_room: the shared-room partial to each member's own rooms stream.
    var stream: u8[>..] = [];
    if status == 201 { turbo_stream(stream,"prepend","shared_rooms",shared_room_html(room,name,"Rooms::Closed")); }
    else { turbo_stream(stream,"replace",str("list_rooms_closed_",room),shared_room_html(room,name,"Rooms::Closed")); }
    publish(CABLE_MEMBERS - room,http::later(out,60000),stream);
    return true;
}
