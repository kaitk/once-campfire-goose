namespace campfire;
import std;
import http;
import json;
import sqlite;
import setup;
import sessions;
import signed_id;
import database;
import messages;
import html;
import view_data;
import view_types;
import cable;
import view_helpers;

extern fn campfire_qr(text: const u8[:], pixels: u8[>..]&) -> i64;

fn form_input(out: u8[>..]&, name: const u8[:], label: const u8[:], value: const u8[:]) {
    out.append("<label>"); escape(out,label); out.append("<input class=\"input\" name=\""); escape(out,name);
    out.append("\" placeholder=\""); escape(out,label); out.append("\" value=\""); escape(out,value); out.append("\"></label>");
}
fn form_start(out: u8[>..]&, action: const u8[:]) {
    out.append("<form data-turbo=\"false\" method=\"post\" action=\""); escape(out,action); out.append("\">");
}
fn form_end(out: u8[>..]&, label: const u8[:] = "Save changes") {
    out.append("<button type=\"submit\">"); escape(out,label); out.append("</button></form>");
}
fn request_base(req: const http::Request&) -> u8[] {
    let host, exists = http::field_of(req,"Host"); return str("http://",host);
}

fn form_encode(out: u8[>..]&, text: const u8[:]) {
    let hex="0123456789ABCDEF";
    for c in text {
        if c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9' {out.push(c);}
        else {out.push('%');out.push(hex[c>>4]);out.push(hex[c&15]);}
    }
}

fn bot_message(db: sqlite::Db, writer: const WriterStatements&, req: const http::Request&, body: const u8[:], avatar_key: const u8[:], storage_key: const u8[:], out: http::Reply) -> bool {
    let path=http::path_of(req.target);
    if req.method!="POST" || !starts_with(path,"/rooms/") || !ends_with(path,"/messages") {return false;}
    let rest=path[7..path.len-9]; let slash=find(rest,"/"); if slash<0 {return false;}
    let room,valid=parse_int(rest[..slash]); let token=rest[slash+1..];
    if !valid || token.len!=64 {return false;}
    var status: i32=404; var html: u8[>..]=[]; var id: i64=0; var posted_ms: i64=0;
    let failed=sqlite::run() {
        let user=sql_number(db,"SELECT u.id FROM users u JOIN memberships m ON m.user_id=u.id WHERE u.bot_token=? AND u.role=2 AND u.status=0 AND m.room_id=?",[sql_text(token),sql_text(room)]);
        if user>0 && body.len>0 && body.len<=65536 {
            var adapted=copy(req); adapted.fields="Content-Type: application/x-www-form-urlencoded\r\n";
            let client=random_token(); var escaped: u8[>..]=[]; escape(escaped,body);
            var form: u8[>..]=[]; form.append("message%5Bbody%5D="); form_encode(form,escaped); form.append("&message%5Bclient_message_id%5D="); form_encode(form,client);
            var bytes: u8[>..]=[]; var ctx=ViewContext {storage_key:storage_key,..}; ctx.user=load_user(db,user,avatar_key,bytes);
            var now: u8[>..]=[]; campfire_sql_now(now);
            status=post_message(db,writer,adapted,form,user,room,now,avatar_key,ctx,bytes,0,html); posted_ms=campfire_epoch_ms(now);
            id=sql_number(db,"SELECT id FROM messages WHERE client_message_id=? AND creator_id=?",[sql_text(client),sql_text(user)]);
        }
    };
    if failed.len>0 {status=500;}
    if status==200 {
        http::start(out,201); http::field(out,"Location",str("/messages/",id)); http::finish(out,http::NO_TYPE,"");
        publish(room,http::later(out,60000),html,posted_ms);
    } else {http::respond(out,status,"text/plain","Unable to post bot message");}
    return true;
}

