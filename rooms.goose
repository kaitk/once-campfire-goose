namespace campfire;
import std;
import public_pages;
import http;
import json;
import sqlite;
import database;
import html;
import messages;
import sessions;
import signed_id;
import cable;
import storage;
import browser_routes;
import route_support;
import auth_routes;
import admin_routes;
import room_pages;
import view_types;
import view_data;
import view_helpers;
import views_generated;

let ROOMS_OPEN: i32 = 1;
let ROOMS_DIRECT: i32 = 2;
let ROOMS_INDEX: i32 = 0;
let ROOMS_NEW: i32 = 1;
let ROOMS_MEMBER: i32 = 2;
let ROOMS_EDIT: i32 = 3;

// Rooms::OpensController, Rooms::DirectsController, the rooms#index and #show routes that `resources :rooms`
// gives the namespaces' collection paths, and Autocompletable::UsersController. False for any other path.
fn rooms_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], avatar_key: const u8[:], sgid_key: const u8[:],
               storage_key: const u8[:], stream_key: const u8[:], vapid: const u8[:], storage: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    if path == "/autocompletable/users" || path == "/autocompletable/users.json" {
        autocomplete_users(db,user,req,path == "/autocompletable/users.json",avatar_key,sgid_key,out); return true;
    }
    let method = effective_method(req,body);
    let reading = method == "GET" || method == "HEAD";
    if path == "/rooms" {
        // RoomsController#index; `resources :rooms` has no create.
        if !reading { public_exception(out,req,404); return true; }
        var last: i64 = 0;
        let failed = sqlite::run() { last = sql_number(db,"SELECT m.room_id FROM memberships m JOIN rooms r ON r.id=m.room_id WHERE m.user_id=? ORDER BY r.id DESC LIMIT 1",[sql_text(user)]); };
        if failed.len > 0 || last == 0 { public_exception(out,req,500); }
        else { redirect_to_path(out,req,str("/rooms/",last)); }
        return true;
    }
    if starts_with(path,"/rooms/") && path.len > 7 {
        // `resources :rooms` answers the namespaces' collection paths but a POST: rooms#show and #destroy with
        // the id "opens", which set_room can't find, and no rooms#update. The same for a room's own path.
        let rest = path[7..];
        let collection = rest == "opens" || rest == "closeds" || rest == "directs";
        let id, numeric = parse_int(rest);
        if collection && method != "POST" || numeric && (method == "PATCH" || method == "PUT" || method == "POST") {
            if method == "PATCH" || method == "PUT" || method == "POST" { public_exception(out,req,404); }
            else if !reading && !same_origin(req) { public_exception(out,req,422); }
            else { redirect_room_not_found(out,req); }
            return true;
        }
    }
    var kind: i32 = 0; var prefix: i64 = 0;
    if starts_with(path,"/rooms/opens") { kind = ROOMS_OPEN; prefix = 12; }
    else if starts_with(path,"/rooms/directs") { kind = ROOMS_DIRECT; prefix = 14; }
    else { return false; }
    let rest = path[prefix..];
    var action: i32 = ROOMS_INDEX; var room: i64 = 0;
    if rest == "/new" { action = ROOMS_NEW; }
    else if rest.len > 0 {
        if rest[0] != '/' { return false; }
        let tail = rest[1..]; let slash = find(tail,"/");
        let id, valid = parse_int(if slash < 0 { tail } else { tail[..slash] });
        if !valid || id <= 0 || slash >= 0 && tail[slash..] != "/edit" { return false; }
        room = id; action = if slash >= 0 { ROOMS_EDIT } else { ROOMS_MEMBER };
    }
    // The routes `resources` draws; anything else is Rails' routing 404.
    let routed = if action == ROOMS_INDEX { method == "POST" } else if action == ROOMS_NEW || action == ROOMS_EDIT { reading }
        else { reading || method == "PATCH" || method == "PUT" || method == "DELETE" };
    if !routed { public_exception(out,req,404); return true; }
    if !reading && !same_origin(req) { public_exception(out,req,422); return true; }
    if kind == ROOMS_OPEN { open_route(db,user,req,body,method,action,room,avatar_key,storage_key,stream_key,vapid,out); }
    else { direct_route(db,user,req,body,method,action,room,avatar_key,storage_key,stream_key,vapid,storage,out); }
    return true;
}

