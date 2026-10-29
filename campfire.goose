import std;
import database;
import setup;
import cable;
import message_actions;
import browser_routes;
import os;
import http from "github.com/kaitk/goose-http@c58a340abe8ed3933806b87752eb5c9e43cd389a";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import compress from "github.com/kaitk/goose-compress@v0.1.4";
import sqlite from "./build/sqlite";
import http.compression;
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

struct Settings {
    database: u8[..1024] = "campfire.sqlite3",
    cookie_key: u8[64] = [0; 64],
    storage_key: u8[64] = [0;64],
    stream_key: u8[64] = [0;64],
    vapid: u8[..256] = [],
    avatar_key: u8[64] = [0; 64],
    storage: u8[..1024] = "storage",
    cache_enabled: bool = true,
    cache_diagnostics: bool = false,
    epoll: bool = true,
    cable_window: i64 = 8,
    cable_batch: i64 = 262144,
    cable_pace: i64 = 0,
    cable_pace_frames: i64 = 16,
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
}

extern fn campfire_now(out: u8[>..]&);
extern fn campfire_sql_now(out: u8[>..]&);
extern fn campfire_profile_enable(enabled: bool);
extern fn campfire_cache_begin(handle: i64) -> i32;
extern fn campfire_cache_confirm(handle: i64);
extern fn campfire_cache_current(handle: i64) -> i32;

fn authenticate(db: sqlite::Db, req: const http::Request&, key: const u8[:], state: campfire::CacheState&) -> i64 {
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
    let failed = sqlite::run() {
        q = sqlite::prepare(db, "SELECT u.id FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token=? AND u.status=0");
        sqlite::bind_text(q, 1, token);
        if sqlite::step(q) { user = sqlite::column_i64(q, 0); }
    };
    sqlite::finalize(q);
    // Both the session row and the signed-cookie expiry must still be valid.
    if state.enabled && failed.len == 0 && user > 0 {
        state.auth_cookie = raw;
        state.auth_expiry = valid_until;
        state.auth_user = user;
    }
    return if failed.len == 0 { user } else { 0 };
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
    if campfire::setup_route(db, req, body, settings.cookie_key, out) { return; }
    if campfire::transfer_route(db,req,settings.avatar_key,settings.cookie_key,out) { return; }
    if campfire::bot_message(db,writer,req,body,settings.avatar_key,settings.storage_key,out) { return; }
    if path == "/session/new" && req.method == "GET" {
        http::respond(out, 200, "text/html; charset=utf-8", "<!DOCTYPE html><html><head><title>Campfire</title></head><body><h1>Sign in to Campfire</h1><form action=\"/session\" method=\"post\"><label>Email <input type=\"email\" name=\"email_address\" required></label><label>Password <input type=\"password\" name=\"password\" required></label><button>Sign in</button></form></body></html>");
        return;
    }
    if path == "/session" && req.method == "POST" {
        campfire::login(db, req, body, settings.cookie_key, out);
        return;
    }
    let user = authenticate(db, req, settings.cookie_key, state);
    if user == 0 {
        http::start(out, 302);
        http::field(out, "Location", "/session/new");
        http::finish(out, http::TEXT, "Authentication required");
        return;
    }
    if path == "/" && req.method == "GET" {
        var q = sqlite::Stmt {};
        var destination: u8[>..] = [];
        let failed = sqlite::run() {
            q = sqlite::prepare(db, "SELECT room_id FROM memberships WHERE user_id=? ORDER BY room_id LIMIT 1");
            sqlite::bind_i64(q, 1, user);
            if sqlite::step(q) { format(destination, "/rooms/", sqlite::column_i64(q, 0)); }
        };
        sqlite::finalize(q);
        if failed.len == 0 && destination.len > 0 {
            http::start(out, 302);
            http::field(out, "Location", destination);
            http::finish(out, http::TEXT, "Redirecting");
        } else { http::respond(out, 404, "text/plain", "No rooms"); }
        return;
    }
    if campfire::message_actions(db,user,req,body,settings.storage_key,settings.avatar_key,out) { return; }
    if campfire::browser_route(db,user,req,body,settings.avatar_key,out) { return; }
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
    var posted = false;
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
        } else if path == "/searches" {
            var search: u8[>..] = [];
            let raw, has_query = http::query_of(req.target, "q");
            if has_query && http::decode(raw, search, true) {
                campfire::search(db, user, search, settings.avatar_key, ctx, view_bytes, req, html);
            } else {
                status = 400;
            }
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
                    status = campfire::post_message(db, writer, req, body, user, room, now, settings.avatar_key, ctx, view_bytes, context_start, html);
                    posted = true;
                } else if req.method == "POST" {
                    status = 405;
                } else {
                    let before, has_before = http::query_int(req.target, "before");
                    status = campfire::room(db, user, room, if has_before { before } else { 0 }, messages, settings.avatar_key, ctx, view_bytes, settings.stream_key, html);
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
    } else if status != 200 {
        http::respond(out, status, "text/plain", if status == 404 { "Not found" } else { "Bad request" });
    } else {
        if posted {
            http::respond_compressed(out, req, 200, "text/vnd.turbo-stream.html; charset=utf-8", html);
            let tail = path[7..]; let slash = find(tail,"/");
            let room, valid = parse_int(tail[..slash]);
            campfire::publish(room, http::later(out,60000), html);
        } else if stream_response {
            http::respond_compressed(out,req,200,"text/vnd.turbo-stream.html; charset=utf-8",html);
        } else {
            campfire::cache_page(entries, bytes, state, user, req, html, out);
        }
    }
}