fn transfer_route(db: sqlite::Db, req: const http::Request&, signing_key: const u8[:], cookie_key: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    if !starts_with(path,"/session/transfers/") { return false; }
    let qr = ends_with(path,"/qr"); let token = path[19..if qr { path.len-3 } else { path.len }];
    var now: u8[>..] = []; campfire_now(now);
    let user = verify_id(token,"campfire/session_transfer",signing_key,now);
    var status: i32 = 404; var content: u8[>..] = []; var session: u8[>..] = []; var destination: u8[>..] = [];
    let failed = sqlite::run() {
        if user > 0 && sql_number(db,"SELECT count(*) FROM users WHERE id=? AND status=0 AND role<>2",[sql_text(user)]) == 1 {
            if req.method == "GET" && qr {
                let url = str(request_base(req),"/session/transfers/",token);
                var pixels: u8[>..] = []; let width = campfire_qr(url,pixels);
                if width > 0 {
                    format(content,"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"320\" height=\"320\" viewBox=\"0 0 ",width+8," ",width+8,"\"><rect width=\"100%\" height=\"100%\" fill=\"white\"/><g fill=\"black\">");
                    for y in width { for x in width { if (pixels[y*width+x] & 1) != 0 { format(content,"<rect x=\"",x+4,"\" y=\"",y+4,"\" width=\"1\" height=\"1\"/>"); } } }
                    content.append("</g></svg>"); status=200;
                } else { status=500; }
            } else if req.method == "GET" {
                content.append("<form method=\"post\" data-controller=\"auto-submit\" action=\""); escape(content,path); content.append("\"><button type=\"submit\">Sign in</button></form>"); status=200;
            } else if req.method == "POST" && same_origin(req) {
                session = str(random_token()); var stamp: u8[>..] = []; campfire_sql_now(stamp);
                sql_rows(db,"INSERT INTO sessions(user_id,token,created_at,updated_at,last_active_at) VALUES(?,?,?,?,?)",[sql_text(user),sql_text(session),sql_text(stamp),sql_text(stamp),sql_text(stamp)]);
                let room=sql_number(db,"SELECT room_id FROM memberships WHERE user_id=? ORDER BY room_id LIMIT 1",[sql_text(user)]); destination=str("/rooms/",room); status=303;
            }
        }
    };
    if failed.len > 0 { status=500; }
    if status==303 { session_created(out,session,cookie_key,destination); }
    else if qr { http::respond(out,status,"image/svg+xml",content); }
    else { http::respond(out,status,"text/html; charset=utf-8",simple_page("Sign in",content)); }
    return true;
}

