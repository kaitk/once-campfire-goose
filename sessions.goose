namespace campfire;

import std;
import sqlite;
import http;
import hash;
import auth;
import messages;
import database;

extern fn campfire_password_verify(password: const u8[:], digest: const u8[:]) -> i32;
extern fn campfire_expiry(out: u8[>..]&);
extern fn campfire_sql_now(out: u8[>..]&);

// ActionDispatch::RemoteIp::TRUSTED_PROXIES.
const TRUSTED_PROXIES: const u8[:][8] = ["127.0.0.0/8", "::1/128", "fc00::/7", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fe80::/10"];

// request.remote_ip: the peer, or the client a trusted proxy forwarded the request for; empty
// when the connection has no IP peer. Without FORWARD_HEADERS, TLS_DOMAIN's default, Thruster
// forwards only the peer's address, so no proxy is trusted.
fn remote_ip(req: const http::Request&, out: http::Reply) -> u8[>..] {
    var nets: http::Network[>..] = [];
    if scheme_config.forward_headers { for text in TRUSTED_PROXIES { let n, ok = http::network(text); if ok { nets.push(n); } } }
    let a, known = http::client(req, out, nets);
    var ip: u8[>..] = [];
    if known { http::format_address(ip, a); }
    return ip;
}

// Session.start!(user_agent: request.user_agent, ip_address: request.remote_ip) for user, with
// token, at now. Inside a sqlite::run.
fn start_session(db, req: const http::Request&, out: http::Reply, user: i64, token: const u8[:], now: const u8[:]) {
    let agent, has_agent = http::field_of(req, "User-Agent");
    sql_rows(db, "INSERT INTO sessions(user_id,token,created_at,updated_at,last_active_at,user_agent,ip_address) VALUES(?,?,?,?,?,iif(?,?,NULL),NULLIF(?,''))",
             [sql_text(user), sql_text(token), sql_text(now), sql_text(now), sql_text(now), sql_text(if has_agent { 1 } else { 0 }), str(agent), sql_text(remote_ip(req, out))]);
}

// Session#resume: at most once an hour, the session's activity, user agent and address. Inside a
// sqlite::run.
fn resume_session(db, req: const http::Request&, out: http::Reply, session: i64) {
    let agent, has_agent = http::field_of(req, "User-Agent");
    var now: u8[>..] = []; campfire_sql_now(now);
    sql_rows(db, "UPDATE sessions SET user_agent=iif(?,?,NULL),ip_address=NULLIF(?,''),last_active_at=?,updated_at=? WHERE id=? AND last_active_at<strftime('%Y-%m-%d %H:%M:%f','now','-1 hour')",
             [sql_text(if has_agent { 1 } else { 0 }), str(agent), sql_text(remote_ip(req, out)), sql_text(now), sql_text(now), sql_text(session)]);
}

// BlockBannedRequests#reject_banned_ip: head :too_many_requests for a request other than GET or
// HEAD from a banned address.
fn banned_request(db: sqlite::Db, req: const http::Request&, out: http::Reply) -> bool {
    guard req.method != "GET" && req.method != "HEAD" else { return false; }
    let ip = remote_ip(req, out);
    guard ip.len > 0 else { return false; }
    var banned = false;
    let failed = sqlite::run() { banned = sql_number(db, "SELECT count(*) FROM bans WHERE ip_address=?", [sql_text(ip)]) > 0; };
    guard failed.len == 0 && banned else { return false; }
    http::respond(out, 429, "text/html", "");
    return true;
}
