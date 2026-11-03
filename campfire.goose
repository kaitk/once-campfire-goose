import std;
import database;
import setup;
import cable;
import message_actions;
import unfurl;
import browser_routes;
import boosts;
import room_pages;
import rooms;
import admin_routes;
import os;
import http from "github.com/kaitk/goose-http@v0.5.17";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import compress from "github.com/kaitk/goose-compress@v0.1.4";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import acme from "github.com/kaitk/goose-acme@v0.0.5";
import sqlite from "./build/sqlite";
import http.compression;
import http.tls;
import front;
import auth;
import pages;
import messages;
import checkpoints;
import sessions;
import assets;
import cache;
import avatars;
import signed_id;
import view_data;
import view_types;
import view_assets_generated;
import webhooks;
import storage;
import media;
import active_storage;
import push;
import account;
import search;
import auth_routes;

struct Settings {
    database: u8[..1024] = "campfire.sqlite3",
    cookie_key: u8[64] = [0; 64],
    storage_key: u8[64] = [0;64],
    stream_key: u8[64] = [0;64],
    vapid: u8[..256] = [],
    // Web Push sends notifications: VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY make a key pair.
    push: bool = false,
    avatar_key: u8[64] = [0; 64],
    sgid_key: u8[64] = [0; 64],
    storage: u8[..1024] = "storage",
    cache_enabled: bool = true,
    cache_diagnostics: bool = false,
    epoll: bool = true,
    cable_window: i64 = 8,
    cable_batch: i64 = 262144,
    cable_pass: i64 = 0,
    cable_pace: i64 = 0,
    cable_pace_frames: i64 = 16,
    upload_limit: i64 = 100 << 20,
    media_threads: i64 = 2,
    // How often an open cable connection looks its session up again, as Rails' check_session does each minute.
    cable_session_check_ms: i64 = 60000,
}

var settings = Settings { .. };

struct Exchange {
    body: http::Gather = http::Gather { .. },
    response: http::Gather = http::Gather { .. },
    commands: http::Gather = http::Gather { .. },
    ws: http::WebSocket = http::WebSocket { .. },
    upgraded: bool = false,
    fragmented: bool = false,
    // The worker's cable connection for this exchange, its generation, and whether it left.
    cable: i64 = -1,
    cable_gen: i64 = 0,
    left: bool = false,
    user: i64 = 0,
    presence: i64[16] = [0;16],
    // The request's body limit (campfire::body_limit), and a blob file being sent at each MORE.
    limit: i64 = 1 << 20,
    file: http::FileBody = http::FileBody { .. },
    // The cable connection's session token, and when it was last found (Rails checks once a minute).
    session: u8[..256] = [],
    checked_ms: i64 = 0,
    // When the connection's next typing event is due (campfire::cable_typing).
    typing: i64[1] = [0],
}

extern fn campfire_now(out: u8[>..]&);
extern fn campfire_sql_now(out: u8[>..]&);
extern fn campfire_after(seconds: i64, out: u8[>..]&);
extern fn campfire_profile_enable(enabled: bool);
extern fn campfire_ffmpeg_exists() -> bool;
extern fn campfire_cache_begin(handle: i64) -> i32;
extern fn campfire_cache_confirm(handle: i64);
extern fn campfire_cache_current(handle: i64) -> i32;

fn authenticate(db: sqlite::Db, req: const http::Request&, out: http::Reply, key: const u8[:], state: campfire::CacheState&) -> i64 {
    let raw, has_cookie = http::cookie_of(req, "session_token");
    guard has_cookie else { return 0; }
    var now: u8[>..] = [];
    campfire_now(now);
    guard now.len == 24 else { return 0; }
    if state.enabled && state.auth_user > 0 && raw == state.auth_cookie &&
       (state.auth_expiry.len == 0 || compare(now, state.auth_expiry) < 0) { return state.auth_user; }
    var token: u8[>..] = [];
    var valid_until: u8[>..] = [];
    guard campfire::verify_cookie(raw, key, now, token, valid_until) else { return 0; }
    var q = sqlite::Stmt {};
    var user: i64 = 0;
    var session: i64 = 0;
    var stale = false;
    var resume_at: u8[>..] = [];
    let failed = sqlite::run() {
        q = sqlite::prepare(db, "SELECT u.id,s.id,s.last_active_at<strftime('%Y-%m-%d %H:%M:%f','now','-1 hour'),strftime('%Y-%m-%dT%H:%M:%fZ',s.last_active_at,'+1 hour') FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token=? AND u.status=0");
        sqlite::bind_text(q, 1, token);
        if sqlite::step(q) {
            user = sqlite::column_i64(q, 0); session = sqlite::column_i64(q, 1); stale = sqlite::column_i64(q, 2) != 0;
            sqlite::column_text(q, 3, resume_at);
        }
        sqlite::finalize(q); q = sqlite::Stmt {};
        if stale { state.resume_session = session; resume_at = []; campfire_after(3600, resume_at); }
    };
    sqlite::finalize(q);
    // Both the session row and the signed-cookie expiry must still be valid. A cached sign-in is
    // looked up again once its session's hourly resume is due, so no resume is skipped.
    if state.enabled && failed.len == 0 && user > 0 {
        state.auth_cookie = raw;
        state.auth_expiry = if resume_at.len == 24 && compare(resume_at, valid_until) < 0 { resume_at } else { valid_until };
        state.auth_user = user;
    }
    return if failed.len == 0 { user } else { 0 };
}

