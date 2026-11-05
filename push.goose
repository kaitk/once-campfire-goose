// Web Push, after the Rails reference at 90b33002: Room::PushMessageJob and Room::MessagePusher
// choose whom a new message notifies and what it says, WebPush::Pool delivers each notification
// on its own, and WebPush::Notification sends it with the web-push gem (3.1.0): RFC 8291 payload
// encryption and an RFC 8292 VAPID signature (push_crypto.c), at an address the private network
// guard admitted. A message's job and each notification are DeliveryJobs (messages.goose) that the
// delivery threads take (webhooks.goose), so no HTTP worker waits for any of it.
namespace campfire;

import std;
import sqlite;
import http;
import http.client;
import database;
import messages;
import signed_id;
import admin_routes;
import webhooks;
import storage;
import rich_html;
import html;
import shutdown;

extern fn campfire_push_encrypt(p256dh: const u8[:], auth: const u8[:], plaintext: const u8[:],
                                salt: const u8[:], sender: const u8[:], out: u8[>..]&) -> i32;
extern fn campfire_vapid_check(public_key: const u8[:], private_key: const u8[:]) -> i32;
extern fn campfire_vapid_sign(public_key: const u8[:], private_key: const u8[:], data: const u8[:], out: u8[>..]&) -> bool;
extern fn campfire_unix_seconds() -> i64;
extern fn campfire_push_resolve(host: const u8[:], out: u8[>..]&, ms: i64) -> i32;
extern fn campfire_push_dropped() -> i64;

// WebPush::Request#default_options[:ttl], four weeks, and the urgency WebPush::Notification asks.
let PUSH_TTL = "2419200";
let PUSH_URGENCY = "high";
// WebPush::Notification#vapid_identification's subject, and the gem's default JWT lifetime.
let PUSH_SUBJECT = "mailto:support@37signals.com";
let PUSH_EXPIRATION: i64 = 43200;
// Each wait of a delivery: the connect, a send, a read. Net::HTTP would wait 60 seconds for each.
let PUSH_TIMEOUT_MS: i64 = 10000;
let PUSH_MAX_BODY: i64 = 65536;
// campfire_push_encrypt's results.
let PUSH_INVALID_KEY: i32 = 1;
let PUSH_TOO_BIG: i32 = 2;

// The VAPID key pair, decoded, for the delivery threads; push is false without a valid one.
struct PushKeys {
    push: bool = false,
    public_key: u8[65] = [0; 65],
    private_key: u8[..32] = [],
    // TEST ONLY (CAMPFIRE_PUSH_TEST_CONNECT): where to connect once the guard admitted an address.
    test_connect: u8[..256] = [],
}

// A delivery thread's push statements, and the subscriptions whose refusal it logged lately.
struct PushState {
    recipients: sqlite::Stmt = sqlite::Stmt {},
    badge: sqlite::Stmt = sqlite::Stmt {},
    refused: i64[64] = [0; 64],
    next_refused: i64 = 0,
}

// VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY, URL-safe Base64 as WebPush.generate_key writes them, into
// keys; "" when they make a key pair, or why they don't.
fn push_keys(public_text: const u8[:], private_text: const u8[:], keys: PushKeys&) -> u8[>..] {
    guard public_text.len > 0 && private_text.len > 0 else { return str("VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY are not both set"); }
    var public_key: u8[>..] = []; var private_key: u8[>..] = [];
    guard base64_url_decode(public_key, public_text) && public_key.len == 65 else { return str("VAPID_PUBLIC_KEY is not a Base64 P-256 public key"); }
    guard base64_url_decode(private_key, private_text) && private_key.len >= 1 && private_key.len <= 32 else { return str("VAPID_PRIVATE_KEY is not a Base64 P-256 private key"); }
    let checked = campfire_vapid_check(public_key, private_key);
    guard checked != 1 else { return str("VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY are not a P-256 key pair"); }
    guard checked != 2 else { return str("VAPID_PUBLIC_KEY is not VAPID_PRIVATE_KEY's public key"); }
    for b, i in public_key { keys.public_key[i] = b; }
    keys.private_key = private_key;
    keys.push = true;
    return [];
}