// `set_room` in Rooms::OpensController and Rooms::ClosedsController: the user's rooms other than directs. Answers
// whether its name is set, the name, and whether the user may administer it.
fn shared_room_of(db, user: i64, room: i64) -> bool, bool, u8[], bool, u8[] {
    let rows = sql_rows(db,"SELECT r.name IS NOT NULL,COALESCE(r.name,''),r.creator_id,r.type FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=? AND r.type<>'Rooms::Direct'",[sql_text(room),sql_text(user)]);
    if rows.len == 0 { return false, false, [], false, []; }
    let administer = rows_col(rows,0,2) == str(user) || sql_number(db,"SELECT role FROM users WHERE id=?",[sql_text(user)]) == 1;
    return true, rows_col(rows,0,0) == "1", rows_col(rows,0,1), administer, rows_col(rows,0,3);
}

// Rooms::OpensController
fn open_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], method: const u8[:], action: i32, room: i64,
              avatar_key: const u8[:], storage_key: const u8[:], stream_key: const u8[:], vapid: const u8[:], out: http::Reply) {
    let reading = method == "GET" || method == "HEAD";
    if action == ROOMS_MEMBER && method == "DELETE" {
        // RoomsController#destroy, whose set_room and ensure_can_administer the subclass's own before_actions
        // replaced with ones that skip it: Rails raises on the missing room.
        public_exception(out,req,500); return;
    }
    if reading {
        var status: i32 = 200; var bytes: u8[>..] = []; var content: u8[>..] = []; var ctx = ViewContext { .. };
        let failed = sqlite::run() {
            if action == ROOMS_NEW {
                if !may_create_rooms(db,user) { status = 403; }
                else {
                    ctx = load_view_context(db,user,avatar_key,stream_key,vapid,req,bytes,storage_key); ctx.title = "New chat room";
                    content = room_form(db,ctx,bytes,req,user,0,"New room",true,true,avatar_key,true);
                }
            } else {
                let found, has_name, name, administer, kind = shared_room_of(db,user,room);
                if !found { status = 302; }
                else if action == ROOMS_MEMBER { status = 301; }
                else {
                    // force_room_type: a closed room's page as the open room it would become.
                    ctx = load_view_context(db,user,avatar_key,stream_key,vapid,req,bytes,storage_key);
                    ctx.title = view_keep(bytes,str("Edit settings for ",name));
                    content = room_form(db,ctx,bytes,req,user,room,name,has_name,administer,avatar_key,true);
                }
            }
        };
        if failed.len > 0 { for e in failed { write_stderr(str("open room page failed: ",e.message,"\n")); } public_exception(out,req,500); }
        else if status == 403 { respond_head(out,req,403); }
        // set_room: "Room not found or inaccessible".
        else if status == 302 { redirect_room_not_found(out,req); }
        // show: remember_last_room_visited, then redirect to the room.
        else if status == 301 {
            http::start(out,302); http::field(out,"Location",str(request_base(req),"/rooms/",room)); http::field(out,"Set-Cookie",last_room_cookie(room));
            http::finish(out,http::TEXT,"Redirecting");
        }
        else { ctx.page_content = content; respond_page(out,req,ctx); }
        return;
    }
    // create and update: params.require(:room).permit(:name).
    let has_room = form_has_prefix(body,"room[");
    var name: u8[>..] = []; let has_name = http::form_value(body,"room[name]",name);
    var status: i32 = 0; var id = room;
    var now: u8[>..] = []; campfire_sql_now(now);
    var changes: i64[>..] = [];
    let failed = write_access_transaction(db,changes) {
        if action == ROOMS_INDEX {
            if !may_create_rooms(db,user) { status = 403; }
            else if !has_room { status = 400; }
            else {
                // Rooms::Open.create_for(room_params, users: Current.user), then grant_access_to_all_users.
                if has_name { sql_rows(db,"INSERT INTO rooms(name,type,creator_id,created_at,updated_at) VALUES(?,'Rooms::Open',?,?,?)",[sql_text(name),sql_text(user),sql_text(now),sql_text(now)]); }
                else { sql_rows(db,"INSERT INTO rooms(type,creator_id,created_at,updated_at) VALUES('Rooms::Open',?,?,?)",[sql_text(user),sql_text(now),sql_text(now)]); }
                id = sqlite::last_insert_rowid(db);
                sql_rows(db,"INSERT OR IGNORE INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,'mentions',?,?)",[sql_text(id),sql_text(user),sql_text(now),sql_text(now)]);
                sql_rows(db,"INSERT OR IGNORE INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT ?,id,'mentions',?,? FROM users WHERE status=0 ORDER BY id",[sql_text(id),sql_text(now),sql_text(now)]);
                changes.push(ACCESS_GRANT); changes.push(0); changes.push(id);
                status = 201;
            }
        } else {
            let found, named, stored, administer, kind = shared_room_of(db,user,room);
            if !found { status = 302; }
            else if !administer { status = 403; }
            else if !has_room { status = 400; }
            else {
                // force_room_type and `update!(room_params)`: only a change saves, and touches the room.
                let renamed = has_name && (!named || stored != name);
                if renamed || kind != "Rooms::Open" {
                    if has_name { sql_rows(db,"UPDATE rooms SET name=?,type='Rooms::Open',updated_at=? WHERE id=?",[sql_text(name),sql_text(now),sql_text(room)]); }
                    else { sql_rows(db,"UPDATE rooms SET type='Rooms::Open',updated_at=? WHERE id=?",[sql_text(now),sql_text(room)]); }
                }
                // Rooms::Open#grant_access_to_all_users, once the type changed.
                if kind != "Rooms::Open" {
                    sql_rows(db,"INSERT OR IGNORE INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT ?,id,'mentions',?,? FROM users WHERE status=0 ORDER BY id",[sql_text(room),sql_text(now),sql_text(now)]);
                    changes.push(ACCESS_GRANT); changes.push(0); changes.push(room);
                }
                status = 200;
            }
        }
        if status == 200 || status == 201 { name = sql_value(db,"SELECT COALESCE(name,'') FROM rooms WHERE id=?",[sql_text(id)]); }
    };
    if failed.len > 0 { for e in failed { write_stderr(str("open room write failed: ",e.message,"\n")); } public_exception(out,req,500); return; }
    if status == 403 { respond_head(out,req,403); return; }
    if status == 400 { public_exception(out,req,400); return; }
    if status == 302 { redirect_room_not_found(out,req); return; }
    redirect_to_path(out,req,str("/rooms/",id));
    // broadcast_create_room / broadcast_update_room, to every user's rooms stream.
    var stream: u8[>..] = [];
    if status == 201 { turbo_stream(stream,"prepend","shared_rooms",shared_room_html(id,name,"Rooms::Open")); }
    else { turbo_stream(stream,"replace",str("list_rooms_open_",id),shared_room_html(id,name,"Rooms::Open")); }
    publish(0,http::later(out,60000),stream);
}