// authenticate for a cable connection, which keeps its session token to check again later.
fn cable_authenticate(db: sqlite::Db, req: const http::Request&, key: const u8[:], token: u8[>..]&) -> i64 {
    let raw, has_cookie = http::cookie_of(req, "session_token");
    guard has_cookie else { return 0; }
    var now: u8[>..] = [];
    campfire_now(now);
    guard now.len == 24 else { return 0; }
    var valid_until: u8[>..] = [];
    guard campfire::verify_cookie(raw, key, now, token, valid_until) else { return 0; }
    return max(campfire::cable_session_user(db, token), 0);
}

fn handle(db: sqlite::Db, writer: const campfire::WriterStatements&, entries: campfire::CachedPage[:], bytes: u8[>..]&, state: campfire::CacheState&,
          req: const http::Request&, body: const u8[:], out: http::Reply) {
    let path = http::path_of(req.target);
    if starts_with(path,"/assets/") && (req.method=="GET" || req.method=="HEAD") {
        let index=campfire::asset_public_index(path); var data: u8[>..]=[];
        if index>=0 && read_file(str("assets/reference/",campfire::asset_filename(index)),data) {
            http::start(out,200); http::field(out,"Cache-Control","public, max-age=31536000, immutable");
            http::field(out,"Content-Type",campfire::asset_mime(index));
            http::finish(out,http::NO_TYPE,data);
        } else { http::respond(out,404,"text/plain","Asset not found"); } return;
    }
    if path == "/up" {
        http::respond(out, 200, "text/html", "<!DOCTYPE html><html><body style=\"background-color: green\"></body></html>");
        return;
    }
    if campfire::public_controller_path(req) && campfire::allow_browser(db, req, out) { return; }
    if campfire::public_route(db, req, settings.storage, out) { return; }
    if campfire::qr_code_route(req, out) { return; }
    if campfire::active_storage_route(db, req, settings.storage, settings.storage_key, out) { return; }
    if campfire::banned_request(db, req, out) { return; }
    if campfire::auth_route(db, req, body, out) { return; }
    if campfire::bot_route(db,writer,req,body,settings.avatar_key,settings.storage_key,settings.storage,out) { return; }
    let user = authenticate(db, req, out, settings.cookie_key, state);
    if user == 0 { campfire::request_authentication(req, out); return; }
    if campfire::authenticated_route(db, user, req, body, out) { return; }
    if campfire::unfurl_route(req,body,out) { return; }
    if campfire::message_actions(db,user,req,body,settings.storage_key,settings.avatar_key,settings.storage,settings.stream_key,settings.vapid,settings.sgid_key,out) { return; }
    if campfire::account_route(db,user,req,body,settings.avatar_key,settings.stream_key,settings.vapid,settings.storage_key,settings.storage,settings.cookie_key,out) { return; }
    if campfire::admin_route(db,user,req,body,settings.storage,settings.avatar_key,out) { return; }
    if campfire::rooms_route(db,user,req,body,settings.avatar_key,settings.sgid_key,settings.storage_key,settings.stream_key,settings.vapid,settings.storage,out) { return; }
    if campfire::boost_route(db,user,req,body,settings.avatar_key,settings.storage_key,settings.stream_key,settings.vapid,out) { return; }
    if campfire::room_page_route(db,user,req,body,settings.avatar_key,settings.storage_key,settings.stream_key,settings.vapid,settings.storage,out) { return; }
    let page_keys = campfire::PageKeys { cookie: settings.cookie_key, avatar: settings.avatar_key, stream: settings.stream_key, vapid: settings.vapid, storage: settings.storage_key };
    if campfire::search_route(db,user,req,body,entries,bytes,state,page_keys,out) { return; }
    if (req.method == "POST" || req.method == "DELETE") && starts_with(path, "/users/") && ends_with(path, "/avatar") {
        campfire::destroy_avatar(db, user, req, body, settings.storage, out);
        return;
    }
    guard req.method == "GET" || req.method == "HEAD" || req.method == "POST" else {
        http::respond(out, 405, "text/plain", "Method not allowed");
        return;
    }
    if req.method == "POST" && !starts_with(path, "/rooms/") {
        http::respond(out, 405, "text/plain", "Method not allowed");
        return;
    }
    if (req.method == "GET" || req.method == "HEAD") && starts_with(path, "/users/") && ends_with(path, "/avatar") {
        var token: u8[>..] = [];
        if http::decode(path[7..path.len - 7], token, false) {
            var now: u8[>..] = [];
            campfire_now(now);
            campfire::avatar(db, req, token, settings.avatar_key, settings.storage, now, out);
        } else { http::respond(out, 404, "text/plain", "Not found"); }
        return;
    }
    if req.method != "POST" && !ends_with(path,"/refresh") && campfire::cached_page(entries, bytes, state, user, req, out) { return; }
    var html: u8[>..] = [];
    var status: i32 = 200;
    var posted = false; var posted_ms: i64 = 0;
    var stream_response = false;
    var view_bytes: u8[>..]=[];
    let failed = sqlite::run() {
        let context_start=campfire::campfire_profile_clock();
        var ctx=campfire::ViewContext { .. };
        ctx.storage_key=settings.storage_key;
        if req.method=="POST" { ctx.user=campfire::load_user(db,user,settings.avatar_key,view_bytes); }
        else { ctx=campfire::load_view_context(db,user,settings.avatar_key,settings.stream_key,settings.vapid,req,view_bytes,settings.storage_key); }
        if path == "/users/me/sidebar" {
            campfire::sidebar(db, user, settings.avatar_key, ctx, view_bytes, html);
        } else if starts_with(path, "/rooms/") {
            let tail = path[7..];
            let slash = find(tail, "/");
            let number = if slash >= 0 { tail[..slash] } else { tail };
            let room, valid = parse_int(number);
            let messages = slash >= 0 && tail[slash..] == "/messages";
            if valid && room > 0 && slash >= 0 && tail[slash..] == "/refresh" && req.method == "GET" {
                let since, exists = http::query_int(req.target,"since");
                status=campfire::refresh_room(db,user,room,since,settings.avatar_key,ctx,view_bytes,html); stream_response=true;
            } else if valid && room > 0 && (slash < 0 || messages) {
                if req.method == "POST" && messages {
                    var now: u8[>..] = [];
                    campfire_sql_now(now);
                    status = campfire::post_message(db, writer, req, body, user, room, now, settings.avatar_key, ctx, view_bytes, context_start, html, settings.storage);
                    posted = true; posted_ms = campfire::campfire_epoch_ms(now);
                } else {
                    // GET rooms#show and messages#index are search_route's.
                    status = if req.method == "POST" { 405 } else { 404 };
                }
            } else {
                status = 404;
            }
        } else {
            status = 404;
        }
    };
    if failed.len > 0 {
        for e in failed { write_stderr(str("database error ", e.code, ": ", e.message, "\n")); }
        http::respond(out, 500, "text/plain", "Database error");
    } else if posted && status == 404 {
        campfire::room_not_found(db, user, req, page_keys, out);
    } else if status != 200 {
        http::respond(out, status, "text/plain", if status == 404 { "Not found" } else { "Bad request" });
    } else {
        // A video or audio file is processed before the answer and the broadcast, which a media
        // thread then makes; with its queue full, they go at once.
        let deferred = campfire::take_deferred_post();
        if posted && deferred.message > 0 && campfire::process_posted_later(deferred, campfire::POSTED_STREAM,
                http::later(out, campfire::MEDIA_POST_WAIT_MS), http::coding_for(req, http::Compression { .. }), "") {
        } else if posted {
            if deferred.message > 0 && deferred.direct {
                let mentions: i64[>..] = []; campfire::deliver_webhooks_later(writer, deferred.room, deferred.creator, deferred.message, true, mentions);
            }
            http::respond_compressed(out, req, 200, "text/vnd.turbo-stream.html; charset=utf-8", html);
            let tail = path[7..]; let slash = find(tail,"/");
            let room, valid = parse_int(tail[..slash]);
            campfire::publish(room, http::later(out,60000), html, posted_ms);
        } else if stream_response {
            http::respond_compressed(out,req,200,"text/vnd.turbo-stream.html; charset=utf-8",html);
        } else {
            campfire::cache_page(entries, bytes, state, user, req, html, out);
        }
    }
}