fn browser_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], key: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    let profile = path=="/users/me/profile";
    let account = path=="/account" || path=="/account/edit";
    let styles = path=="/account/custom_styles" || path=="/account/custom_styles/edit";
    let bots = starts_with(path,"/account/bots");
    let open = starts_with(path,"/rooms/opens");
    let direct = path=="/rooms/directs/new" || path=="/rooms/directs";
    let autocomplete = path=="/autocompletable/users";
    if !profile && !account && !styles && !bots && !open && !direct && !autocomplete { return false; }
    let writing = req.method=="POST" || req.method=="PATCH";
    if writing && !same_origin(req) { http::respond(out,422,"text/plain","Invalid origin"); return true; }
    var status: i32=200; var content: u8[>..]=[]; var location: u8[>..]=[]; var broadcast: u8[>..]=[]; var json_response=false;
    // Memberships granted, as pairs of user (0 for every user) and room, for the cable workers' unread notices.
    var grants: i64[>..]=[];
    if writing { campfire_writer_enter(); }
    let failed=sqlite::run() {
        if writing { sqlite::exec(db,"BEGIN IMMEDIATE"); }
        let admin=sql_number(db,"SELECT role FROM users WHERE id=? AND status=0",[sql_text(user)])==1;
        var now: u8[>..]=[]; campfire_sql_now(now);
        if (styles || bots || writing && account) && !admin { status=403; }
        else if profile {
            if writing {
                var bio: u8[>..]=[]; var name: u8[>..]=[];
                if http::form_value(body,"user[bio]",bio) { sql_rows(db,"UPDATE users SET bio=?,updated_at=? WHERE id=?",[sql_text(bio),sql_text(now),sql_text(user)]); }
                if http::form_value(body,"user[name]",name) && name.len>0 { sql_rows(db,"UPDATE users SET name=?,updated_at=? WHERE id=?",[sql_text(name),sql_text(now),sql_text(user)]); }
                location=str(path);
            } else {
                form_start(content,path);
                form_input(content,"user[name]","Name",sql_value(db,"SELECT name FROM users WHERE id=?",[sql_text(user)]));
                form_input(content,"user[email_address]","Email",sql_value(db,"SELECT email_address FROM users WHERE id=?",[sql_text(user)]));
                content.append("<label>Bio<textarea name=\"user[bio]\">"); escape(content,sql_value(db,"SELECT bio FROM users WHERE id=?",[sql_text(user)])); content.append("</textarea></label>"); form_end(content);
                let expiry=sql_value(db,"SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now','+5 minutes')",[]);
                let url=str(request_base(req),"/session/transfers/",sign_id(user,"campfire/session_transfer",key,expiry));
                content.append("<input id=\"session_transfer_url\" readonly value=\""); escape(content,url); content.append("\"><a href=\""); escape(content,str(url,"/qr")); content.append("\">Show auto-login QR code</a>");
            }
        } else if account {
            if writing { var name: u8[>..]=[]; if http::form_value(body,"account[name]",name) && name.len>0 { sql_rows(db,"UPDATE accounts SET name=?,updated_at=?",[sql_text(name),sql_text(now)]); location=str("/account/edit"); } else { status=422; } }
            else {
                if admin { form_start(content,"/account"); form_input(content,"account[name]","Account name",sql_value(db,"SELECT name FROM accounts",[])); form_end(content); content.append("<a href=\"/account/bots\">Set up chat bots</a>"); }
                let invite=str(request_base(req),"/join/",sql_value(db,"SELECT join_code FROM accounts",[]));
                content.append("<input id=\"invite_url\" readonly value=\""); escape(content,invite); content.append("\">");
            }
        } else if styles {
            if writing { var css: u8[>..]=[]; http::form_value(body,"account[custom_styles]",css); sql_rows(db,"UPDATE accounts SET custom_styles=?,updated_at=?",[sql_text(css),sql_text(now)]); location=str("/account/custom_styles/edit"); }
            else { form_start(content,"/account/custom_styles"); content.append("<textarea name=\"account[custom_styles]\">"); escape(content,sql_value(db,"SELECT custom_styles FROM accounts",[])); content.append("</textarea>"); form_end(content); }
        } else if open {
            var id: i64=0;
            if starts_with(path,"/rooms/opens/") && path!="/rooms/opens/new" { let part=path[13..]; let slash=find(part,"/"); let n,ok=parse_int(if slash<0 { part } else { part[..slash] }); id=n; }
            if id>0 && !admin && sql_number(db,"SELECT count(*) FROM rooms WHERE id=? AND creator_id=?",[sql_text(id),sql_text(user)])==0 { status=403; }
            else if writing {
                var name: u8[>..]=[];
                if !http::form_value(body,"room[name]",name) || name.len==0 { status=422; }
                else {
                    let created=id==0;
                    if created {
                        sql_rows(db,"INSERT INTO rooms(name,type,creator_id,created_at,updated_at) VALUES(?,'Rooms::Open',?,?,?)",[sql_text(name),sql_text(user),sql_text(now),sql_text(now)]); id=sqlite::last_insert_rowid(db);
                        sql_rows(db,"INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT ?,id,'everything',?,? FROM users WHERE status=0",[sql_text(id),sql_text(now),sql_text(now)]);
                        grants.push(0); grants.push(id);
                    } else {
                        // A closed room opened again is every active user's (Rooms::Open#grant_access_to_all_users).
                        if sql_value(db,"SELECT type FROM rooms WHERE id=?",[sql_text(id)])=="Rooms::Closed" {
                            sql_rows(db,"UPDATE rooms SET type='Rooms::Open' WHERE id=?",[sql_text(id)]);
                            sql_rows(db,"INSERT OR IGNORE INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT ?,id,'mentions',?,? FROM users WHERE status=0",[sql_text(id),sql_text(now),sql_text(now)]);
                            grants.push(0); grants.push(id);
                        }
                        sql_rows(db,"UPDATE rooms SET name=?,updated_at=? WHERE id=?",[sql_text(name),sql_text(now),sql_text(id)]);
                    }
                    location=str("/rooms/",id);
                    let target: u8[>..]=if created { str("shared_rooms") } else { str("list_rooms_open_",id) };
                    format(broadcast,"<turbo-stream action=\"",if created { "prepend" } else { "replace" },"\" target=\"",target,"\"><template><a id=\"list_rooms_open_",id,"\" href=\"/rooms/",id,"\" data-turbo-frame=\"_top\" data-sorted-list-name=\""); escape(broadcast,name); broadcast.append("\"><span>"); escape(broadcast,name); broadcast.append("</span></a></template></turbo-stream>");
                }
            } else { let action: u8[>..]=if id==0 {str("/rooms/opens")} else {str("/rooms/opens/",id)}; let name: u8[]=if id==0 {[]} else {sql_value(db,"SELECT name FROM rooms WHERE id=?",[sql_text(id)])}; form_start(content,action); form_input(content,"room[name]","Name this room",name); form_end(content,"Save"); }
        } else if direct {
            if writing {
                var ids: i64[>..]=[]; ids.push(user);
                for field in split(body,"&") {
                    let eq=find(field,"="); if eq<0 { continue; }
                    var name: u8[>..]=[]; var value: u8[>..]=[];
                    if !http::decode(field[..eq],name,true) || name!="user_ids[]" || !http::decode(field[eq+1..],value,true) { continue; }
                    let id,valid=parse_int(value); if !valid || id<=0 { continue; }
                    var duplicate=false; for existing in ids { if existing==id {duplicate=true;} }
                    if !duplicate && ids.len<32 && sql_number(db,"SELECT count(*) FROM users WHERE id=? AND status=0 AND role<>2",[sql_text(id)])>0 {ids.push(id);}
                }
                if ids.len<2 {status=422;}
                else {
                    var list: u8[>..]=[]; for id,i in ids {if i>0 {list.push(',');} format(list,id);}
                    var room=sql_number(db,str("SELECT r.id FROM rooms r WHERE r.type='Rooms::Direct' AND (SELECT count(*) FROM memberships m WHERE m.room_id=r.id)=",ids.len," AND (SELECT count(*) FROM memberships m WHERE m.room_id=r.id AND m.user_id IN (",list,"))=",ids.len," LIMIT 1"),[]);
                    if room==0 {
                        sql_rows(db,"INSERT INTO rooms(type,creator_id,created_at,updated_at) VALUES('Rooms::Direct',?,?,?)",[sql_text(user),sql_text(now),sql_text(now)]); room=sqlite::last_insert_rowid(db);
                        for id in ids {sql_rows(db,"INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,'everything',?,?)",[sql_text(room),sql_text(id),sql_text(now),sql_text(now)]); grants.push(id); grants.push(room);}
                    }
                    location=str("/rooms/",room);
                }
            } else {
                content.append("<turbo-frame id=\"direct_rooms_control\" target=\"_top\"><div class=\"directs directs--new flex flex-column gap\"><form class=\"flex gap flex-item-grow\" data-controller=\"form\" data-action=\"keydown.esc->form#cancel\" action=\"/rooms/directs\" method=\"post\"><a class=\"btn\" data-turbo-frame=\"user_sidebar\" data-form-target=\"cancel\" href=\"/users/me/sidebar\">Cancel changes</a><section class=\"autocomplete__container unpad input input--actor\"><div class=\"autocomplete__input input flex flex-wrap position-relative flex-item-grow\" data-controller=\"autocomplete\" data-autocomplete-url-value=\"/autocompletable/users\"><select name=\"user_ids[]\" data-autocomplete-target=\"select\" data-template-id=\"autocompletable-user\" multiple hidden required></select><template id=\"autocompletable-user\"><div class=\"autocomplete__pill max-width\" data-value=\"\" tabindex=\"0\"><img class=\"avatar\" data-content=\"avatar\" src=\"\"><span data-content=\"label\"></span><button type=\"button\" data-action=\"autocomplete#remove:prevent\" data-value=\"\"><span data-content=\"screenReaderLabel\"></span></button></div></template><input autocomplete=\"off\" class=\"autocomplete__input input\" data-autocomplete-target=\"input\" data-action=\"input->autocomplete#search keydown->autocomplete#didPressKey\" type=\"text\" name=\"rooms_direct[user_ids_input]\" id=\"rooms_direct_user_ids_input\"></div></section><button type=\"submit\" class=\"btn\">Start Ping</button></form></div></turbo-frame>");
            }
        } else if autocomplete {
            json_response=true; content.push('['); var first=true; var query: u8[>..]=[];
            let raw,has_query=http::query_of(req.target,"query"); if has_query {http::decode(raw,query,true);}
            let users=sql_rows(db,"SELECT id FROM users WHERE status=0 AND id<>? AND role<>2 AND name LIKE ? ORDER BY name LIMIT 50",[sql_text(user),str("%",query,"%")]);
            var bytes: u8[>..]=[];
            for row in users {for cell in row {
                let id,valid=parse_int(cell); let person=load_user(db,id,key,bytes); var escaped_name: u8[>..]=[]; escape(escaped_name,person.name);
                if !first {content.push(',');} first=false; format(content,"{\"value\":",id,",\"name\":"); json::format_string(content,escaped_name); content.append(",\"avatar_url\":"); json::format_string(content,person.avatar_url); content.append(",\"type\":\"user\"}");
            }} content.push(']');
        } else if bots {
            var id: i64=0;
            if starts_with(path,"/account/bots/") && path!="/account/bots/new" { let part=path[14..]; let slash=find(part,"/"); let n,ok=parse_int(if slash<0 {part} else {part[..slash]}); id=n; }
            if writing {
                var name: u8[>..]=[];
                if http::form_value(body,"user[name]",name) && name.len>0 {
                    if id==0 {
                        sql_rows(db,"INSERT INTO users(name,role,status,bot_token,created_at,updated_at) VALUES(?,2,0,?,?,?)",[sql_text(name),random_token(),sql_text(now),sql_text(now)]); id=sqlite::last_insert_rowid(db);
                        sql_rows(db,"INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT id,?,'everything',?,? FROM rooms WHERE type='Rooms::Open'",[sql_text(id),sql_text(now),sql_text(now)]);
                    } else { sql_rows(db,"UPDATE users SET name=?,updated_at=? WHERE id=? AND role=2",[sql_text(name),sql_text(now),sql_text(id)]); }
                    location=str("/account/bots");
                } else { status=422; }
            } else if path=="/account/bots/new" || id>0 {
                let action: u8[>..]=if id==0 {str("/account/bots")} else {str("/account/bots/",id)}; let name: u8[]=if id==0 {[]} else {sql_value(db,"SELECT name FROM users WHERE id=? AND role=2",[sql_text(id)])}; form_start(content,action); form_input(content,"user[name]","Name the bot",name); form_end(content);
            } else {
                let rows=sql_rows(db,"SELECT u.id,u.name,u.bot_token,m.room_id FROM users u JOIN memberships m ON m.user_id=u.id WHERE u.role=2 AND u.status=0 ORDER BY u.id,m.room_id",[]);
                var previous: u8[>..]=[];
                for row in rows { var bot_id: u8[>..]=[]; var name: u8[>..]=[]; var token: u8[>..]=[]; for cell,i in row {
                    if i==0 {bot_id=copy(cell);} else if i==1 {name=copy(cell);} else if i==2 {token=copy(cell);} else {
                        if bot_id!=previous {format(content,"<a href=\"/account/bots/",bot_id,"/edit\">Edit "); escape(content,name); content.append("</a>"); previous=copy(bot_id);}
                        content.append("<input aria-label=\"curl command for posting messages\" value=\"");
                        escape(content,str("curl --data Hello ",request_base(req),"/rooms/",cell,"/",token,"/messages")); content.append("\">");
                    }
                } }
            }
        }
        if writing {
            sqlite::exec(db,"COMMIT");
            for i in grants.len / 2 { cable_grant(grants[2*i],grants[2*i+1]); }
        }
        if !json_response && location.len==0 { let css=sql_value(db,"SELECT custom_styles FROM accounts",[]); if css.len>0 { content.append("<style>"); escape(content,css); content.append("</style>"); } }
    };
    if writing { let cleanup=sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db,"ROLLBACK"); } }; campfire_writer_leave(); }
    if failed.len>0 { status=500; for e in failed { write_stderr(str(e.message,"\n")); } }
    if status!=200 { http::respond(out,status,"text/plain","Unable to complete request"); }
    else if location.len>0 { redirect(out,location); }
    else if json_response { http::respond(out,200,"application/json",content); }
    else { http::respond(out,200,"text/html; charset=utf-8",simple_page("Campfire",content)); }
    if status==200 && broadcast.len>0 { publish(0,http::later(out,60000),broadcast); }
    return true;
}