fn request(db: sqlite::Db, writer: const campfire::WriterStatements&, version: sqlite::Stmt, entries: campfire::CachedPage[:], bytes: u8[>..]&, state: campfire::CacheState&,
           req: const http::Request&, body: const u8[:], out: http::Reply) {
    if !state.enabled || (req.method != "GET" && req.method != "HEAD") {
        campfire::clear_cache(state);
        handle(db, writer, entries, bytes, state, req, body, out);
        campfire::clear_cache(state);
        return;
    }
    if state.auth_user>0 && campfire_cache_current(db.id)!=0 {
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
    if failed.len > 0 {
        campfire::clear_cache(state);
        http::respond(out, 500, "text/plain", "Database error");
    } else {campfire_cache_confirm(db.id);}
}

fn serve_app<S,H>(cfg: http::Config, fresh: S) -> http::Error {
    if settings.epoll {return http::serve_epoll(cfg,fresh,H);}
    return http::serve(cfg,fresh,H);
}

thread_fn worker(cfg: http::Config) {
    var db = sqlite::Db {};
    var version = sqlite::Stmt {};
    var writer=campfire::WriterStatements { .. };
    let failed = sqlite::run() {
        db = sqlite::open(settings.database, sqlite::READ_WRITE);
        sqlite::busy_timeout(db, 5000);
        sqlite::exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA journal_size_limit=67108864; PRAGMA cache_size=2000;");
        version = sqlite::prepare(db, "PRAGMA data_version");
        campfire::prepare_writer(db,writer);
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
    var cable = campfire::CableShard { window: settings.cable_window, batch: settings.cable_batch, pace: settings.cable_pace, pace_frames: settings.cable_pace_frames, .. };
    let e = serve_app(cfg, Exchange { .. }) { ev, exchange, out =>
        if ev.kind == http::WORKER {
            // Publications the broker mailed the worker: its readers enroll, and wake to write.
            campfire::cable_receive(cable,cable_conns,cable_targets,ev.data);
            campfire::cable_pump(cable,cable_conns,cable_targets,cable_storage);
            campfire::cable_credit(cable);
        } else if ev.kind == http::REQUEST && http::path_of(ev.req.target) == "/cable" {
            campfire::clear_cache(state);
            exchange.user = authenticate(db,ev.req,settings.cookie_key,state);
            if exchange.user == 0 || !campfire::same_origin(ev.req) { http::respond(out,403,"text/plain","Forbidden"); }
            else if http::ws_upgrade(ev.req,exchange.ws,out,"actioncable-v1-json") {
                exchange.upgraded = true;
                http::ws_send(out,http::WS_TEXT,"{\"type\":\"welcome\"}");
                http::after_drain(out);
                exchange.cable = campfire::cable_open(cable,cable_conns,cable_targets,http::later(out,3000),http::worker_address(cfg,out),exchange.user);
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
                        campfire::cable_message(db,exchange.user,settings.stream_key,http::gathered[at..at+size],exchange.presence,
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
                            campfire::cable_message(db,exchange.user,settings.stream_key,data,exchange.presence,
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
            if !exchange.left && campfire::cable_owns(cable_conns,exchange.cable,exchange.cable_gen) {
                cable_conns[exchange.cable].kicked = false;
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
        } else if ev.kind == http::TIMEOUT {
            http::release_gather(exchange.response); http::respond(out,503,"text/plain","Delivery timed out");
        } else {
            if ev.kind == http::CLOSED { http::release_gather(exchange.response); }
            http::gather(ev,exchange.body,out,1<<20) { req,body,reply =>
                let path = http::path_of(req.target);
                let posting = req.method == "POST" || req.method == "PATCH" || req.method == "DELETE";
                var admitted = true;
                if posting {
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
    hash::pbkdf2_sha256(settings.storage_key, secret, "ActiveStorage", 1000);
    hash::pbkdf2_sha256(settings.stream_key, secret, "turbo/signed_stream_verifier_key", 1000);
    var vapid: u8[>..]=[]; if env("VAPID_PUBLIC_KEY",vapid) { settings.vapid=vapid; }
    var storage: u8[>..] = [];
    if env("STORAGE_PATH", storage) {
        guard storage.len > 0 && storage.len <= 1024 else { abort("STORAGE_PATH is too long or empty"); }
        settings.storage = storage;
    }
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
    let queued_ack = publication_ack=="queued";
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
    // Experimental: each loop pass serves requests, and so posts and their acknowledgements, before cable writes.
    var first_text: u8[>..]=[];
    let requests_first=env("CAMPFIRE_REQUESTS_FIRST",first_text) && first_text=="1";
    write_stderr(str("Cable batch: ",settings.cable_batch,"; pace: ",settings.cable_pace," ms, ",settings.cable_pace_frames," frames\n"));
    write_stderr(str("Requests first: ",if requests_first {"on"} else {"off"},"\n"));
    var cfg = http::Config { address: "0.0.0.0", port: 3000, workers: 4, max_conns: 1024,
        mail_size:campfire::CABLE_MAIL as i32,max_waiting:1024,.. };
    cfg.requests_first=requests_first;
    cfg.emulate_ring=backend=="emulated";
    cfg.require_ring=!settings.epoll && !cfg.emulate_ring;
    write_stderr(str("HTTP backend: ", if settings.epoll {"epoll"} else if cfg.emulate_ring {"emulated"} else {"io_uring"}, "\n"));
    var port_text: u8[>..] = [];
    if env("HTTP_PORT", port_text) || env("PORT", port_text) {
        let port, ok = parse_int(port_text);
        guard ok && port > 0 && port < 65536 else { abort("invalid HTTP_PORT or PORT"); }
        cfg.port = port as i32;
    }
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
    for i in delivery_permits { qput(campfire::CablePermit { .. }); }
    thread_spawn(campfire::cable_broker,queued_ack,publication_window);
    qlimit<campfire::CheckpointJob>(1);
    let checkpointer=thread_spawn(campfire::checkpointer,copy(settings.database));
    http::run(cfg, worker);
    while !qput(campfire::CheckpointJob { stop:true }) { sleep_ms(1); }
    thread_wait(checkpointer);
}
