// Image processing off the HTTP workers. Variants are made by media threads, as Rails makes them
// lazily on a representation's or avatar's first request (VariantWithRecord#processed), and eagerly
// after an upload, as Message#process_attachment does for a message's thumbnail. A request whose
// variant isn't made yet waits (http::later) and its worker is free meanwhile: the media thread
// makes and records the variant, puts the answer in a shared blob, and mails its handle to the
// waiting exchange, which sends it (media_reply).
namespace campfire;

import std;
import os;
import sqlite;
import http;
import http.shared;
import database;
import storage;
import checkpoints;
import messages;
import avatars;
import admin_routes;
import sessions;

// What a job makes: a variant, answering a representation request with its redirect; an avatar's
// :square variant, answering with the avatar; or the account logo's :large and :small, answering
// with the logo of record's size (1 small, 0 large).
let MEDIA_VARIANT: i32 = 1;
let MEDIA_REDIRECT: i32 = 2;
let MEDIA_AVATAR: i32 = 3;
let MEDIA_LOGO: i32 = 4;
// The tag of a media thread's mail to a waiting exchange.
let MEDIA_DONE: i32 = 260;
// The most jobs waiting; past it a request is answered 503 and an upload's eager job is dropped
// (its variant is then made on first request).
let MEDIA_QUEUE: i64 = 1024;

struct MediaJob {
    kind: i32 = 0,
    blob: i64 = 0,
    record: i64 = 0,
    variation: Variation = Variation { .. },
    disposition: u8[..16] = [],
    wait: bool = false,
    reply: http::MailAddress = http::MailAddress { .. },
    host: u8[..512] = [],
}

struct MediaSettings { storage: u8[..1024] = [], key: u8[64] = [0; 64] }

// A response a media thread made for a waiting exchange, or a worker for its own.
struct MediaAnswer {
    status: i32 = 500,
    content_type: u8[..128] = [],
    etag: u8[..96] = [],
    cache: u8[..96] = [],
    nosniff: bool = false,
    location: u8[..4096] = [],
    body: u8[>..] = [],
}

fn send_answer(out: http::Reply, a: const MediaAnswer&) {
    if a.status == 302 {
        http::start(out, 302);
        http::field(out, "Location", a.location);
        http::field(out, "Cache-Control", "max-age=300, private");
        http::field(out, "Content-Type", "text/html; charset=utf-8");
        http::finish(out, http::NO_TYPE, "");
        return;
    }
    if a.status != 200 && a.status != 304 {
        http::respond(out, a.status, "text/plain", if a.status == 404 { "Not found" } else { "Unable to process the image" });
        return;
    }
    http::start(out, a.status);
    if a.etag.len > 0 { http::field(out, "ETag", a.etag); }
    if a.cache.len > 0 { http::field(out, "Cache-Control", a.cache); }
    if a.nosniff { http::field(out, "X-Content-Type-Options", "nosniff"); }
    http::field(out, "Content-Type", a.content_type);
    http::finish(out, http::NO_TYPE, a.body);
}

fn encode_answer(a: const MediaAnswer&) -> u8[>..] {
    var out: u8[>..] = [];
    format(out, a.status, "\n", a.content_type, "\n", a.etag, "\n", a.cache, "\n", if a.nosniff { "1" } else { "0" }, "\n", a.location, "\n");
    out.append(a.body);
    return out;
}

fn decode_answer(bytes: const u8[:], a: MediaAnswer&) -> bool {
    var at: i64 = 0;
    for i in 6 {
        let end = find(bytes[at..], "\n");
        guard end >= 0 else { return false; }
        let field = bytes[at..at + end]; at += end + 1;
        if i == 0 { let status, valid = parse_int(field); guard valid else { return false; } a.status = status as! i32; }
        else if i == 1 { guard field.len <= 128 else { return false; } a.content_type = field; }
        else if i == 2 { guard field.len <= 96 else { return false; } a.etag = field; }
        else if i == 3 { guard field.len <= 96 else { return false; } a.cache = field; }
        else if i == 4 { a.nosniff = field == "1"; }
        else { guard field.len <= 4096 else { return false; } a.location = field; }
    }
    a.body.append(bytes[at..]);
    return true;
}

// The worker's WAKE with MEDIA_DONE: the answer a media thread made.
fn media_reply(data: const u8[:], out: http::Reply) {
    guard data.len == 8 else { http::respond(out, 500, "text/plain", "Unable to process the image"); return; }
    var h: i64 = 0;
    for i in 8 { h = h | ((data[i] as i64) << (8 * i)); }
    let blob = http::Shared { h: h };
    var bytes: u8[>..] = [];
    let copied = http::shared_append(blob, 0, http::shared_len(blob), bytes);
    http::shared_release(blob);
    var answer = MediaAnswer { .. };
    if copied && decode_answer(bytes, answer) { send_answer(out, answer); }
    else { http::respond(out, 500, "text/plain", "Unable to process the image"); }
}

fn mail_answer(to: http::MailAddress, a: const MediaAnswer&) {
    let blob, failed = http::shared_put(encode_answer(a), 1);
    guard failed == 0 else { return; }
    var handle: u8[8] = [0; 8];
    for i in 8 { handle[i] = ((blob.h >> (8 * i)) & 255) as! u8; }
    if http::mail_send(to, MEDIA_DONE, handle) != http::SENT { http::shared_release(blob); }
}