// The users of a direct room as `users/sidebars/rooms/_direct` and directs/edit list them: room.users without
// `except` (0 for none), in the order the database gives them.
fn direct_members(db, room: i64, except: i64, avatar_key: const u8[:], bytes: u8[>..]&) -> UserView[>..] {
    var q = sqlite::Stmt {}; var people: UserView[>..] = [];
    let failed = sqlite::run() {
        q = sqlite::prepare(db,"SELECT u.id,u.name,u.bio,u.updated_at,u.role FROM users u JOIN memberships m ON m.user_id=u.id WHERE m.room_id=? AND u.id<>?");
        sqlite::bind_i64(q,1,room); sqlite::bind_i64(q,2,except);
        while sqlite::step(q) { people.push(user_view(q,0,avatar_key,bytes)); }
    };
    sqlite::finalize(q); for e in failed { sqlite::fail(e.code,e.message); }
    return people;
}

// `users/sidebars/rooms/_direct` for one membership, as the sidebar renders it.
fn direct_room_entry(db, room: i64, member: i64, avatar_key: const u8[:]) -> u8[>..] {
    var bytes: u8[>..] = [];
    let rows = sql_rows(db,"SELECT r.updated_at,m.unread_at IS NOT NULL FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=?",[sql_text(room),sql_text(member)]);
    var people = direct_members(db,room,member,avatar_key,bytes);
    if people.len == 0 { people.push(load_user(db,member,avatar_key,bytes)); }
    var initials: u8[>..] = [];
    for i in people.len {
        if i > 0 { initials.append(if people.len == 2 { "+" } else if i == people.len-1 { ", and " } else { ", " }); }
        var words = 0; for word in split(people[i].name," ") { if word.len > 0 && words < 3 { initials.append(capitalized(word[..1])); words += 1; } }
    }
    var view = DirectView { .. }; view.room_id = room;
    view.updated_at_epoch = view_keep(bytes,str(campfire_epoch_ms(rows_col(rows,0,0))));
    view.classes = if rows_col(rows,0,1) == "1" { "direct unread" } else { "direct" };
    view.initials = view_keep(bytes,initials); view.members = people;
    var out: u8[>..] = []; let ctx = ViewContext { .. }; render_direct_room_html(out,ctx,view); return out;
}

