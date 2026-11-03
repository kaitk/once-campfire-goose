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
import https;

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
    return base_url(req);
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
    let user = verify_id(token,TRANSFER_PURPOSE,signing_key,now);
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