// Session#resume for the session authenticate found due, outside any read snapshot (a GET's is
// rolled back).
fn resume_due_session(db: sqlite::Db, req: const http::Request&, out: http::Reply, state: campfire::CacheState&) {
    guard state.resume_session > 0 else { return; }
    let session = state.resume_session;
    state.resume_session = 0;
    let failed = sqlite::run() { campfire::resume_session(db, req, out, session); };
    for e in failed { write_stderr(str("session resume failed: ", e.message, "\n")); }
}

// A request, with what Rails adds to every response: ActionDispatch::SSL's redirect, HSTS and secure
// cookies, and the version headers of an ApplicationController's.
fn request(db: sqlite::Db, writer: const campfire::WriterStatements&, version: sqlite::Stmt, entries: campfire::CachedPage[:], bytes: u8[>..]&, state: campfire::CacheState&,
           req: const http::Request&, body: const u8[:], out: http::Reply) {
    let mark = out.buf.len;
    if campfire::force_ssl_redirect(req, out) { return; }
    let common = campfire::response_common(req, out.common);
    let reply = http::Reply { buf: out.buf, common: common, keep_alive: out.keep_alive, minor: out.minor, head: out.head, stream: out.stream, fd: out.fd };
    answer(db, writer, version, entries, bytes, state, req, body, reply);
    campfire::secure_cookies(req, out, mark);
}

fn answer(db: sqlite::Db, writer: const campfire::WriterStatements&, version: sqlite::Stmt, entries: campfire::CachedPage[:], bytes: u8[>..]&, state: campfire::CacheState&,
          req: const http::Request&, body: const u8[:], out: http::Reply) {
    if !state.enabled || (req.method != "GET" && req.method != "HEAD") {
        campfire::clear_cache(state);
        handle(db, writer, entries, bytes, state, req, body, out);
        resume_due_session(db, req, out, state);
        campfire::clear_cache(state);
        return;
    }
    if state.auth_user>0 && campfire_cache_current(db.id)!=0 && !campfire::request_browser_blocked(req) {
        let raw,present=http::cookie_of(req,"session_token");
        var now: u8[>..]=[]; campfire_now(now);
        if present && raw==state.auth_cookie && now.len==24 &&
           (state.auth_expiry.len==0 || compare(now,state.auth_expiry)<0) &&
           campfire::cached_page(entries,bytes,state,state.auth_user,req,out,true) {return;}
    }
    if campfire_cache_begin(db.id)!=0 {campfire::clear_cache(state);}
    let failed = sqlite::run() {
        sqlite::exec(db, "BEGIN");
        // data_version opens the read snapshot used by authentication and rendering.
        sqlite::reset(version);
        guard sqlite::step(version) else { sqlite::fail(1, "Missing data_version"); }
        let current = sqlite::column_i64(version, 0);
        sqlite::reset(version);
        if current != state.version {
            campfire::clear_cache(state);
            state.version = current;
        }
        handle(db, writer, entries, bytes, state, req, body, out);
    };
    let rollback = sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db, "ROLLBACK"); } };
    if rollback.len > 0 {
        // A worker must not serve another request with an unreleased snapshot.
        for e in rollback { write_stderr(str("database rollback failed: ", e.message, "\n")); }
        exit(1);
    }
    resume_due_session(db, req, out, state);
    if failed.len > 0 {
        campfire::clear_cache(state);
        http::respond(out, 500, "text/plain", "Database error");
    } else {campfire_cache_confirm(db.id);}
}

