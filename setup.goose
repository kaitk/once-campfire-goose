namespace campfire;
import std;
import http;
import sqlite;
import hash;
import database;
import auth;
import sessions;
import messages;
import html;
import view_assets_generated;

extern fn campfire_password_hash(password: const u8[:], entropy: const u8[:], out: u8[>..]&) -> bool;

fn random_token() -> u8[] {
    var bytes: u8[32] = [0;32]; hash::random_bytes(bytes);
    var out: u8[>..] = []; let digits="0123456789abcdef";
    for c in bytes { out.push(digits[c >> 4]); out.push(digits[c & 15]); }
    return out;
}

fn redirect(out: http::Reply, path: const u8[:]) {
    http::start(out,303); http::field(out,"Location",path); http::finish(out,http::TEXT,"Redirecting");
}

fn session_created(out: http::Reply, token: const u8[:], key: const u8[:], location: const u8[:]) {
    var expiry: u8[>..]=[]; campfire_expiry(expiry);
    http::start(out,303);
    http::field(out,"Set-Cookie",str("session_token=",sign_cookie(token,key,expiry),"; Path=/; HttpOnly; SameSite=Lax; Max-Age=630720000"));
    http::field(out,"Location",location); http::finish(out,http::TEXT,"Signed in");
}

fn simple_page(title: const u8[:], content: const u8[:]) -> u8[>..] {
    var out: u8[>..]=[];
    out.append("<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>");
    escape(out,title); out.append("</title>"); out.append(VIEW_STYLESHEET_TAGS); out.append(VIEW_IMPORTMAP_TAGS);
    out.append("</head><body><nav id=\"nav\"></nav><main id=\"main-content\"><section class=\"center max-width pad\">");
    out.append(content); out.append("</section></main></body></html>"); return out;
}

fn setup_route(db: sqlite::Db, req: const http::Request&, body: const u8[:], key: const u8[:], out: http::Reply) -> bool {
    let path=http::path_of(req.target);
    if path!="/first_run" && !starts_with(path,"/join/") && path!="/" { return false; }
    var handled=false;
    var status: i32=200;
    var token: u8[>..]=[];
    var destination: u8[>..]=[];
    var page: u8[>..]=[];
    let failed=sqlite::run() {
        let exists=sql_number(db,"SELECT count(*) FROM accounts",[])>0;
        if path=="/" {
            if !exists { destination="/first_run"; handled=true; }
        } else {
            handled=true;
            let first=path=="/first_run";
            let code=if first { "" } else { path[6..] };
            let allowed=if first { !exists } else { sql_number(db,"SELECT count(*) FROM accounts WHERE join_code=?",[sql_text(code)])>0 };
            if !allowed { status=if first { 409 } else { 404 }; }
            else if req.method=="GET" {
                var form: u8[>..]=[];
                form.append("<h1>"); escape(form,if first { "Set up Campfire" } else { "Join Campfire" });
                form.append("</h1><form method=\"post\" data-turbo=\"false\" action=\""); escape(form,path);
                form.append("\"><label>Name<input name=\"user[name]\" autocomplete=\"name\" required></label><label>Email address<input name=\"user[email_address]\" type=\"email\" autocomplete=\"username\" required></label><label>Password<input name=\"user[password]\" type=\"password\" autocomplete=\"new-password\" maxlength=\"72\" required></label><button type=\"submit\">Save</button></form>");
                page=simple_page("Campfire",form);
            } else if req.method=="POST" {
                var name: u8[>..]=[]; var email: u8[>..]=[]; var password: u8[>..]=[];
                let valid=same_origin(req) && http::form_value(body,"user[name]",name) && trim(name).len>0 && name.len<=255 &&
                    http::form_value(body,"user[email_address]",email) && find(email,"@")>0 && email.len<=255 &&
                    http::form_value(body,"user[password]",password) && password.len>0 && password.len<=72;
                if !valid { status=422; }
                else {
                    var entropy: u8[16]=[0;16]; hash::random_bytes(entropy); var digest: u8[>..]=[];
                    if !campfire_password_hash(password,entropy,digest) { sqlite::fail("Password hashing failed"); }
                    var now: u8[>..]=[]; campfire_sql_now(now); token=random_token();
                    campfire_writer_enter();
                    let transaction=sqlite::run() {
                        sqlite::exec(db,"BEGIN IMMEDIATE");
                        let permitted=if first { sql_number(db,"SELECT count(*) FROM accounts",[])==0 }
                                      else { sql_number(db,"SELECT count(*) FROM accounts WHERE join_code=?",[sql_text(code)])>0 };
                        if !permitted { status=409; }
                        else {
                            if first { sql_rows(db,"INSERT INTO accounts(name,join_code,settings,created_at,updated_at) VALUES('Campfire',?,'{}',?,?)",[random_token(),sql_text(now),sql_text(now)]); }
                            sql_rows(db,"INSERT INTO users(name,email_address,password_digest,role,status,created_at,updated_at) VALUES(?,?,?,?,0,?,?)",[sql_text(trim(name)),sql_text(trim(email)),sql_text(digest),sql_text(if first { 1 } else { 0 }),sql_text(now),sql_text(now)]);
                            let user=sqlite::last_insert_rowid(db);
                            if first { sql_rows(db,"INSERT INTO rooms(name,type,creator_id,created_at,updated_at) VALUES('All Talk','Rooms::Open',?,?,?)",[sql_text(user),sql_text(now),sql_text(now)]); }
                            sql_rows(db,"INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT id,?,'mentions',?,? FROM rooms WHERE type='Rooms::Open'",[sql_text(user),sql_text(now),sql_text(now)]);
                            start_session(db,req,out,user,token,now);
                            let room=sql_number(db,"SELECT room_id FROM memberships WHERE user_id=? ORDER BY room_id LIMIT 1",[sql_text(user)]);
                            destination=str("/rooms/",room);
                        }
                        sqlite::exec(db,"COMMIT");
                    };
                    let cleanup=sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db,"ROLLBACK"); } };
                    campfire_writer_leave();
                    for error in transaction {
                        if sqlite::primary(error.code)==sqlite::CONSTRAINT { status=422; }
                        else { sqlite::fail(error.code,error.message); }
                    }
                }
            } else { status=405; }
        }
    };
    if failed.len>0 { status=500; handled=true; for error in failed { write_stderr(str(error.message,"\n")); } }
    if handled {
        if status!=200 { http::respond(out,status,"text/plain","Unable to set up account"); }
        else if destination.len>0 {
            if token.len>0 { session_created(out,token,key,destination); } else { redirect(out,destination); }
        } else { http::respond(out,200,"text/html; charset=utf-8",page); }
    }
    return handled;
}