fn prepare_push(db: sqlite::Db, state: PushState&) {
    // Room::MessagePusher#relevant_subscriptions: the subscriptions of the room's visible,
    // disconnected members but the creator, those involved in everything first, then those
    // involved in mentions (each in id order, as find_each takes them). Only active users: banning
    // keeps a user's subscriptions, but nobody who can't sign in is sent what's said meanwhile.
    state.recipients = sqlite::prepare(db, "SELECT s.id,s.endpoint,m.involvement='mentions',s.user_id FROM memberships m JOIN users u ON u.id=m.user_id AND u.status=0 JOIN push_subscriptions s ON s.user_id=m.user_id WHERE m.room_id=?1 AND m.user_id<>?2 AND m.involvement IN ('everything','mentions') AND (m.connected_at IS NULL OR m.connected_at<?3) ORDER BY m.involvement='mentions',s.id");
    // Push::Subscription#notification's badge: user.memberships.unread.count.
    state.badge = sqlite::prepare(db, "SELECT count(*) FROM memberships WHERE user_id=? AND unread_at IS NOT NULL");
}

// Room#push_later, after the message's commit: one job, whatever the room's size. A full queue
// skips the message's notifications, logged sparsely.
fn push_later(message: i64, room: i64, creator: i64) {
    if !queue_job(JOBS_DELIVERY, DeliveryJob { kind: PUSH_MESSAGE, a: message, b: room, c: creator }) { push_dropped(str("message ",message)); }
}

fn push_dropped(what: const u8[:]) {
    let n = campfire_push_dropped();
    if (n & (n - 1)) == 0 { write_stderr(str("Web Push queue is full: ",what," skipped (",n," skipped so far)\n")); }
}

// Logs once in a while that a subscription is refused, as Rails doesn't: it skips them in silence.
fn push_refused(state: PushState&, subscription: i64, why: const u8[:]) {
    for id in state.refused { if id == subscription { return; } }
    state.refused[state.next_refused % 64] = subscription; state.next_refused += 1;
    write_stderr(str("Web Push to subscription ",subscription," skipped: ",why,"\n"));
}

struct PushRecipient { subscription: i64 = 0, user: i64 = 0, mentions: bool = false }