// With TLS_DOMAIN the worker's port is HTTPS, each connection's certificate chosen by the lane's
// mail (front.goose); otherwise plain HTTP, as without TLS before.
fn serve_app<S,H>(cfg: http::Config, fresh: S, service: acme::Service) -> http::Error {
    if tls::ok(service.base) {
        var server = acme::tls_server(service);
        let e = if settings.epoll { http::serve_epoll(cfg,fresh,server,H) } else { http::serve(cfg,fresh,server,H) };
        acme::release(server);
        return e;
    }
    if settings.epoll {return http::serve_epoll(cfg,fresh,H);}
    return http::serve(cfg,fresh,H);
}

thread_fn worker(cfg: http::Config, service: acme::Service) {
    var db = sqlite::Db {};
    var version = sqlite::Stmt {};
    var writer=campfire::WriterStatements { .. };
    let failed = sqlite::run() {
        db = sqlite::open(settings.database, sqlite::READ_WRITE);
        sqlite::busy_timeout(db, 5000);
        sqlite::exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA journal_size_limit=67108864; PRAGMA cache_size=2000;");
        version = sqlite::prepare(db, "PRAGMA data_version");
        campfire::prepare_writer(db,writer);
        writer.sgid_key=settings.sgid_key;
        writer.push=settings.push;
        let wal=campfire::campfire_track_wal(db.id); if wal!=0 { sqlite::fail(wal,"Cannot install WAL observer"); }
    };
    if failed.len > 0 {
        for e in failed { write_stderr(str("database open failed: ", e.message, "\n")); }
        exit(1);
    }
    var entries: campfire::CachedPage[128] = [campfire::CachedPage { .. }; 128];
    var bytes: u8[>..] = [];
    var state = campfire::CacheState { enabled: settings.cache_enabled, diagnostics: settings.cache_diagnostics, .. };
    // The worker's cable connections: it matches and writes the publications the broker mails it.
    reusable[] var cable_storage: u8[>..] = [];
    var cable_conns: campfire::CableLocal[>..] = [];
    var cable_targets: i32[>..] = [];
    var cable = campfire::CableShard { window: settings.cable_window, batch: settings.cable_batch,
        pace: settings.cable_pace, pace_frames: settings.cable_pace_frames, pass: settings.cable_pass, .. };
    let e = serve_app(cfg, Exchange { .. }, service) { ev, exchange, out =>
        if ev.kind == http::WORKER {
            // Publications the broker mailed the worker: its readers enroll, and wake to write. Transient events
            // and access changes come the same way.
            if ev.tag == campfire::CABLE_PUBS { campfire::cable_receive(db,cable,cable_conns,cable_targets,cable_storage,ev.data); }
            else if ev.tag == campfire::CABLE_TRANSIENT_MAIL { campfire::cable_receive_transient(cable,cable_conns,ev.data); }
            else { campfire::cable_access(cable,cable_conns,cable_targets,cable_storage); }
            campfire::cable_pump(cable,cable_conns,cable_targets,cable_storage);
            campfire::cable_credit(cable);
        } else if ev.kind == http::REQUEST && http::path_of(ev.req.target) == "/cable" {
            campfire::clear_cache(state);
            // Access changes logged from now on may postdate what authentication reads.
            let epoch = campfire::campfire_access_epoch();
            var token: u8[>..] = [];
            exchange.user = cable_authenticate(db,ev.req,settings.cookie_key,token);
            if !campfire::cable_origin_allowed(ev.req) { http::respond(out,404,"text/plain; charset=utf-8","Page not found"); }
            else if exchange.user == 0 {
                // Action Cable's reject_unauthorized_connection: the client stops reconnecting.
                if http::ws_upgrade(ev.req,exchange.ws,out,"actioncable-v1-json") {
                    http::ws_send(out,http::WS_TEXT,campfire::cable_disconnect_message(campfire::CABLE_UNAUTHORIZED,false));
                    http::ws_fail(out,exchange.ws,http::WS_NORMAL);
                }
            } else if http::ws_upgrade(ev.req,exchange.ws,out,"actioncable-v1-json") {
                exchange.upgraded = true;
                exchange.session.clear(); exchange.session.append(token); exchange.checked_ms = campfire::campfire_clock_ms();
                http::ws_send(out,http::WS_TEXT,"{\"type\":\"welcome\"}");
                http::after_drain(out);
                exchange.cable = campfire::cable_open(cable,cable_conns,cable_targets,http::later(out,3000),http::worker_address(),exchange.user,epoch);
                exchange.cable_gen = cable_conns[exchange.cable].gen;
            }
        } else if exchange.upgraded {
            if ev.kind == http::WAKE {
                // A kick: the loop writes below.
                http::later(out,3000);
            } else if ev.kind == http::DRAINED {
                // Every drain covers the batch written before it.
                if campfire::cable_owns(cable_conns,exchange.cable,exchange.cable_gen) { cable_conns[exchange.cable].ready = true; }
                if !exchange.fragmented && exchange.commands.len>0 {
                    let end=exchange.commands.at+exchange.commands.len; var at=exchange.commands.at;
                    while at+4<=end {
                        let size=(http::gathered[at] as i64) | (http::gathered[at+1] as i64)<<8 | (http::gathered[at+2] as i64)<<16 | (http::gathered[at+3] as i64)<<24; at+=4;
                        assert(size>=0 && size<=end-at);
                        campfire::cable_message(db,exchange.user,settings.stream_key,http::gathered[at..at+size],exchange.presence,exchange.typing,
                            cable,cable_conns,cable_targets,cable_storage,exchange.cable,exchange.cable_gen,out); at+=size;
                    }
                    http::release_gather(exchange.commands);
                }
                http::later(out,3000);
            } else if ev.kind == http::TIMEOUT {
                var now: u8[>..] = []; campfire_sql_now(now);
                // A paced connection's timer is not the keepalive: publications are flowing.
                let paced = campfire::cable_owns(cable_conns,exchange.cable,exchange.cable_gen) && cable_conns[exchange.cable].paced;
                if !exchange.fragmented && !paced {http::ws_send(out,http::WS_TEXT,str("{\"type\":\"ping\",\"message\":",campfire::campfire_epoch_ms(now)/1000,"}"));}
                http::after_drain(out); http::later(out,3000);
                campfire::cable_probe(cable,cable_conns,cable_targets,cable_storage);
                campfire::cable_access(cable,cable_conns,cable_targets,cable_storage);
            } else {
                if ev.kind == http::CLOSED {
                    for room in exchange.presence {if room>0 {campfire::presence_change(db,exchange.user,room,2);}}
                    http::release_gather(exchange.commands); exchange.left = true;
                    campfire::cable_leave(cable,cable_conns,cable_targets,cable_storage,exchange.cable,exchange.cable_gen);
                }
                http::ws_read(ev,exchange.ws,out) { op,data,reply =>
                    if op == http::WS_TEXT {
                        if exchange.fragmented {
                            var admitted=true;
                            if exchange.commands.most==0 {admitted=http::gather_promise(exchange.commands,65536);}
                            var length: u8[4]=[0;4]; for i in 4 {length[i]=(data.len>>(8*i)) as! u8;}
                            if !admitted || !http::gather_piece(exchange.commands,length) || !http::gather_piece(exchange.commands,data) {http::ws_close(reply,exchange.ws,1009); http::ws_end(reply,exchange.ws);}
                        } else {
                            campfire::cable_message(db,exchange.user,settings.stream_key,data,exchange.presence,exchange.typing,
                                cable,cable_conns,cable_targets,cable_storage,exchange.cable,exchange.cable_gen,reply);
                        }
                    }
                };
                // A WebSocket close ends the exchange without CLOSED.
                if !exchange.left && exchange.ws.done {
                    for room in exchange.presence {if room>0 {campfire::presence_change(db,exchange.user,room,2);}}
                    http::release_gather(exchange.commands); exchange.left = true;
                    campfire::cable_leave(cable,cable_conns,cable_targets,cable_storage,exchange.cable,exchange.cable_gen);
                }
            }
            // ApplicationCable::Connection#check_session: a connection whose session is gone closes. It is looked up
            // on the keepalive timer, or after a drained batch while publications flow, never per delivery.
            if !exchange.left && (ev.kind == http::TIMEOUT || ev.kind == http::DRAINED) && campfire::cable_owns(cable_conns,exchange.cable,exchange.cable_gen) {
                let clock = campfire::campfire_clock_ms();
                if clock - exchange.checked_ms >= settings.cable_session_check_ms {
                    exchange.checked_ms = clock;
                    if campfire::cable_session_user(db,exchange.session) == 0 {
                        campfire::cable_revoke_connection(cable,cable_conns,cable_targets,cable_storage,exchange.cable,campfire::CABLE_UNAUTHORIZED,false);
                    }
                }
            }
            if !exchange.left && campfire::cable_owns(cable_conns,exchange.cable,exchange.cable_gen) && cable_conns[exchange.cable].revoked != 0 {
                // Revoked: Action Cable's disconnect, unless a message is part written, and the close.
                let offset = cable_conns[exchange.cable].offset; let revoked = cable_conns[exchange.cable].revoked;
                if offset == 0 { http::ws_send(out,http::WS_TEXT,campfire::cable_disconnect_message(revoked,true)); }
                http::ws_fail(out,exchange.ws,http::WS_NORMAL);
                for room in exchange.presence {if room>0 {campfire::presence_change(db,exchange.user,room,2);}}
                http::release_gather(exchange.commands); exchange.left = true;
                campfire::cable_leave(cable,cable_conns,cable_targets,cable_storage,exchange.cable,exchange.cable_gen);
            }
            if !exchange.left && campfire::cable_owns(cable_conns,exchange.cable,exchange.cable_gen) {
                campfire::cable_arrived(cable,cable_conns[exchange.cable]);
                let due = campfire::cable_service(cable,cable_conns,cable_targets,cable_storage,exchange.cable,out);
                if due > 0 { http::later(out,due); }
                exchange.fragmented = cable_conns[exchange.cable].offset != 0;
            }
            campfire::cable_pump(cable,cable_conns,cable_targets,cable_storage);
            campfire::cable_credit(cable);
        } else if ev.kind == http::WAKE && ev.tag == campfire::CABLE_ACK {
            out.buf.append(http::gathered[exchange.response.at..exchange.response.at+exchange.response.len]);
            http::release_gather(exchange.response);
            campfire::cable_command(campfire::CABLE_PUBLISH,out.stream.later);
        } else if ev.kind == http::WAKE && ev.tag == campfire::UNFURL_DONE {
            campfire::unfurl_reply(ev.data,out);
        } else if ev.kind == http::WAKE && ev.tag == campfire::MEDIA_DONE {
            // A media thread's answer for a request that waited for its variant.
            campfire::media_reply(ev.data,out);
        } else if ev.kind == http::WAKE && ev.tag == campfire::MEDIA_POSTED {
            // A post whose attachment a media thread processed: its answer waits, as any post's, for
            // the acknowledgement of the broadcast that thread makes next.
            var response: u8[>..] = [];
            let deferred = http::Reply { buf:response,common:out.common,keep_alive:out.keep_alive,
                minor:out.minor,head:out.head,stream:out.stream,fd:out.fd };
            if campfire::posted_reply(ev.data,deferred) {
                assert(http::gather_piece(exchange.response,response));
                http::later(out,60000);
            } else { out.buf.append(response); http::release_gather(exchange.response); }
        } else if ev.kind == http::MORE && exchange.file.fd >= 0 {
            if !http::send_file(out,exchange.file) { http::end(out); }
        } else if ev.kind == http::TIMEOUT {
            http::release_gather(exchange.response); http::respond(out,503,"text/plain","Delivery timed out");
        } else {
            if ev.kind == http::CLOSED { http::release_gather(exchange.response); http::close_body(exchange.file); }
            if ev.kind == http::REQUEST { exchange.limit = campfire::body_limit(ev.req,settings.upload_limit); }
            http::gather(ev,exchange.body,out,exchange.limit) { req,body,reply =>
                let path = http::path_of(req.target);
                // An unfurl waits for its thread's answer, not for a publication.
                let posting = (req.method == "POST" || req.method == "PATCH" || req.method == "PUT" || req.method == "DELETE") && path != "/unfurl_link" && path != "/unfurl_link.json";
                var admitted = true;
                if campfire::is_disk_route(req) {
                    campfire::serve_disk(req,settings.storage,settings.storage_key,reply,exchange.file); admitted = false;
                } else if posting {
                    let permit, acquired = qpoll<campfire::CablePermit>();
                    if !acquired { http::respond(reply,503,"text/plain","Live delivery is busy"); admitted = false; }
                    else if !http::gather_promise(exchange.response,1<<20) {
                        qput(campfire::CablePermit { .. }); http::respond(reply,503,"text/plain","Response storage is busy"); admitted = false;
                    }
                }
                if admitted {
                if posting {
                    var response: u8[>..] = [];
                    let deferred = http::Reply { buf:response,common:reply.common,keep_alive:reply.keep_alive,
                        minor:reply.minor,head:reply.head,stream:reply.stream,fd:reply.fd };
                    request(db,writer,version,entries,bytes,state,req,body,deferred);
                    if reply.stream.waiting {
                        assert(http::gather_piece(exchange.response,response));
                        // A post handed to a media thread: its broadcast takes a permit of its own.
                        if campfire::take_posted_media() { qput(campfire::CablePermit { .. }); }
                    } else { reply.buf.append(response); http::release_gather(exchange.response); qput(campfire::CablePermit { .. }); }
                } else { request(db,writer,version,entries,bytes,state,req,body,reply); }
                }
            };
        }
    };
    campfire::close_writer(writer);
    sqlite::finalize(version);
    sqlite::close(db);
    http::exit_on_error(e);
    http::report(e);
}