// `link_back_to_last_room_visited` in the page's nav.
fn back_to_last_room_nav(db, ctx: ViewContext&, bytes: u8[>..]&, req: const http::Request&, user: i64) {
    var nav: u8[>..] = []; nav.append("\n  <div class=\"flex-item-justify-start\">\n    ");
    let last = last_room_visited(db,user,req); let back: u8[>..] = if last > 0 { str("/rooms/",last) } else { str("/") }; link_back_to(nav,back); nav.append("\n  </div>");
    ctx.page_nav = view_keep(bytes,nav);
}

// rooms/directs/new, with users/autocompletables/_template.
fn new_direct_html(out: u8[>..]&) {
    out.append("<turbo-frame id=\"direct_rooms_control\" target=\"_top\">\n  <div class=\"directs directs--new flex flex-column gap\">\n    <form class=\"flex gap flex-item-grow\" data-controller=\"form\" data-action=\"keydown.esc-&gt;form#cancel\" action=\"/rooms/directs\" accept-charset=\"UTF-8\" method=\"post\">\n");
    out.append("      <a class=\"btn flex-item-no-shrink\" data-turbo-frame=\"user_sidebar\" data-form-target=\"cancel\" href=\"/users/me/sidebar\">\n        ");
    out.append(image_html("arrow-left.svg",[html_attr("aria-hidden","true")])); out.append("\n        <span class=\"for-screen-reader\">Cancel changes</span>\n</a>\n");
    out.append("      <section class=\"autocomplete__container unpad input input--actor\">\n        <div class=\"autocomplete__input input flex flex-wrap position-relative flex-item-grow\"\n            data-controller=\"autocomplete\" data-autocomplete-url-value=\"/autocompletable/users\">\n");
    out.append("          <select name=\"user_ids[]\" data-autocomplete-target=\"select\" data-template-id=\"autocompletable-user\" multiple=\"true\" hidden required></select>\n\n");
    out.append("          <template id=\"autocompletable-user\">\n  <div class=\"autocomplete__pill max-width\" data-value=\"\" tabindex=\"0\">\n    <img class=\"avatar flex-item-no-shrink\" data-content=\"avatar\" src=\"\" />\n");
    out.append("    <span class=\"autocomplete-field__selected-value-text overflow-ellipsis flex-item-grow\" data-content=\"label\"></span>\n\n");
    out.append("    <button type=\"button\" data-action=\"autocomplete#remove:prevent\" data-value=\"\" tabindex=\"-1\" class=\"btn btn--plain txt-small translucent flex-item-no-shrink\">\n      ");
    out.append(image_html("remove-circle.svg",[html_attr("aria-hidden","true"),html_attr("class","colorize--black")]));
    out.append("\n      <span class=\"for-screen-reader\">Remove <span data-content=\"screenReaderLabel\"></span></span>\n    </button>\n  </div>\n</template>\n\n\n");
    out.append("          <input autocomplete=\"off\" autocorrect=\"off\" data-1p-ignore=\"true\" class=\"autocomplete__input input flex flex-wrap position-relative\" data-autocomplete-target=\"input\" data-action=\"input-&gt;autocomplete#search keydown-&gt;autocomplete#didPressKey\" type=\"text\" name=\"rooms_direct[user_ids_input]\" id=\"rooms_direct_user_ids_input\" />\n        </div>\n      </section>\n\n");
    out.append("      <button name=\"button\" type=\"submit\" class=\"btn btn--reversed flex-item-no-shrink\">\n        "); out.append(image_html("check.svg",[html_attr("aria-hidden","true")]));
    out.append("\n        <span class=\"for-screen-reader\">Start Ping</span>\n</button></form>\n    <span class=\"txt-small translucent pad-inline-half center\">Type names to ping someone…</span>\n  </div>\n</turbo-frame>\n");
}