// Room::PushMessageJob#perform: Room::MessagePusher#push, then WebPush::Pool#queue for each
// subscription it finds. Endpoints that aren't a permitted push service are refused here, before
// the message is read, as Push::Subscription#resolved_endpoint_ip would refuse them.
fn push_message(db: sqlite::Db, state: PushState&, job: const DeliveryJob&, sgid_key: const u8[:]) {
    var cutoff: u8[>..] = []; campfire_disconnected_before(cutoff);
    var recipients: PushRecipient[>..] = [];
    let q = state.recipients;
    let failed = sqlite::run() {
        sqlite::reset(q);
        sqlite::bind_i64(q,1,job.b); sqlite::bind_i64(q,2,job.c); sqlite::bind_text(q,3,cutoff);
        while sqlite::step(q) {
            let id = sqlite::column_i64(q,0);
            var endpoint: u8[>..] = []; sqlite::column_text(q,1,endpoint);
            if !push_endpoint_valid(endpoint) { push_refused(state,id,"its endpoint is not a permitted push service"); continue; }
            let mentions = sqlite::column_i64(q,2) == 1;
            recipients.push(PushRecipient { subscription: id, user: sqlite::column_i64(q,3), mentions: mentions });
        }
    };
    sqlite::reset(q);
    for e in failed { write_stderr(str("Web Push for message ",job.a," failed: ",e.message,"\n")); return; }
    guard recipients.len > 0 else { return; }

    var found = false; var direct = false;
    var room_name: u8[>..] = []; var room_named = false; var creator_name: u8[>..] = [];
    var body: u8[>..] = []; var filename: u8[>..] = [];
    var m = sqlite::Stmt {};
    let read = sqlite::run() {
        m = sqlite::prepare(db,"SELECT r.type,r.name,c.name,t.body,b.filename FROM messages m JOIN rooms r ON r.id=m.room_id JOIN users c ON c.id=m.creator_id LEFT JOIN action_text_rich_texts t ON t.record_type='Message' AND t.record_id=m.id AND t.name='body' LEFT JOIN active_storage_attachments a ON a.record_type='Message' AND a.name='attachment' AND a.record_id=m.id LEFT JOIN active_storage_blobs b ON b.id=a.blob_id WHERE m.id=? ORDER BY a.id LIMIT 1");
        sqlite::bind_i64(m,1,job.a);
        if sqlite::step(m) {
            var kind: u8[>..] = []; sqlite::column_text(m,0,kind); direct = kind == "Rooms::Direct";
            room_named = !sqlite::is_null(m,1); sqlite::column_text(m,1,room_name);
            sqlite::column_text(m,2,creator_name); sqlite::column_text(m,3,body); sqlite::column_text(m,4,filename);
            found = true;
        }
    };
    sqlite::finalize(m);
    for e in read { write_stderr(str("Web Push for message ",job.a," failed: ",e.message,"\n")); return; }
    guard found else { return; }

    // Message#plain_text_body (the rich text, else the attachment's filename) and Message#mentionees.
    var mentioned: i64[>..] = [];
    let plain = if find(body,"<action-text-attachment") >= 0 { mention_plain(db,body,sgid_key,mentioned) } else { rich_plain(body) };
    var text: u8[>..] = [];
    if trim_unicode(plain).len > 0 { text.append(plain); } else if filename.len > 0 { text = sanitized_filename(filename); }
    // build_direct_payload or build_shared_payload, and Notification#encoded_message without the badge.
    var head: u8[>..] = str("{\"title\":");
    if direct { json_generate(head,creator_name); } else if room_named { json_generate(head,room_name); } else { head.append("null"); }
    head.append(",\"options\":{\"body\":");
    if direct { json_generate(head,text); } else { json_generate(head,str(creator_name,": ",text)); }
    format(head,",\"icon\":\"/account/logo\",\"data\":{\"path\":\"/rooms/",job.b,"\",\"badge\":");

    for r in recipients {
        if r.mentions {
            var named = false; for id in mentioned { if id == r.user { named = true; } }
            if !named { continue; }
        }
        let badge = push_badge(state,r.user);
        guard badge >= 0 else { continue; }
        if !queue_job(JOBS_DELIVERY, DeliveryJob { kind: PUSH_NOTIFY, a: r.subscription, text: str(head,badge,"}}}") }) {
            push_dropped(str("subscription ",r.subscription,", message ",job.a));
        }
    }
}

fn push_badge(state: PushState&, user: i64) -> i64 {
    var badge: i64 = -1;
    let q = state.badge;
    let failed = sqlite::run() {
        sqlite::reset(q); sqlite::bind_i64(q,1,user);
        if sqlite::step(q) { badge = sqlite::column_i64(q,0); }
    };
    sqlite::reset(q);
    for e in failed { write_stderr(str("Web Push badge for user ",user," failed: ",e.message,"\n")); }
    return badge;
}

// Users::PushSubscriptions::TestNotificationsController#create: "Campfire Test", a random body, and
// user_push_subscriptions_url, from base, the request's scheme and host.
fn push_test(db: sqlite::Db, state: PushState&, session: http::Session&, keys: const PushKeys&, subscription: i64, base: const u8[:]) {
    var user: i64 = 0;
    var q = sqlite::Stmt {};
    let failed = sqlite::run() {
        q = sqlite::prepare(db,"SELECT user_id FROM push_subscriptions WHERE id=?");
        sqlite::bind_i64(q,1,subscription);
        if sqlite::step(q) { user = sqlite::column_i64(q,0); }
    };
    sqlite::finalize(q);
    for e in failed { write_stderr(str("Web Push test notification for subscription ",subscription," failed: ",e.message,"\n")); return; }
    guard user > 0 else { return; }
    let badge = push_badge(state,user);
    guard badge >= 0 else { return; }
    var message: u8[>..] = str("{\"title\":\"Campfire Test\",\"options\":{\"body\":");
    json_generate(message,random_uuid());
    message.append(",\"icon\":\"/account/logo\",\"data\":{\"path\":");
    json_generate(message,str(base,"/users/me/push_subscriptions"));
    format(message,",\"badge\":",badge,"}}}");
    deliver_push(db,state,session,keys,subscription,message);
}