fn main() {
    var database: u8[>..] = [];
    if env("DATABASE_PATH", database) {
        guard database.len > 0 && database.len <= 1024 else { abort("DATABASE_PATH is too long or empty"); }
        settings.database = database;
    }
    var secret: u8[>..] = [];
    guard env("SECRET_KEY_BASE", secret) && secret.len >= 32 else { abort("set SECRET_KEY_BASE to the database's Rails signing secret"); }
    settings.cookie_key = campfire::signed_cookie_key(secret);
    settings.avatar_key = campfire::signed_id_key(secret);
    settings.sgid_key = campfire::sgid_key(secret);
    hash::pbkdf2_sha256(settings.storage_key, secret, "ActiveStorage", 1000);
    hash::pbkdf2_sha256(settings.stream_key, secret, "turbo/signed_stream_verifier_key", 1000);
    var vapid: u8[>..]=[]; if env("VAPID_PUBLIC_KEY",vapid) { settings.vapid=vapid; }
    var vapid_private: u8[>..]=[]; env("VAPID_PRIVATE_KEY",vapid_private);
    var push_keys=campfire::PushKeys { .. };
    let unpushed=campfire::push_keys(vapid,vapid_private,push_keys);
    settings.push=push_keys.push;
    let push_status: u8[>..] = if settings.push { "Web Push: on\n" } else { str("Web Push: off, since ",unpushed,"\n") };
    write_stderr(push_status);
    // TEST ONLY: connect every push delivery to this address once the guard has admitted the
    // endpoint's (test_push.py); with CAMPFIRE_PUSH_TEST_RESOLVE (push_crypto.c), never in production.
    var test_connect: u8[>..]=[];
    if env("CAMPFIRE_PUSH_TEST_CONNECT",test_connect) && test_connect.len>0 {
        guard test_connect.len<256 else { abort("CAMPFIRE_PUSH_TEST_CONNECT is too long"); }
        push_keys.test_connect=test_connect;
        write_stderr(str("TEST ONLY: Web Push deliveries connect to ",test_connect,"\n"));
    }
    var test_resolve: u8[>..]=[];
    if env("CAMPFIRE_PUSH_TEST_RESOLVE",test_resolve) && test_resolve.len>0 { write_stderr(str("TEST ONLY: Web Push resolves ",test_resolve,"\n")); }
    var storage: u8[>..] = [];
    if env("STORAGE_PATH", storage) {
        guard storage.len > 0 && storage.len <= 1024 else { abort("STORAGE_PATH is too long or empty"); }
        settings.storage = storage;
    }
    // config/environments/production.rb: assume_ssl and force_ssl unless DISABLE_SSL is present.
    var disable_ssl: u8[>..] = [];
    // Thruster's settings: the ports, TLS_DOMAIN and FORWARD_HEADERS (front.goose).
    let front = campfire::front_config();
    let tls_on = front.domains.len > 0;
    campfire::configure_scheme(env("DISABLE_SSL", disable_ssl) && trim(disable_ssl).len > 0, tls_on, front.forward_headers);
    campfire::configure_auth(secret, settings.cookie_key, settings.avatar_key, settings.vapid, settings.storage);
    var cache_text: u8[>..] = [];
    if env("CAMPFIRE_CACHE", cache_text) { settings.cache_enabled = cache_text != "0"; }
    var diagnostics: u8[>..] = [];
    if env("CAMPFIRE_CACHE_DIAGNOSTICS", diagnostics) { settings.cache_diagnostics = diagnostics == "1"; }
    var backend: u8[>..]=[];
    if env("CAMPFIRE_HTTP_BACKEND",backend) {
        guard backend=="epoll" || backend=="auto" || backend=="uring" || backend=="emulated"
            else {abort("CAMPFIRE_HTTP_BACKEND must be epoll, auto, uring or emulated");}
        settings.epoll=backend=="epoll" || backend=="auto" && http::ring_probe()!=0;
    }
    var profiling: u8[>..]=[];
    campfire_profile_enable(env("CAMPFIRE_PROFILE_WRITES",profiling) && profiling=="1");
    var publication_ack: u8[>..]=[];
    if env("CAMPFIRE_PUBLICATION_ACK",publication_ack) {
        guard publication_ack=="drained" || publication_ack=="queued"
            else {abort("CAMPFIRE_PUBLICATION_ACK must be drained or queued");}
    }
    let queued_ack = publication_ack!="drained";
    var publication_window: i64 = campfire::CABLE_WINDOW;
    var window_text: u8[>..]=[];
    if env("CAMPFIRE_PUBLICATION_WINDOW",window_text) {
        let size, ok = parse_int(window_text);
        guard ok && size>=8 && size<=512 && (size & (size-1))==0
            else {abort("CAMPFIRE_PUBLICATION_WINDOW must be a power of two from 8 through 512");}
        guard queued_ack || size==8 else {abort("larger publication windows require queued acknowledgements");}
        publication_window=size;
    }
    let delivery_permits=publication_window+56;
    settings.cable_window=publication_window;
    write_stderr(str("Publication acknowledgement: ",if queued_ack {"queued"} else {"drained"},"\n"));
    var batch_text: u8[>..]=[];
    if env("CAMPFIRE_CABLE_BATCH",batch_text) {
        let size, ok = parse_int(batch_text);
        guard ok && size>=16384 && size<=1048576 && (size & (size-1))==0
            else {abort("CAMPFIRE_CABLE_BATCH must be a power of two from 16384 through 1048576");}
        settings.cable_batch=size;
    } else { settings.cable_batch=campfire::CABLE_BATCH; }
    // Experimental: pace each cable connection's writes under load (fanout-pace).
    var pace_text: u8[>..]=[];
    if env("CAMPFIRE_CABLE_PACE_MS",pace_text) {
        let ms, ok = parse_int(pace_text);
        guard ok && ms>=0 && ms<=1000 else {abort("CAMPFIRE_CABLE_PACE_MS must be from 0 through 1000");}
        settings.cable_pace=ms;
    }
    var pace_frames_text: u8[>..]=[];
    if env("CAMPFIRE_CABLE_PACE_FRAMES",pace_frames_text) {
        let n, ok = parse_int(pace_frames_text);
        guard ok && n>=1 && n<=512 else {abort("CAMPFIRE_CABLE_PACE_FRAMES must be from 1 through 512");}
        settings.cable_pace_frames=n;
    }
    write_stderr(str("Publication window: ",publication_window,"; delivery permits: ",delivery_permits,"\n"));
    // Wake at most this many cable connections per pass of a worker's loop; 0 wakes every ready one.
    var pass_text: u8[>..]=[];
    if env("CAMPFIRE_CABLE_PASS_READERS",pass_text) {
        let n, ok = parse_int(pass_text);
        guard ok && n>=0 && n<=65536 else {abort("CAMPFIRE_CABLE_PASS_READERS must be from 0 through 65536");}
        settings.cable_pass=n;
    } else { settings.cable_pass=campfire::CABLE_PASS; }
    var check_text: u8[>..]=[];
    if env("CAMPFIRE_CABLE_SESSION_CHECK_MS",check_text) {
        let ms, ok = parse_int(check_text);
        guard ok && ms>=100 && ms<=3600000 else {abort("CAMPFIRE_CABLE_SESSION_CHECK_MS must be from 100 through 3600000");}
        settings.cable_session_check_ms=ms;
    }
    write_stderr(str("Cable batch: ",settings.cable_batch,"; pass readers: ",settings.cable_pass,"; pace: ",settings.cable_pace," ms, ",settings.cable_pace_frames," frames\n"));
    // Uploads (a message's attachment, an avatar, the logo) may be this large; every other body 1 MiB.
    var upload_text: u8[>..]=[];
    if env("CAMPFIRE_UPLOAD_MAX_BYTES",upload_text) {
        let n, ok = parse_int(upload_text);
        guard ok && n>=(1<<20) && n<=(1<<30) else {abort("CAMPFIRE_UPLOAD_MAX_BYTES must be from 1048576 through 1073741824");}
        settings.upload_limit=n;
    }
    var cfg = http::Config { address: "0.0.0.0", port: 3000, workers: 4, max_conns: 1024,
        mail_size:campfire::CABLE_MAIL as i32,max_waiting:1024,.. };
    cfg.max_body=settings.upload_limit;
    // A worker gathers whole bodies: room for two uploads at once beside its responses.
    http::gather_budget(max(64 << 20, 2*settings.upload_limit + (16 << 20)));
    cfg.emulate_ring=backend=="emulated";
    cfg.require_ring=!settings.epoll && !cfg.emulate_ring;
    write_stderr(str("HTTP backend: ", if settings.epoll {"epoll"} else if cfg.emulate_ring {"emulated"} else {"io_uring"}, "\n"));
    cfg.port = (if tls_on { front.https_port } else { front.http_port }) as i32;
    cfg.tls = tls_on;
    var workers_text: u8[>..] = [];
    if env("CAMPFIRE_HTTP_THREADS", workers_text) {
        let workers, ok = parse_int(workers_text);
        guard ok && workers > 0 && workers <= 256 else { abort("invalid CAMPFIRE_HTTP_THREADS"); }
        cfg.workers = workers;
    }
    var conns_text: u8[>..] = [];
    // Each worker's connections, and as many waiting cable exchanges.
    if env("CAMPFIRE_HTTP_MAX_CONNS", conns_text) {
        let conns, ok = parse_int(conns_text);
        guard ok && conns >= 64 && conns <= 65536 else { abort("invalid CAMPFIRE_HTTP_MAX_CONNS"); }
        cfg.max_conns = conns; cfg.max_waiting = conns;
    }
    // A box takes the publication mails and the acknowledgements outstanding; kicks take no slot.
    var slots: i64 = 2;
    while slots < 4*publication_window + 256 { slots *= 2; }
    cfg.mail_slots = slots as i32;
    campfire::initialize_database(settings.database);
    qlimit<campfire::Publication>(delivery_permits); qlimit<campfire::CablePermit>(delivery_permits); qlimit<campfire::CableCommand>(65536);
    // Typing and read notices wait in a queue of their own, which drops them when full.
    qlimit<campfire::CableTransientEvent>(256);
    for i in delivery_permits { qput(campfire::CablePermit { .. }); }
    thread_spawn(campfire::cable_broker,queued_ack,publication_window);
    // Bot webhooks and Web Push: a bounded queue, and delivery threads that never hold an HTTP worker.
    // CAMPFIRE_WEBHOOK_THREADS is the setting's earlier name.
    var delivery_threads: i64 = 4;
    var delivery_text: u8[>..]=[];
    if env("CAMPFIRE_DELIVERY_THREADS",delivery_text) || env("CAMPFIRE_WEBHOOK_THREADS",delivery_text) {
        let n, ok = parse_int(delivery_text);
        guard ok && n>=1 && n<=64 else {abort("CAMPFIRE_DELIVERY_THREADS must be from 1 through 64");}
        delivery_threads=n;
    }
    qlimit<campfire::DeliveryJob>(campfire::DELIVERY_QUEUE);
    let webhook_keys=campfire::WebhookKeys { avatar: settings.avatar_key, storage: settings.storage_key, sgid: settings.sgid_key, push: push_keys, files: settings.storage };
    for _ in delivery_threads { thread_spawn(campfire::webhook_supervisor,copy(settings.database),webhook_keys); }
    // Image and video processing: media threads that run no event loop make variants, as Rails'
    // image_processing does, and run ffprobe and ffmpeg. Whether ffmpeg is installed (which makes
    // videos previewable) is asked once, now, rather than by the first page that shows a video.
    write_stderr(if campfire_ffmpeg_exists() { "Video previews: on\n" } else { "Video previews: off, since ffmpeg isn't installed\n" });
    var media_text: u8[>..]=[];
    if env("CAMPFIRE_MEDIA_THREADS",media_text) {
        let n, ok = parse_int(media_text);
        guard ok && n>=1 && n<=64 else {abort("CAMPFIRE_MEDIA_THREADS must be from 1 through 64");}
        settings.media_threads=n;
    }
    qlimit<campfire::MediaJob>(campfire::MEDIA_QUEUE);
    var media_settings=campfire::MediaSettings { .. };
    media_settings.storage=settings.storage; media_settings.key=settings.storage_key; media_settings.avatar_key=settings.avatar_key;
    for _ in settings.media_threads { thread_spawn(campfire::media_supervisor,copy(settings.database),media_settings); }
    // Link previews: unfurl threads fetch pages, so no HTTP worker waits on another server.
    qlimit<campfire::UnfurlJob>(campfire::UNFURL_QUEUE);
    var unfurl_settings=campfire::UnfurlSettings { .. };
    // TEST ONLY: where every unfurl connects once the guard has admitted its address (test_ui_messages.py).
    var unfurl_connect: u8[>..]=[];
    if env("CAMPFIRE_UNFURL_TEST_CONNECT",unfurl_connect) && unfurl_connect.len>0 {
        guard unfurl_connect.len<256 else { abort("CAMPFIRE_UNFURL_TEST_CONNECT is too long"); }
        unfurl_settings.test_connect.append(unfurl_connect);
    }
    for _ in 4 { thread_spawn(campfire::unfurl_worker,unfurl_settings); }
    qlimit<campfire::CheckpointJob>(1);
    let checkpointer=thread_spawn(campfire::checkpointer,copy(settings.database));
    var service = acme::Service { .. };
    if tls_on {
        service = campfire::front_service(front, http::worker_count(cfg));
        thread_spawn(campfire::front_http, http::Config { address: "0.0.0.0", port: front.http_port as i32, workers: 1, .. }, front.domains);
        write_stderr(str("TLS: HTTPS on port ", front.https_port, ", and HTTP on port ", front.http_port, " redirects to it\n"));
    }
    http::run(cfg, service, worker);
    while !qput(campfire::CheckpointJob { stop:true }) { sleep_ms(1); }
    thread_wait(checkpointer);
}