// Rooms::DirectsController
fn direct_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], method: const u8[:], action: i32, room: i64,
                avatar_key: const u8[:], storage_key: const u8[:], stream_key: const u8[:], vapid: const u8[:], storage: const u8[:], out: http::Reply) {
    let reading = method == "GET" || method == "HEAD";
    if action == ROOMS_MEMBER && reading {
        // RoomsController#show, without the set_room the subclass limited to edit and destroy: Rails raises.
        public_exception(out,req,500); return;
    }
    if action == ROOMS_MEMBER && method != "DELETE" { public_exception(out,req,404); return; }
    if reading {
        var status: i32 = 200; var bytes: u8[>..] = []; var content: u8[>..] = []; var ctx = ViewContext { .. };
        let failed = sqlite::run() {
            ctx = load_view_context(db,user,avatar_key,stream_key,vapid,req,bytes,storage_key);
            if action == ROOMS_NEW { new_direct_html(content); }
            else if sql_number(db,"SELECT count(*) FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=? AND r.type='Rooms::Direct'",[sql_text(room),sql_text(user)]) == 0 { status = 302; }
            else {
                // rooms/directs/edit
                let others = direct_room_name(db,room,user);
                let shown: u8[>..] = if others.len > 0 { str(others) } else { str(ctx.user.name) };
                ctx.title = view_keep(bytes,str("Edit settings for ",shown));
                back_to_last_room_nav(db,ctx,bytes,req,user);
                var people = direct_members(db,room,user,avatar_key,bytes);
                if people.len == 0 { people = direct_members(db,room,0,avatar_key,bytes); }
                content.append("\n<div class=\"panel txt-align-center\">\n  <section class=\"directs--edit margin-block-end\">");
                for person in people {
                    content.append("\n      <div class=\"member flex flex-column gap fill-shade pad border-radius\">\n        <figure class=\"avatar center\" style=\"--avatar-border-radius: 10ch; --avatar-size: 10ch;\" >\n          <a title=\"");
                    escape(content,person.title); content.append("\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\""); escape(content,person.path);
                    content.append("\"><img aria-hidden=\"true\" loading=\"lazy\" src=\""); escape(content,person.avatar_url); content.append("\" width=\"48\" height=\"48\" /></a>\n        </figure>\n\n        <strong>");
                    escape(content,person.name); content.append("</strong>\n      </div>");
                }
                format(content,"\n  </section>\n\n  <form class=\"button_to\" method=\"post\" action=\"",request_base(req),"/rooms/directs/",room,"\"><input type=\"hidden\" name=\"_method\" value=\"delete\" /><button class=\"btn btn--negative center\" aria-label=\"Delete Ping\" data-turbo-confirm=\"Are you sure you want to delete this ping and all messages in it? This can’t be undone.\" type=\"submit\">\n    ");
                content.append(image_html("trash.svg",[html_attr("aria-hidden","true")])); content.append("\n    Ping\n</button></form></div>\n");
            }
        };
        if failed.len > 0 { for e in failed { write_stderr(str("direct room page failed: ",e.message,"\n")); } public_exception(out,req,500); }
        else if status == 302 { redirect_room_not_found(out,req); }
        else { ctx.page_content = content; respond_page(out,req,ctx); }
        return;
    }
    if method == "DELETE" {
        // RoomsController#destroy: set_room among the user's direct rooms; every member may delete it.
        var found = false; var keys: u8[][>..] = [];
        let failed = write_transaction(db) {
            if sql_number(db,"SELECT count(*) FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=? AND r.type='Rooms::Direct'",[sql_text(room),sql_text(user)]) > 0 {
                delete_room(db,room,keys); found = true;
            }
        };
        if failed.len > 0 { public_exception(out,req,500); return; }
        if found { redirect_to_path(out,req,"/"); } else { redirect_room_not_found(out,req); }
        if found {
            delete_blob_files(storage,keys);
            var stream: u8[>..] = []; turbo_stream(stream,"remove",str("list_rooms_direct_",room));
            publish(0,http::later(out,60000),stream);
        }
        return;
    }
    // create: Rooms::Direct.find_or_create_for(User.where(id: user_ids + [Current.user.id])). The ids come from
    // the form, or from the query as `rooms_directs_path(user_ids: [id])` puts them there.
    var ids = form_ids(body,"user_ids[]");
    if ids.len == 0 { let start = find(req.target,"?"); if start >= 0 { ids = form_ids(req.target[start+1..],"user_ids[]"); } }
    ids.push(user);
    var list: u8[>..] = []; for id, i in ids { if i > 0 { list.push(','); } format(list,id); }
    var now: u8[>..] = []; campfire_sql_now(now);
    var changes: i64[>..] = []; var direct: i64 = 0; var members: i64[>..] = []; var entries: u8[>..] = []; var ends: i64[>..] = [];
    let failed = write_access_transaction(db,changes) {
        var users: i64[>..] = [];
        for row in sql_rows(db,str("SELECT id FROM users WHERE id IN (",list,") ORDER BY id"),[]) { let id, valid = parse_int(cell(row,0)); users.push(id); }
        var chosen: u8[>..] = []; for id, i in users { if i > 0 { chosen.push(','); } format(chosen,id); }
        direct = sql_number(db,str("SELECT r.id FROM rooms r WHERE r.type='Rooms::Direct' AND (SELECT count(*) FROM memberships m WHERE m.room_id=r.id)=",users.len,
            " AND (SELECT count(*) FROM memberships m WHERE m.room_id=r.id AND m.user_id IN (",chosen,"))=",users.len," ORDER BY r.id LIMIT 1"),[]);
        if direct == 0 {
            sql_rows(db,"INSERT INTO rooms(type,creator_id,created_at,updated_at) VALUES('Rooms::Direct',?,?,?)",[sql_text(user),sql_text(now),sql_text(now)]);
            direct = sqlite::last_insert_rowid(db);
            for id in users {
                sql_rows(db,"INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,'everything',?,?)",[sql_text(direct),sql_text(id),sql_text(now),sql_text(now)]);
                changes.push(ACCESS_GRANT); changes.push(id); changes.push(direct);
            }
        }
        // broadcast_create_room: each membership's sidebar entry, rendered for its user.
        for row in sql_rows(db,"SELECT user_id FROM memberships WHERE room_id=? ORDER BY id",[sql_text(direct)]) {
            let member, valid = parse_int(cell(row,0)); members.push(member);
            entries.append(direct_room_entry(db,direct,member,avatar_key)); ends.push(entries.len);
        }
    };
    if failed.len > 0 { for e in failed { write_stderr(str("direct room write failed: ",e.message,"\n")); } public_exception(out,req,500); return; }
    redirect_to_path(out,req,str("/rooms/",direct));
    // One publication to each member's own rooms stream. The request's permit covers the last, whose
    // acknowledgement the response waits for; the others take a permit each if one is free.
    for member, i in members {
        var stream: u8[>..] = []; turbo_stream(stream,"prepend","direct_rooms",entries[if i == 0 { 0 } else { ends[i-1] }..ends[i]]);
        if i == members.len - 1 { publish(-member,http::later(out,60000),stream); }
        else {
            let permit, acquired = qpoll<CablePermit>();
            if acquired { publish(-member,http::MailAddress { .. },stream); }
            else { write_stderr(str("Ping ",direct,": no publication permit for member ",member,"'s sidebar\n")); }
        }
    }
}