// Restarts a media thread that aborted, so one bad image can't stop the rest.
thread_fn media_supervisor(database: u8[], settings: MediaSettings) {
    loop {
        let worker = thread_spawn_contained(media_worker, copy(database), settings);
        var message: u8[>..] = [];
        if thread_wait(worker, message) { return; }
        write_stderr(str("Image processing restarts after: ", message, "\n"));
        sleep_ms(100);
    }
}

thread_fn media_worker(database: u8[], settings: MediaSettings) {
    var db = sqlite::Db {};
    let failed = sqlite::run() {
        db = sqlite::open(database, sqlite::READ_WRITE);
        sqlite::busy_timeout(db, 5000);
        sqlite::exec(db, "PRAGMA synchronous=NORMAL; PRAGMA cache_size=200;");
        let wal = campfire_track_wal(db.id); if wal != 0 { sqlite::fail(wal, "Cannot install WAL observer"); }
    };
    if failed.len > 0 {
        for e in failed { write_stderr(str("Image processing cannot open the database: ", e.message, "\n")); }
        return;
    }
    loop {
        let job = qget<MediaJob>();
        run_media_job(db, settings, job);
    }
}

// VariantWithRecord#processed: the variant blob, made and recorded when it isn't yet. When another
// thread records it first, its image wins and this one's file is deleted.
fn ensure_variant(db: sqlite::Db, storage: const u8[:], blob: i64, v: const Variation&, error: u8[>..]&) -> VariantBlob {
    let digest = variation_digest(v);
    var found = VariantBlob { .. };
    var source_key: u8[>..] = []; var source_filename: u8[>..] = []; var variable = false;
    let read = sqlite::run() {
        found = find_variant(db, blob, digest);
        if found.id == 0 {
            for row in sql_rows(db, "SELECT key,filename,coalesce(content_type,'') FROM active_storage_blobs WHERE id=?", [sql_text(blob)]) {
                source_key.append(cell(row, 0)); source_filename.append(cell(row, 1)); variable = variable_content_type(cell(row, 2));
            }
        }
    };
    if read.len > 0 { for e in read { error.append(e.message); } return found; }
    if found.id != 0 { return found; }
    guard variable && source_key.len > 0 else { error.append("the blob is gone or can't be transformed"); return found; }
    var staged = StagedVariant { .. };
    guard transform_variant(storage, source_key, source_filename, v, staged, error) else { return found; }
    var now: u8[>..] = []; campfire_sql_now(now);
    var recorded = false;
    campfire_writer_enter();
    let failed = sqlite::run() {
        sqlite::exec(db, "BEGIN IMMEDIATE");
        if sql_number(db, "SELECT count(*) FROM active_storage_blobs WHERE id=?", [sql_text(blob)]) > 0 { recorded = record_variant(db, blob, digest, staged, now); }
        sqlite::exec(db, "COMMIT");
    };
    if failed.len > 0 { let rollback = sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db, "ROLLBACK"); } }; }
    if failed.len == 0 && recorded { checkpoint_after_write(db); }
    campfire_writer_leave();
    for e in failed { error.append(e.message); }
    if failed.len > 0 || !recorded { delete_blob_file(storage, staged.key); }
    let again = sqlite::run() { found = find_variant(db, blob, digest); };
    return found;
}

fn run_media_job(db: sqlite::Db, settings: const MediaSettings&, job: const MediaJob&) {
    var error: u8[>..] = [];
    var answer = MediaAnswer { .. };
    if job.kind == MEDIA_VARIANT || job.kind == MEDIA_REDIRECT {
        let variant = ensure_variant(db, settings.storage, job.blob, job.variation, error);
        if variant.id != 0 {
            answer.status = 302;
            answer.location = str(job.host, disk_path(variant.key, variant.filename, content_type_for_serving(variant.content_type),
                disposition_for_serving(variant.content_type, job.disposition), settings.key));
        }
    } else if job.kind == MEDIA_AVATAR {
        let square_variation = avatar_variation(); let square = ensure_variant(db, settings.storage, job.blob, square_variation, error);
        if job.wait { let failed = sqlite::run() { let pending = avatar_answer(db, job.record, "", settings.storage, true, answer); }; }
    } else if job.kind == MEDIA_LOGO {
        let large_variation = logo_variation(false); let large = ensure_variant(db, settings.storage, job.blob, large_variation, error);
        let small_variation = logo_variation(true); let small = ensure_variant(db, settings.storage, job.blob, small_variation, error);
        if job.wait { let failed = sqlite::run() { let pending = logo_answer(db, job.record == 1, "", settings.storage, true, answer); }; }
    }
    if error.len > 0 { write_stderr(str("Image processing of blob ", job.blob, " failed: ", error, "\n")); }
    if job.wait { mail_answer(job.reply, answer); }
}

// After an upload: the variants Rails would make, made now, so that the first request needn't wait.
fn process_later(kind: i32, blob: i64, record: i64, variation: Variation) {
    if !qput(MediaJob { kind: kind, blob: blob, record: record, variation: variation, .. }) {
        write_stderr(str("Image processing queue is full: blob ", blob, " is processed on first request\n"));
    }
}