// WebPush::Pool#deliver: WebPush::Notification#deliver, which sends only to an address the guard
// admits, and the subscription's destruction when the push service no longer knows it (404, 410)
// or its key is no P-256 point.
fn deliver_push(db: sqlite::Db, state: PushState&, session: http::Session&, keys: const PushKeys&, subscription: i64, message: const u8[:]) {
    var endpoint: u8[>..] = []; var p256dh_text: u8[>..] = []; var auth_text: u8[>..] = [];
    var found = false;
    var q = sqlite::Stmt {};
    let failed = sqlite::run() {
        q = sqlite::prepare(db,"SELECT endpoint,p256dh_key,auth_key FROM push_subscriptions WHERE id=?");
        sqlite::bind_i64(q,1,subscription);
        if sqlite::step(q) { sqlite::column_text(q,0,endpoint); sqlite::column_text(q,1,p256dh_text); sqlite::column_text(q,2,auth_text); found = true; }
    };
    sqlite::finalize(q);
    for e in failed { write_stderr(str("Web Push to subscription ",subscription," failed: ",e.message,"\n")); return; }
    guard found else { return; }
    // Push::Subscription#resolved_endpoint_ip: nothing is sent unless it gives an address.
    guard push_endpoint_valid(endpoint) else { push_refused(state,subscription,"its endpoint is not a permitted push service"); return; }
    let url, parsed = http::parse_url(endpoint);
    guard parsed else { write_stderr(str("Web Push to subscription ",subscription," failed: ArgumentError: bad URI\n")); return; }
    var address: u8[>..] = [];
    let resolved = campfire_push_resolve(url.host,address,-1);
    guard resolved == 0 else {
        let why: u8[>..] = if resolved == -2 { str(url.host," resolves only to private or reserved addresses") } else { str(url.host," does not resolve") };
        push_refused(state,subscription,why);
        return;
    }

    // WebPush.payload_send(message:, endpoint:, endpoint_ip:, p256dh:, auth:, vapid:, urgency: "high")
    var p256dh: u8[>..] = []; var auth: u8[>..] = [];
    guard p256dh_text.len > 0 && auth_text.len > 0 else {
        write_stderr(str("Web Push to subscription ",subscription," failed: ArgumentError: ",if p256dh_text.len == 0 { "p256dh" } else { "auth" }," cannot be blank\n"));
        return;
    }
    guard base64_url_decode(p256dh,p256dh_text) && base64_url_decode(auth,auth_text) else {
        write_stderr(str("Web Push to subscription ",subscription," failed: ArgumentError: invalid base64\n"));
        return;
    }
    var payload: u8[>..] = [];
    let sealed = campfire_push_encrypt(p256dh,auth,message,"","",payload);
    if sealed == PUSH_INVALID_KEY {
        // OpenSSL::PKey::EC::Point::Error, an OpenSSL::OpenSSLError: the pool destroys it.
        destroy_subscription(db,subscription,"its p256dh key is not a P-256 point");
        return;
    }
    guard sealed == 0 else {
        write_stderr(str("Web Push to subscription ",subscription," failed: ",if sealed == PUSH_TOO_BIG { "ArgumentError: encrypted payload is too big" } else { "OpenSSL error" },"\n"));
        return;
    }
    var authorization: u8[>..] = [];
    guard vapid_authorization(keys,url.host,authorization) else {
        write_stderr(str("Web Push to subscription ",subscription," failed: cannot sign the VAPID token\n"));
        return;
    }
    // WebPush::PersistentRequest pins the connection to the guarded address; TLS checks the host.
    session.via = if keys.test_connect.len > 0 { keys.test_connect[..] } else { address[..] };
    let response, err = http::post(session,endpoint) { req =>
        http::header(req,"Ttl",PUSH_TTL);
        http::header(req,"Urgency",PUSH_URGENCY);
        http::header(req,"Content-Encoding","aes128gcm");
        http::header(req,"Authorization",authorization);
        http::body(req,"application/octet-stream",payload);
    };
    // Net::HTTP's connection lasts the one request.
    http::hangup(session);
    session.via = [];
    if err.code != 0 {
        write_stderr(str("Web Push to subscription ",subscription," failed: ",err.call," error ",err.code,"\n"));
        return;
    }
    // WebPush::Request#verify_response
    let status = response.status;
    if status >= 200 && status <= 299 { return; }
    if status == 410 || status == 404 {
        destroy_subscription(db,subscription,str("the push service answered ",status));
        return;
    }
    // FCM's 400 "UnauthorizedRegistration" is an Unauthorized in the gem, but goose-http's client
    // keeps no reason phrase, so it is logged as a ResponseError; either way it is only logged.
    let name = if status == 401 || status == 403 { "WebPush::Unauthorized" }
        else if status == 413 { "WebPush::PayloadTooLarge" } else if status == 429 { "WebPush::TooManyRequests" }
        else if status >= 500 && status <= 599 { "WebPush::PushServiceError" } else { "WebPush::ResponseError" };
    write_stderr(str("Web Push to subscription ",subscription," failed: ",name," host: ",url.host,", status ",status,"\n"));
}