// One `key=value` of a URL's query, percent-encoded as Addressable encodes it.
fn link_param(out: u8[>..]&, first: bool&, key: const u8[:], value: const u8[:]) {
    out.push(if first { '?' } else { '&' }); first = false;
    let hex = "0123456789ABCDEF";
    out.append(key); out.push('=');
    for c in value {
        if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '.' || c == '_' || c == '~' { out.push(c); }
        else { out.push('%'); out.push(hex[c >> 4]); out.push(hex[c & 15]); }
    }
}

// Rails' negotiation between respond_to's html and json for this request: an explicit format, then the
// Accept header's first known type (html for none or */*); 406 for none it knows.
fn autocomplete_format(req: const http::Request&, json_extension: bool) -> i32 {
    if json_extension { return 2; }
    let accept, has_accept = http::field_of(req,"Accept");
    if !has_accept || accept.len == 0 { return 1; }
    // A browser's Accept, with */* among other types, is ignored for html.
    for item in split(accept,",") {
        let semicolon = find(item,";"); let kind = html_lower(trim(if semicolon < 0 { item } else { item[..semicolon] }));
        if kind == "*/*" && accept != "*/*" && find(accept,",") >= 0 { return 1; }
    }
    for item in split(accept,",") {
        let semicolon = find(item,";"); let kind = html_lower(trim(if semicolon < 0 { item } else { item[..semicolon] }));
        if kind == "text/html" || kind == "application/xhtml+xml" || kind == "*/*" || kind == "text/*" { return 1; }
        if kind == "application/json" || kind == "text/x-json" || kind == "application/jsonrequest" { return 2; }
    }
    return 0;
}