// The method a form asks for with Rails' _method, for a POST.
fn form_method(req: const http::Request&, body: const u8[:]) -> u8[] {
    if req.method != "POST" { return str(req.method); }
    var override: u8[>..] = [];
    if !http::form_value(body,"_method",override) { return str("POST"); }
    return str(if override == "patch" || override == "PATCH" { "PATCH" } else if override == "delete" || override == "DELETE" { "DELETE" } else if override == "put" || override == "PUT" { "PATCH" } else { "POST" });
}

// The ids a form names under field, repeated: "user_ids[]".
fn form_ids(body: const u8[:], field: const u8[:]) -> i64[>..] {
    var ids: i64[>..] = [];
    for part in split(body,"&") {
        let eq=find(part,"="); if eq<0 { continue; }
        var name: u8[>..]=[]; var value: u8[>..]=[];
        if !http::decode(part[..eq],name,true) || name!=field || !http::decode(part[eq+1..],value,true) { continue; }
        let id,valid=parse_int(value);
        if valid && id>0 { var seen=false; for existing in ids { if existing==id {seen=true;} } if !seen && ids.len<4096 { ids.push(id); } }
    }
    return ids;
}

fn found(out: http::Reply, location: const u8[:]) {
    http::start(out,302); http::field(out,"Location",location); http::finish(out,http::TEXT,"Redirecting");
}