// The invalid_subscription_handler: Push::Subscription.find_by(id:)&.destroy, logged as Rails does.
fn destroy_subscription(db: sqlite::Db, subscription: i64, why: const u8[:]) {
    write_stderr(str("Destroying push subscription: ",subscription," (",why,")\n"));
    campfire_writer_enter();
    var q = sqlite::Stmt {};
    let failed = sqlite::run() {
        q = sqlite::prepare(db,"DELETE FROM push_subscriptions WHERE id=?");
        sqlite::bind_i64(q,1,subscription);
        while sqlite::step(q) {}
    };
    sqlite::finalize(q);
    campfire_writer_leave();
    for e in failed { write_stderr(str("Destroying push subscription ",subscription," failed: ",e.message,"\n")); }
}

// WebPush::Request#build_vapid_header: "vapid t=<JWT>,k=<public key>", the JWT ES256-signed with
// aud the endpoint's scheme and host, exp twelve hours from now, and the subject.
fn vapid_authorization(keys: const PushKeys&, host: const u8[:], out: u8[>..]&) -> bool {
    var claims: u8[>..] = str("{\"aud\":");
    json_generate(claims,str("https://",host));
    format(claims,",\"exp\":",campfire_unix_seconds() + PUSH_EXPIRATION,",\"sub\":");
    json_generate(claims,PUSH_SUBJECT);
    claims.push('}');
    var input: u8[>..] = [];
    base64_url(input,"{\"typ\":\"JWT\",\"alg\":\"ES256\"}");
    input.push('.');
    base64_url(input,claims);
    var signature: u8[>..] = [];
    guard campfire_vapid_sign(keys.public_key,keys.private_key,input,signature) else { return false; }
    out.append("vapid t="); out.append(input); out.push('.'); base64_url(out,signature);
    out.append(",k="); base64_url(out,keys.public_key);
    return true;
}

// A JSON string as Ruby's JSON.generate writes it: only ", \ and control characters escaped.
fn json_generate(out: u8[>..]&, raw: const u8[:]) {
    var s: u8[>..] = []; utf8_lossy(s,raw);
    let hex = "0123456789abcdef";
    out.push('"');
    for c in s {
        if c == '"' { out.append("\\\""); }
        else if c == '\\' { out.append("\\\\"); }
        else if c == '\n' { out.append("\\n"); }
        else if c == '\r' { out.append("\\r"); }
        else if c == '\t' { out.append("\\t"); }
        else if c == 8 { out.append("\\b"); }
        else if c == 12 { out.append("\\f"); }
        else if c < 0x20 { out.append("\\u00"); out.push(hex[c >> 4]); out.push(hex[c & 15]); }
        else { out.push(c); }
    }
    out.push('"');
}