// Autocompletable::UsersController#index: the active users, of the room when room_id is given, whose names
// contain `filter` or else `query`, 20 to a page, as <lexxy-prompt-item> elements or as JSON.
fn autocomplete_users(db: sqlite::Db, user: i64, req: const http::Request&, json_extension: bool, avatar_key: const u8[:], sgid_key: const u8[:], out: http::Reply) {
    if req.method != "GET" && req.method != "HEAD" { public_exception(out,req,404); return; }
    var room_id: u8[>..] = []; var filter: u8[>..] = []; var query: u8[>..] = []; var page_text: u8[>..] = [];
    let raw_room, has_room = http::query_of(req.target,"room_id"); if has_room { http::decode(raw_room,room_id,true); }
    let raw_filter, has_filter = http::query_of(req.target,"filter"); if has_filter { http::decode(raw_filter,filter,true); }
    let raw_query, has_query = http::query_of(req.target,"query"); if has_query { http::decode(raw_query,query,true); }
    let raw_page, has_page = http::query_of(req.target,"page"); if has_page { http::decode(raw_page,page_text,true); }
    // `.presence`: blank strings count as absent.
    let search: u8[>..] = if trim(filter).len > 0 { str(filter) } else if trim(query).len > 0 { str(query) } else { str("") };
    let scoped = trim(room_id).len > 0;
    // `param.to_i`, at least 1.
    var page_digits: u8[>..] = []; for c in trim(page_text) { if c < '0' || c > '9' || page_digits.len >= 9 { break; } page_digits.push(c); }
    let parsed_page, page_valid = parse_int(page_digits);
    let page: i64 = if page_valid && parsed_page > 0 { parsed_page } else { 1 };
    let wanted = autocomplete_format(req,json_extension);
    var status: i32 = 200; var content: u8[>..] = []; var total: i64 = 0;
    let failed = sqlite::run() {
        var room: i64 = 0;
        if scoped {
            // Current.user.rooms.find(params[:room_id]), as Active Record casts the id.
            var digits: u8[>..] = []; for c in trim(room_id) { if c < '0' || c > '9' { break; } digits.push(c); }
            let id, valid = parse_int(digits);
            room = if valid { sql_number(db,"SELECT room_id FROM memberships WHERE room_id=? AND user_id=?",[sql_text(id),sql_text(user)]) } else { 0 };
            if room == 0 { status = 404; }
        }
        if status == 200 && wanted == 0 { status = 406; }
        if status == 200 {
            let from = if scoped { "FROM users u JOIN memberships m ON m.user_id=u.id WHERE m.room_id=? AND u.status=0 AND u.name LIKE ?" } else { "FROM users u WHERE ?='0' AND u.status=0 AND u.name LIKE ?" };
            let pattern = str("%",search,"%");
            total = sql_number(db,str("SELECT count(*) ",from),[sql_text(room),copy(pattern)]);
            let rows = sql_rows(db,str("SELECT u.id ",from," ORDER BY LOWER(u.name),u.id LIMIT 20 OFFSET ?"),[sql_text(room),copy(pattern),sql_text((page-1)*20)]);
            var bytes: u8[>..] = []; var first = true;
            if wanted == 2 { content.push('['); }
            for row in rows {
                let id, valid = parse_int(cell(row,0)); let person = load_user(db,id,avatar_key,bytes); let sgid = attachable_sgid(id,sgid_key);
                if wanted == 2 {
                    // autocompletable/users/_user.json.jbuilder
                    var escaped_name: u8[>..] = []; escape(escaped_name,person.name);
                    if !first { content.push(','); } first = false;
                    content.append("{\"name\":"); json::format_string(content,escaped_name); format(content,",\"value\":",id,",\"avatar_url\":");
                    json::format_string(content,str(request_base(req),person.avatar_url)); content.append(",\"sgid\":"); json::format_string(content,sgid); content.push('}');
                } else {
                    // autocompletable/users/_prompt_item, with `avatar_tag` and users/_mention.
                    var avatar: u8[>..] = [];
                    avatar.append("<a title=\""); escape(avatar,person.title); avatar.append("\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\""); escape(avatar,person.path);
                    avatar.append("\"><img aria-hidden=\"true\" src=\""); escape(avatar,person.avatar_url); avatar.append("\" width=\"48\" height=\"48\" /></a>");
                    content.append("<lexxy-prompt-item search=\""); escape(content,person.name); content.append("\" sgid=\""); escape(content,sgid);
                    content.append("\">\n  <template type=\"menu\">\n    <span class=\"autocomplete__item flex align-center gap unpad\">\n      "); content.append(avatar);
                    content.append("\n      <span class=\"autocompletable__name\">"); escape(content,person.name); content.append("</span>\n    </span>\n  </template>\n  <template type=\"editor\">\n    <span class=\"mention\" sgid=\"");
                    escape(content,sgid); content.append("\">"); content.append(avatar); content.push(' '); escape(content,person.name); content.append("</span>\n\n  </template>\n</lexxy-prompt-item>\n");
                }
            }
            if wanted == 2 { content.push(']'); }
        }
    };
    if failed.len > 0 { for e in failed { write_stderr(str("autocomplete failed: ",e.message,"\n")); } public_exception(out,req,500); return; }
    if status != 200 { public_exception(out,req,status); return; }
    if wanted == 1 { http::respond(out,200,"text/html; charset=utf-8",content); return; }
    // GearedPagination's headers for a JSON page: the count, and the next page's URL unless this is the last.
    http::start(out,200); http::field(out,"Content-Type","application/json; charset=utf-8"); http::field(out,"X-Total-Count",str(total));
    // `page.last?` is the page count's page alone (at least one page): pages past it link onward too.
    let page_count = max((total + 19) / 20, 1);
    if page != page_count {
        var next: u8[>..] = []; next.append(request_base(req)); next.append(http::path_of(req.target));
        // Addressable's query_values: the keys sorted, each once with its last value, percent-encoded.
        let start = find(req.target,"?"); let fields = split(if start < 0 { "" } else { req.target[start+1..] },"&");
        var first_key = true; var previous: u8[>..] = []; var started = false;
        loop {
            var best: u8[>..] = str("page"); var found = !started || compare("page",previous) > 0;
            for field in fields {
                let eq = find(field,"="); var key: u8[>..] = [];
                if !http::decode(if eq < 0 { field } else { field[..eq] },key,true) || key.len == 0 { continue; }
                if started && compare(key,previous) <= 0 { continue; }
                if !found || compare(key,best) < 0 { best = copy(key); found = true; }
            }
            if !found { break; }
            var value: u8[>..] = if best == "page" { str(page+1) } else { str("") };
            if best != "page" {
                for field in fields {
                    let eq = find(field,"="); var key: u8[>..] = [];
                    if !http::decode(if eq < 0 { field } else { field[..eq] },key,true) || key != best { continue; }
                    value.clear(); if eq >= 0 { http::decode(field[eq+1..],value,true); }
                }
            }
            link_param(next,first_key,best,value);
            previous = copy(best); started = true;
        }
        http::field(out,"Link",str("<",next,">; rel=\"next\""));
    }
    http::finish(out,http::NO_TYPE,content);
}