// SessionsController#destroy: ends this session, and resets the user's cable connections, as
// terminate_current_session does. The signed-out ones are then refused when they reconnect.
fn sign_out(db: sqlite::Db, req: const http::Request&, body: const u8[:], key: const u8[:], out: http::Reply) {
    guard same_origin(req) else { http::respond(out,422,"text/plain","Invalid origin"); return; }
    let raw, has_cookie = http::cookie_of(req,"session_token");
    var token: u8[>..]=[]; var valid_until: u8[>..]=[]; var now: u8[>..]=[]; campfire_now(now);
    var user: i64 = 0;
    if has_cookie && now.len==24 && verify_cookie(raw,key,now,token,valid_until) {
        campfire_writer_enter();
        let failed=sqlite::run() {
            sqlite::exec(db,"BEGIN IMMEDIATE");
            user=sql_number(db,"SELECT s.user_id FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token=? AND u.status=0",[sql_text(token)]);
            if user>0 {
                var endpoint: u8[>..]=[];
                if http::form_value(body,"push_subscription_endpoint",endpoint) { sql_rows(db,"DELETE FROM push_subscriptions WHERE endpoint=? AND user_id=?",[sql_text(endpoint),sql_text(user)]); }
                sql_rows(db,"DELETE FROM sessions WHERE token=?",[sql_text(token)]);
            }
            sqlite::exec(db,"COMMIT");
            if user>0 { cable_revoke(user,true); }
        };
        let cleanup=sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db,"ROLLBACK"); } };
        campfire_writer_leave();
        if failed.len>0 { for e in failed { write_stderr(str(e.message,"\n")); } http::respond(out,500,"text/plain","Unable to sign out"); return; }
    }
    if user==0 { found(out,"/session/new"); return; }
    http::start(out,302);
    http::field(out,"Set-Cookie","session_token=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax");
    http::field(out,"Location","/"); http::finish(out,http::TEXT,"Signed out");
}

