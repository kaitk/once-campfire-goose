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
import admin_routes;
import storage;
import media;
import avatars;

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
                start_session(db,req,out,user,session,stamp);
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

fn browser_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], key: const u8[:], sgid_key: const u8[:], storage: const u8[:], out: http::Reply) -> bool {
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
    var status: i32=200; var content: u8[>..]=[]; var location: u8[>..]=[]; var broadcast: u8[>..]=[]; var json_response=false; var fragment_response=false;
    var keys: u8[][>..]=[]; var written: u8[>..]=[]; var avatar: i64=0;
    let raw_room,prompt=http::query_of(req.target,"room_id");
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
                let kind,has_kind=http::field_of(req,"Content-Type");
                if has_kind && starts_with(kind,"multipart/form-data") {
                    // The profile form as Rails renders it: multipart, with the avatar.
                    let b,bf,has_bio=http::find_part(req,body,"user[bio]"); let n,nf,has_name=http::find_part(req,body,"user[name]");
                    if has_bio==http::PART_FOUND { sql_rows(db,"UPDATE users SET bio=?,updated_at=? WHERE id=?",[sql_text(b),sql_text(now),sql_text(user)]); }
                    if has_name==http::PART_FOUND && n.len>0 { sql_rows(db,"UPDATE users SET name=?,updated_at=? WHERE id=?",[sql_text(n),sql_text(now),sql_text(user)]); }
                    let data,fields,found=http::find_part(req,body,"user[avatar]");
                    let part,raw_filename,disposed=http::disposition(fields);
                    if found==http::PART_TYPE || found==http::PART_BAD { status=400; }
                    else if found==http::PART_FOUND && data.len>0 && raw_filename.len>0 {
                        let declared,typed=http::field_in(fields,"content-type");
                        var upload=Upload { .. };
                        if !stage_upload(storage,data,unquote_filename(raw_filename),declared,upload) { sqlite::fail("Cannot write the avatar"); }
                        written.append(upload.key);
                        // has_one_attached replaces the avatar, purging the old one; the attachment touches the user.
                        purge_attachments(db,"record_type='User' AND name='avatar' AND record_id=?",[sql_text(user)],keys);
                        let blob=save_upload(db,upload,"avatar","User",user,now);
                        if variable_content_type(upload.content_type) { avatar=blob; }
                        sql_rows(db,"UPDATE users SET updated_at=? WHERE id=?",[sql_text(now),sql_text(user)]);
                    }
                } else {
                    if http::form_value(body,"user[bio]",bio) { sql_rows(db,"UPDATE users SET bio=?,updated_at=? WHERE id=?",[sql_text(bio),sql_text(now),sql_text(user)]); }
                    if http::form_value(body,"user[name]",name) && name.len>0 { sql_rows(db,"UPDATE users SET name=?,updated_at=? WHERE id=?",[sql_text(name),sql_text(now),sql_text(user)]); }
                }
                location=str(path);
            } else {
                // The avatar's upload and delete, as users/profiles/show.html.erb has them beside the profile form.
                let has_avatar=sql_number(db,"SELECT count(*) FROM active_storage_attachments WHERE record_type='User' AND name='avatar' AND record_id=?",[sql_text(user)])>0;
                content.append("<form data-turbo=\"false\" method=\"post\" enctype=\"multipart/form-data\" action=\""); escape(content,path);
                content.append("\"><input type=\"hidden\" name=\"_method\" value=\"patch\"><img src=\""); escape(content,avatar_path(user,key));
                content.append("\" width=\"64\" height=\"64\" alt=\"\"><label>Avatar<input type=\"file\" accept=\"image/*\" name=\"user[avatar]\" id=\"user_avatar\"></label><button type=\"submit\">Upload avatar</button></form>");
                if has_avatar {
                    content.append("<form data-turbo=\"false\" method=\"post\" action=\""); escape(content,str("/users/",user,"/avatar"));
                    content.append("\"><input type=\"hidden\" name=\"_method\" value=\"delete\"><button type=\"submit\">Delete avatar</button></form>");
                }
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
                account_admin_html(db,user,admin,key,content);
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
                // `rooms_directs_path(user_ids: [id])` carries the ids in the query.
                let query_start=find(req.target,"?"); let query=if query_start<0 { "" } else { req.target[query_start+1..] };
                for field in split(str(body,"&",query),"&") {
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
        } else if autocomplete && prompt {
            // The mentions prompt: <lexxy-prompt-item> elements for the room's active users, bots included.
            let room,valid=parse_int(raw_room);
            if !valid || sql_number(db,"SELECT count(*) FROM memberships WHERE room_id=? AND user_id=?",[sql_text(room),sql_text(user)])==0 { status=404; }
            else {
                fragment_response=true; var filter: u8[>..]=[];
                let raw_filter,has_filter=http::query_of(req.target,"filter"); let raw_query,has_query=http::query_of(req.target,"query");
                if has_filter && raw_filter.len>0 { http::decode(raw_filter,filter,true); } else if has_query { http::decode(raw_query,filter,true); }
                let users=sql_rows(db,"SELECT u.id FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.room_id=? AND u.status=0 AND u.name LIKE ? ORDER BY LOWER(u.name) LIMIT 20",[sql_text(room),str("%",filter,"%")]);
                var bytes: u8[>..]=[];
                for row in users {for cell in row {
                    let id,ok=parse_int(cell); let person=load_user(db,id,key,bytes); let sgid=attachable_sgid(id,sgid_key);
                    var avatar: u8[>..]=[];
                    avatar.append("<a class=\"btn avatar\" title=\""); escape(avatar,person.title); avatar.append("\" href=\""); escape(avatar,person.path);
                    avatar.append("\"><img src=\""); escape(avatar,person.avatar_url); avatar.append("\" width=\"48\" height=\"48\"></a>");
                    content.append("<lexxy-prompt-item search=\""); escape(content,person.name); content.append("\" sgid=\""); escape(content,sgid);
                    content.append("\">\n  <template type=\"menu\">\n    <span class=\"autocomplete__item flex align-center gap unpad\">\n      "); content.append(avatar);
                    content.append("\n      <span class=\"autocompletable__name\">"); escape(content,person.name); content.append("</span>\n    </span>\n  </template>\n  <template type=\"editor\">\n    <span class=\"mention\" sgid=\"");
                    escape(content,sgid); content.append("\">"); content.append(avatar); content.push(' '); escape(content,person.name); content.append("</span>\n  </template>\n</lexxy-prompt-item>\n");
                }}
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
                var name: u8[>..]=[]; var given_url: u8[>..]=[]; http::form_value(body,"user[webhook_url]",given_url); let url=trim(given_url);
                if http::form_value(body,"user[name]",name) && name.len>0 {
                    if id==0 {
                        sql_rows(db,"INSERT INTO users(name,role,status,bot_token,created_at,updated_at) VALUES(?,2,0,?,?,?)",[sql_text(name),random_token(),sql_text(now),sql_text(now)]); id=sqlite::last_insert_rowid(db);
                        sql_rows(db,"INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT id,?,'everything',?,? FROM rooms WHERE type='Rooms::Open'",[sql_text(id),sql_text(now),sql_text(now)]);
                        if url.len>0 { sql_rows(db,"INSERT INTO webhooks(user_id,url,created_at,updated_at) VALUES(?,?,?,?)",[sql_text(id),sql_text(url),sql_text(now),sql_text(now)]); }
                    } else if sql_number(db,"SELECT count(*) FROM users WHERE id=? AND role=2 AND status=0",[sql_text(id)])>0 {
                        sql_rows(db,"UPDATE users SET name=?,updated_at=? WHERE id=? AND role=2",[sql_text(name),sql_text(now),sql_text(id)]);
                        // User#update_bot!: a present URL updates or creates the webhook, a blank one deletes it.
                        if url.len==0 { sql_rows(db,"DELETE FROM webhooks WHERE user_id=?",[sql_text(id)]); }
                        else if sql_number(db,"SELECT count(*) FROM webhooks WHERE user_id=?",[sql_text(id)])>0 { sql_rows(db,"UPDATE webhooks SET url=?,updated_at=? WHERE user_id=?",[sql_text(url),sql_text(now),sql_text(id)]); }
                        else { sql_rows(db,"INSERT INTO webhooks(user_id,url,created_at,updated_at) VALUES(?,?,?,?)",[sql_text(id),sql_text(url),sql_text(now),sql_text(now)]); }
                    } else { status=404; }
                    if status==200 { location=str("/account/bots"); }
                } else { status=422; }
            } else if path=="/account/bots/new" || id>0 {
                let action: u8[>..]=if id==0 {str("/account/bots")} else {str("/account/bots/",id)}; let name: u8[]=if id==0 {[]} else {sql_value(db,"SELECT name FROM users WHERE id=? AND role=2",[sql_text(id)])};
                let url: u8[]=if id==0 {[]} else {sql_value(db,"SELECT url FROM webhooks WHERE user_id=? ORDER BY id LIMIT 1",[sql_text(id)])};
                form_start(content,action); form_input(content,"user[name]","Name the bot",name); form_input(content,"user[webhook_url]","Webhook URL",url); form_end(content);
            } else {
                let rows=sql_rows(db,"SELECT u.id,u.name,u.bot_token,m.room_id FROM users u JOIN memberships m ON m.user_id=u.id WHERE u.role=2 AND u.status=0 ORDER BY u.id,m.room_id",[]);
                var previous: u8[>..]=[];
                for row in rows { var bot_id: u8[>..]=[]; var name: u8[>..]=[]; var token: u8[>..]=[]; for cell,i in row {
                    if i==0 {bot_id=copy(cell);} else if i==1 {name=copy(cell);} else if i==2 {token=copy(cell);} else {
                        if bot_id!=previous {format(content,"<a href=\"/account/bots/",bot_id,"/edit\">Edit "); escape(content,name); content.append("</a>"); previous=copy(bot_id);}
                        content.append("<input aria-label=\"curl command for posting messages\" value=\"");
                        escape(content,str("curl --data Hello ",request_base(req),"/rooms/",cell,"/",bot_id,"-",token,"/messages")); content.append("\">");
                    }
                } }
            }
        }
        if writing {
            sqlite::exec(db,"COMMIT");
            for i in grants.len / 2 { cable_grant(grants[2*i],grants[2*i+1]); }
        }
        if !json_response && !fragment_response && location.len==0 { let css=sql_value(db,"SELECT custom_styles FROM accounts",[]); if css.len>0 { content.append("<style>"); escape(content,css); content.append("</style>"); } }
    };
    if writing { let cleanup=sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db,"ROLLBACK"); } }; campfire_writer_leave(); }
    if failed.len>0 { status=500; for e in failed { write_stderr(str(e.message,"\n")); } }
    // An uploaded avatar's file goes with a transaction that didn't commit; a replaced one's after one that did.
    if written.len>0 && (failed.len>0 || status!=200) { delete_blob_file(storage,written); }
    if failed.len==0 && status==200 {
        delete_blob_files(storage,keys);
        if avatar>0 { process_later(MEDIA_AVATAR,avatar,user,avatar_variation()); }
    }
    if status!=200 { http::respond(out,status,"text/plain","Unable to complete request"); }
    else if location.len>0 { redirect(out,location); }
    else if json_response { http::respond(out,200,"application/json",content); }
    else if fragment_response { http::respond(out,200,"text/html; charset=utf-8",content); }
    else { http::respond(out,200,"text/html; charset=utf-8",simple_page("Campfire",content)); }
    if status==200 && broadcast.len>0 { publish(0,http::later(out,60000),broadcast); }
    return true;
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
    if user==0 { redirect_found(out,"/session/new"); return; }
    http::start(out,302);
    http::field(out,"Set-Cookie","session_token=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax");
    http::field(out,"Location","/"); http::finish(out,http::TEXT,"Signed out");
}