// Changes of access: an administrator deactivates a user (Accounts::UsersController#destroy, User#deactivate),
// and a room's administrator revises who is in it (Rooms::ClosedsController#update). Each revoked user's cable
// connections close once the change commits.
fn access_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    let deactivate = starts_with(path,"/account/users/");
    let closed = starts_with(path,"/rooms/closeds/");
    if !deactivate && !closed { return false; }
    let method = form_method(req,body);
    let tail = path[15..];
    let slash = find(tail,"/");
    let id, valid = parse_int(if slash<0 { tail } else { tail[..slash] });
    let edit = slash>=0 && tail[slash..]=="/edit";
    if !valid || id<=0 || slash>=0 && !edit { http::respond(out,404,"text/plain","Not found"); return true; }
    let writing = method=="PATCH" || method=="DELETE";
    if deactivate && (method!="DELETE" || edit) || closed && !(method=="PATCH" && !edit || method=="GET" && edit) {
        http::respond(out,405,"text/plain","Method not allowed"); return true;
    }
    if writing && !same_origin(req) { http::respond(out,422,"text/plain","Invalid origin"); return true; }
    var status: i32 = 200; var content: u8[>..]=[]; var location: u8[>..]=[];
    var grants: i64[>..]=[]; var revoked: i64[>..]=[];
    if writing { campfire_writer_enter(); }
    let failed=sqlite::run() {
        if writing { sqlite::exec(db,"BEGIN IMMEDIATE"); }
        let admin=sql_number(db,"SELECT role FROM users WHERE id=? AND status=0",[sql_text(user)])==1;
        var now: u8[>..]=[]; campfire_sql_now(now);
        if deactivate {
            if !admin { status=403; }
            else if sql_number(db,"SELECT count(*) FROM users WHERE id=? AND status=0",[sql_text(id)])==0 { status=404; }
            else {
                let t=random_token();
                let uuid=str(t[0..8],"-",t[8..12],"-",t[12..16],"-",t[16..20],"-",t[20..32]);
                sql_rows(db,"DELETE FROM memberships WHERE user_id=? AND room_id IN (SELECT id FROM rooms WHERE type<>'Rooms::Direct')",[sql_text(id)]);
                sql_rows(db,"DELETE FROM push_subscriptions WHERE user_id=?",[sql_text(id)]);
                sql_rows(db,"DELETE FROM searches WHERE user_id=?",[sql_text(id)]);
                sql_rows(db,"DELETE FROM sessions WHERE user_id=?",[sql_text(id)]);
                sql_rows(db,"UPDATE users SET status=1,email_address=replace(email_address,'@','-deactivated-'||?||'@'),updated_at=? WHERE id=?",[sql_text(uuid),sql_text(now),sql_text(id)]);
                revoked.push(id);
                location=str("/account/edit");
            }
        } else {
            let kind=sql_value(db,"SELECT r.type FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=?",[sql_text(id),sql_text(user)]);
            if kind.len==0 || kind=="Rooms::Direct" { status=404; }
            else if !admin && sql_number(db,"SELECT count(*) FROM rooms WHERE id=? AND creator_id=?",[sql_text(id),sql_text(user)])==0 { status=403; }
            else if writing {
                var name: u8[>..]=[];
                if http::form_value(body,"room[name]",name) && name.len>0 { sql_rows(db,"UPDATE rooms SET name=? WHERE id=?",[sql_text(name),sql_text(id)]); }
                sql_rows(db,"UPDATE rooms SET type='Rooms::Closed',updated_at=? WHERE id=?",[sql_text(now),sql_text(id)]);
                // Membership#revise: grant the users named, and revoke the members not named.
                let granted=form_ids(body,"user_ids[]");
                for uid in granted {
                    if sql_number(db,"SELECT count(*) FROM users WHERE id=?",[sql_text(uid)])>0 &&
                       sql_number(db,"SELECT count(*) FROM memberships WHERE room_id=? AND user_id=?",[sql_text(id),sql_text(uid)])==0 {
                        sql_rows(db,"INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,'mentions',?,?)",[sql_text(id),sql_text(uid),sql_text(now),sql_text(now)]);
                        grants.push(uid); grants.push(id);
                    }
                }
                for row in sql_rows(db,"SELECT user_id FROM memberships WHERE room_id=?",[sql_text(id)]) {
                    for cell in row {
                        let member,ok=parse_int(cell); var kept=false;
                        for uid in granted { if uid==member {kept=true;} }
                        if ok && !kept { revoked.push(member); }
                    }
                }
                for member in revoked { sql_rows(db,"DELETE FROM memberships WHERE room_id=? AND user_id=?",[sql_text(id),sql_text(member)]); }
                location=str("/rooms/",id);
            } else {
                form_start(content,str("/rooms/closeds/",id));
                content.append("<input type=\"hidden\" name=\"_method\" value=\"patch\">");
                form_input(content,"room[name]","Name this room",sql_value(db,"SELECT name FROM rooms WHERE id=?",[sql_text(id)]));
                for row in sql_rows(db,"SELECT u.id,u.name,(SELECT count(*) FROM memberships m WHERE m.room_id=? AND m.user_id=u.id) FROM users u WHERE u.status=0 ORDER BY LOWER(u.name)",[sql_text(id)]) {
                    var uid: u8[>..]=[]; var uname: u8[>..]=[];
                    for cell,i in row {
                        if i==0 { uid=copy(cell); } else if i==1 { uname=copy(cell); }
                        else {
                            content.append("<label><input type=\"checkbox\" name=\"user_ids[]\" value=\""); escape(content,uid); content.append("\"");
                            if cell!="0" { content.append(" checked"); }
                            content.append("> "); escape(content,uname); content.append("</label>");
                        }
                    }
                }
                form_end(content,"Save");
            }
        }
        if writing {
            sqlite::exec(db,"COMMIT");
            for i in grants.len / 2 { cable_grant(grants[2*i],grants[2*i+1]); }
            // Membership's after_destroy_commit and User#deactivate: reset_remote_connections, close_remote_connections.
            for member in revoked { cable_revoke(member,!deactivate); }
        }
    };
    if writing { let cleanup=sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db,"ROLLBACK"); } }; campfire_writer_leave(); }
    if failed.len>0 { status=500; for e in failed { write_stderr(str(e.message,"\n")); } }
    if status!=200 { http::respond(out,status,"text/plain","Unable to complete request"); }
    else if location.len>0 { found(out,location); }
    else { http::respond(out,200,"text/html; charset=utf-8",simple_page("Campfire",content)); }
    return true;
}
