// Image and video processing off the HTTP workers. Variants and video previews are made by media
// threads, as Rails makes them lazily on a representation's or avatar's first request
// (VariantWithRecord#processed, Preview#processed), and eagerly after an upload, as
// Message#process_attachment does for a message's thumbnail or a video's preview. Videos and audio
// are analyzed with ffprobe there too. A request whose variant or preview isn't made yet waits
// (http::later) and its worker is free meanwhile: the media thread makes and records it, puts the
// answer in a shared blob, and mails its handle to the waiting exchange, which sends it
// (media_reply).
namespace campfire;

import std;
import os;
import sqlite;
import http;
import etag;
import http.shared;
import http.compression;
import database;
import storage;
import checkpoints;
import messages;
import avatars;
import admin_routes;
import sessions;
import route_support;
import cable;
import public_pages;
import auth_routes;
import active_storage;
import shutdown;

// What a job makes: a representation (a variant, or a video's preview), answering a
// representation request with its redirect; an avatar's :square variant, answering with the avatar;
// the account logo's :large and :small, answering with the logo of record's size (1 small, 0
// large); or a video's or audio file's analysis, then, for a message's attachment (record, which
// posting says how it was posted), its preview and the message's broadcast
// (Message#process_attachment, then broadcast_create).
let MEDIA_VARIANT: i32 = 1;
let MEDIA_REDIRECT: i32 = 2;
let MEDIA_AVATAR: i32 = 3;
let MEDIA_LOGO: i32 = 4;
// Representations::ProxyController#show, for a representation not processed yet: its bytes.
let MEDIA_PROXY: i32 = 6;
let MEDIA_ANALYZE: i32 = 5;
// How an attachment's message was posted, for MEDIA_ANALYZE: by a browser's form, which is
// answered with its turbo stream; through the bot API, answered 201 with its location (host the
// request's base); or as a bot's webhook reply, which nobody waits for.
let POSTED_STREAM: i32 = 1;
let POSTED_BOT: i32 = 2;
let POSTED_REPLY: i32 = 3;
// The tags of a media thread's mail to a waiting exchange: a representation's answer, and a
// processed post's (posted_reply).
let MEDIA_DONE: i32 = 260;
let MEDIA_POSTED: i32 = 261;
// How long a post waits for its attachment's processing: the queue, ffprobe's 30 seconds,
// ffmpeg's 10, the variants and a cable permit.
let MEDIA_POST_WAIT_MS: i64 = 300000;
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
    posting: i32 = 0,
    coding: http::Coding = http::Coding.Identity,
    // MEDIA_AVATAR: the validators the request adds to the user's (avatar_etag_suffix). MEDIA_PROXY:
    // the ETag, and the disposition asked for, if any.
    etag: u8[..96] = [],
    asked: u8[..256] = [],
    has_asked: bool = false,
}

struct MediaSettings { storage: u8[..1024] = [], key: u8[64] = [0; 64], avatar_key: u8[64] = [0; 64] }

// A response a media thread made for a waiting exchange, or a worker for its own.
struct MediaAnswer {
    status: i32 = 500,
    content_type: u8[..128] = [],
    etag: u8[..96] = [],
    cache: u8[..96] = [],
    location: u8[..4096] = [],
    // send_file's and send_stream's Content-Disposition, http_cache_forever's Last-Modified, and
    // send_file's Content-Transfer-Encoding.
    disposition: u8[..4096] = [],
    modified: u8[..32] = [],
    binary: bool = false,
    // A render or send_stream's body, streamed (chunked, no Content-Length) as a Live controller's
    // is; and an ApplicationController's, with the version headers when answered later.
    streamed: bool = false,
    versioned: bool = false,
    // The default headers, which Active Storage's proxies (Live controllers) send in Rails main.
    defaults: bool = false,
    body: u8[>..] = [],
}

// An answer for a Live controller (avatars, the logo, Active Storage's proxies): no default headers.
// A 304 has the 200's fields, as Thruster's cache answers it, less its type. An error is the
// exception's page (a record not found, a 500), in html: its request's formats aren't kept. later:
// answered after the request (media_reply), whose common fields lack the version headers.
fn send_answer(out: http::Reply, a: const MediaAnswer&, later: bool = false) {
    if a.status == 302 {
        http::start(out, 302);
        http::field(out, "Location", a.location);
        http::field(out, "Cache-Control", "max-age=300, private");
        http::field(out, "Content-Type", "text/html; charset=utf-8");
        http::finish(out, http::NO_TYPE, "");
        return;
    }
    if a.status != 200 && a.status != 304 { public_exception_later(out, a.status); return; }
    let chunked = a.streamed && a.status == 200 && !out.head;
    if chunked { http::begin(out, 200, -1); } else { http::start(out, a.status); }
    if later && a.versioned { version_fields(out.buf); }
    if a.defaults { out.buf.append(DEFAULT_HEADERS); }
    if a.etag.len > 0 { http::field(out, "ETag", a.etag); }
    if a.modified.len > 0 { http::field(out, "Last-Modified", a.modified); }
    if a.cache.len > 0 { http::field(out, "Cache-Control", a.cache); }
    if a.disposition.len > 0 { http::field(out, "Content-Disposition", a.disposition); }
    if a.binary { http::field(out, "Content-Transfer-Encoding", "binary"); }
    if a.status == 200 { http::field(out, "Content-Type", a.content_type); }
    if chunked { http::send(out, a.body); http::end(out); return; }
    http::finish(out, http::NO_TYPE, if a.streamed { "" } else { a.body });
}

fn encode_answer(a: const MediaAnswer&) -> u8[>..] {
    var out: u8[>..] = [];
    format(out, a.status, "\n", a.content_type, "\n", a.etag, "\n", a.cache, "\n", (if a.binary { 1 } else { 0 }) + (if a.streamed { 2 } else { 0 }) + (if a.versioned { 4 } else { 0 }) + (if a.defaults { 8 } else { 0 }), "\n", a.location, "\n",
           a.disposition, "\n", a.modified, "\n");
    out.append(a.body);
    return out;
}

fn decode_answer(bytes: const u8[:], a: MediaAnswer&) -> bool {
    var at: i64 = 0;
    for i in 8 {
        let end = find(bytes[at..], "\n");
        guard end >= 0 else { return false; }
        let field = bytes[at..at + end]; at += end + 1;
        if i == 0 { let status, valid = parse_int(field); guard valid else { return false; } a.status = status as! i32; }
        else if i == 1 { guard field.len <= 128 else { return false; } a.content_type = field; }
        else if i == 2 { guard field.len <= 96 else { return false; } a.etag = field; }
        else if i == 3 { guard field.len <= 96 else { return false; } a.cache = field; }
        else if i == 4 { let flags, valid = parse_int(field); guard valid else { return false; } a.binary = flags & 1 != 0; a.streamed = flags & 2 != 0; a.versioned = flags & 4 != 0; a.defaults = flags & 8 != 0; }
        else if i == 5 { guard field.len <= 4096 else { return false; } a.location = field; }
        else if i == 6 { guard field.len <= 4096 else { return false; } a.disposition = field; }
        else { guard field.len <= 32 else { return false; } a.modified = field; }
    }
    a.body.append(bytes[at..]);
    return true;
}

// The worker's WAKE with MEDIA_DONE: the answer a media thread made.
fn media_reply(data: const u8[:], out: http::Reply) {
    guard data.len == 8 else { public_exception_later(out, 500); return; }
    var h: i64 = 0;
    for i in 8 { h = h | ((data[i] as i64) << (8 * i)); }
    let blob = http::Shared { h: h };
    var bytes: u8[>..] = [];
    let copied = http::shared_append(blob, 0, http::shared_len(blob), bytes);
    http::shared_release(blob);
    var answer = MediaAnswer { .. };
    if copied && decode_answer(bytes, answer) { send_answer(out, answer, true); }
    else { public_exception_later(out, 500); }
}

fn mail_answer(to: http::MailAddress, a: const MediaAnswer&) { let sent = mail_shared(to, MEDIA_DONE, encode_answer(a)); }

// Mails bytes to a waiting exchange as a shared blob's handle, trying again for a second while its
// box is full. False when it didn't go: the exchange no longer waits.
fn mail_shared(to: http::MailAddress, tag: i32, bytes: const u8[:]) -> bool {
    let blob, failed = http::shared_put(bytes, 1);
    guard failed == 0 else { return false; }
    var handle: u8[8] = [0; 8];
    for i in 8 { handle[i] = ((blob.h >> (8 * i)) & 255) as! u8; }
    for attempt in 1000 {
        let result = http::mail_send(to, tag, handle);
        if result == http::SENT { return true; }
        if result != http::FULL { break; }
        sleep_ms(1);
    }
    http::shared_release(blob);
    return false;
}

// The bytes a mail_shared mail carries; false when they can't be had.
fn mailed_shared(data: const u8[:], bytes: u8[>..]&) -> bool {
    guard data.len == 8 else { return false; }
    var h: i64 = 0;
    for i in 8 { h = h | ((data[i] as i64) << (8 * i)); }
    let blob = http::Shared { h: h };
    let copied = http::shared_append(blob, 0, http::shared_len(blob), bytes);
    http::shared_release(blob);
    return copied;
}

fn coding_number(coding: http::Coding) -> i64 {
    return if coding == http::Coding.Gzip { 1 } else if coding == http::Coding.Deflate { 2 } else if coding == http::Coding.Zstd { 3 } else { 0 };
}

fn numbered_coding(n: i64) -> http::Coding {
    return if n == 1 { http::Coding.Gzip } else if n == 2 { http::Coding.Deflate } else if n == 3 { http::Coding.Zstd } else { http::Coding.Identity };
}

// respond_compressed in the coding the request took, worked out when it came.
fn respond_coded(out: http::Reply, coding: http::Coding, status: i32, content_type: const u8[:], body: const u8[:]) {
    let c = http::Compression { .. };
    http::start(out, status);
    out.buf.append(rack_etag_wire(status, body, ""));
    http::field(out, "Content-Type", content_type);
    guard http::compressible(content_type) else { http::finish(out, http::NO_TYPE, body); return; }
    out.buf.append("Vary: Accept-Encoding\r\n");
    let chosen = if out.head || out.stream.bodyless || status == 206 || body.len < c.min_size { http::Coding.Identity } else { coding };
    guard chosen != http::Coding.Identity else { http::finish(out, http::NO_TYPE, body); return; }
    out.buf.append(http::coding_field(chosen));
    var compressed: u8[>..] = [];
    http::compress_whole(body, compressed, chosen, c);
    http::finish(out, http::NO_TYPE, compressed);
}

// The worker's WAKE with MEDIA_POSTED: a post's answer once its attachment is processed, into out
// (the exchange's deferred response, sent when the broadcast's acknowledgement comes); false when
// the answer was an error, which is in out and needs no acknowledgement.
fn posted_reply(data: const u8[:], out: http::Reply) -> bool {
    var bytes: u8[>..] = [];
    guard mailed_shared(data, bytes) else { public_exception_later(out, 500); return false; }
    var fields: i64[3] = [0; 3]; var at: i64 = 0;
    for i in 3 {
        let end = find(bytes[at..], "\n");
        guard end >= 0 else { public_exception_later(out, 500); return false; }
        let n, valid = parse_int(bytes[at..at + end]); fields[i] = n; at += end + 1;
    }
    let end = find(bytes[at..], "\n");
    guard end >= 0 && fields[0] == 200 else { public_exception_later(out, 500); return false; }
    let location = bytes[at..at + end];
    let html = bytes[at + end + 1..];
    if fields[2] == POSTED_BOT {
        http::start(out, 201); http::field(out, "Location", location); http::finish(out, http::NO_TYPE, "");
    } else { respond_coded(out, numbered_coding(fields[1]), 200, "text/vnd.turbo-stream.html; charset=utf-8", html); }
    return true;
}

// Hands a post whose attachment is still to be processed (take_deferred_post) to a
// media thread, which processes it, answers the exchange at reply (unless it is a webhook reply),
// and broadcasts it. False when the media queue is full: the caller then answers and broadcasts at
// once, the attachment unanalyzed, and its bots' webhooks are its own.
fn process_posted_later(post: const DeferredPost&, posting: i32, reply: http::MailAddress, coding: http::Coding, host: const u8[:]) -> bool {
    guard post.message > 0 && post.blob > 0 && host.len <= 512 else { return false; }
    let job = MediaJob { kind: MEDIA_ANALYZE, blob: post.blob, record: post.message,
        wait: posting != POSTED_REPLY, reply: reply, host: host, posting: posting, coding: coding };
    guard queue_job(JOBS_MEDIA, job) else {
        write_stderr(str("Media processing queue is full: blob ", post.blob, " is not processed, and message ", post.message, " is broadcast at once\n"));
        return false;
    }
    if posting != POSTED_REPLY { posted_media = true; }
    return true;
}

// Restarts a media thread that aborted, so one bad image can't stop the rest.
thread_fn media_supervisor(database: u8[], settings: MediaSettings) {
    loop {
        let worker = thread_spawn_contained(media_worker, copy(database), settings);
        var message: u8[>..] = [];
        if thread_wait(worker, message) { return; }
        // The job it aborted in is done with.
        job_finished(JOBS_MEDIA);
        write_stderr(str("Image processing restarts after: ", message, "\n"));
        sleep_ms(100);
    }
}

thread_fn media_worker(database: u8[], settings: MediaSettings) {
    var db = sqlite::Db {};
    // For the bots' webhooks of the posts it broadcasts (deliver_webhooks_later).
    var writer = WriterStatements { .. };
    let failed = sqlite::run() {
        db = sqlite::open(database, sqlite::READ_WRITE);
        sqlite::busy_timeout(db, 5000);
        sqlite::exec(db, "PRAGMA synchronous=NORMAL; PRAGMA cache_size=200;");
        let wal = campfire_track_wal(db.id); if wal != 0 { sqlite::fail(wal, "Cannot install WAL observer"); }
        prepare_writer(db, writer);
    };
    if failed.len > 0 {
        for e in failed { write_stderr(str("Image processing cannot open the database: ", e.message, "\n")); }
        return;
    }
    loop {
        let job = qget<MediaJob>();
        job_started(JOBS_MEDIA);
        run_media_job(db, writer, settings, job);
        job_finished(JOBS_MEDIA);
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
    let failed = write_transaction(db) {
        if sql_number(db, "SELECT count(*) FROM active_storage_blobs WHERE id=?", [sql_text(blob)]) > 0 { recorded = record_variant(db, blob, digest, staged, now); }
    };
    for e in failed { error.append(e.message); }
    if failed.len > 0 || !recorded { delete_blob_file(storage, staged.key); }
    let again = sqlite::run() { found = find_variant(db, blob, digest); };
    return found;
}

// Preview#process unless processed?: the video's preview image, drawn with ffmpeg and attached when
// it isn't yet. When another thread attaches one first, its image wins and this one's file is
// deleted.
fn ensure_preview_image(db: sqlite::Db, storage: const u8[:], blob: i64, error: u8[>..]&) -> VariantBlob {
    var found = VariantBlob { .. };
    var source_key: u8[>..] = []; var source_filename: u8[>..] = []; var previewable = false;
    let read = sqlite::run() {
        found = find_preview_image(db, blob);
        if found.id == 0 {
            for row in sql_rows(db, "SELECT key,filename,coalesce(content_type,'') FROM active_storage_blobs WHERE id=?", [sql_text(blob)]) {
                source_key.append(cell(row, 0)); source_filename.append(cell(row, 1)); previewable = previewable_content_type(cell(row, 2));
            }
        }
    };
    if read.len > 0 { for e in read { error.append(e.message); } return found; }
    if found.id != 0 { return found; }
    guard previewable && source_key.len > 0 else { error.append("the blob is gone or can't be previewed"); return found; }
    var staged = StagedVariant { .. };
    guard stage_preview_image(storage, source_key, source_filename, staged, error) else { return found; }
    var now: u8[>..] = []; campfire_sql_now(now);
    var recorded = false;
    let failed = write_transaction(db) {
        if sql_number(db, "SELECT count(*) FROM active_storage_blobs WHERE id=?", [sql_text(blob)]) > 0 { recorded = record_preview_image(db, blob, staged, now); }
    };
    for e in failed { error.append(e.message); }
    if failed.len > 0 || !recorded { delete_blob_file(storage, staged.key); }
    let again = sqlite::run() { found = find_preview_image(db, blob); };
    return found;
}

// blob.representation(variation).processed, the blob that represents it: for a previewable blob
// its preview (Preview#presentation: the preview image itself for a bare variation, otherwise the
// image's variant), for a variable one its variant.
fn ensure_representation(db: sqlite::Db, storage: const u8[:], blob: i64, v: const Variation&, error: u8[>..]&) -> VariantBlob {
    var previewable = false;
    let read = sqlite::run() { previewable = previewable_content_type(sql_value(db, "SELECT coalesce(content_type,'') FROM active_storage_blobs WHERE id=?", [sql_text(blob)])); };
    if read.len > 0 { for e in read { error.append(e.message); } return VariantBlob { .. }; }
    guard previewable else { return ensure_variant(db, storage, blob, v, error); }
    let image = ensure_preview_image(db, storage, blob, error);
    if image.id == 0 || v.bare { return image; }
    return ensure_variant(db, storage, image.id, v, error);
}

// Blob#analyze for a video or an audio file: ffprobe's metadata merged in, saved, and the records
// holding the blob touched. False, with why, where Rails' analyzer raises.
fn analyze_blob(db: sqlite::Db, storage: const u8[:], blob: i64, error: u8[>..]&) -> bool {
    var key: u8[>..] = []; var filename: u8[>..] = []; var content_type: u8[>..] = []; var stored: u8[>..] = [];
    let read = sqlite::run() {
        for row in sql_rows(db, "SELECT key,filename,coalesce(content_type,''),coalesce(metadata,'') FROM active_storage_blobs WHERE id=?", [sql_text(blob)]) {
            key.append(cell(row, 0)); filename.append(cell(row, 1)); content_type.append(cell(row, 2)); stored.append(cell(row, 3));
        }
    };
    if read.len > 0 { for e in read { error.append(e.message); } return false; }
    guard key.len > 0 && probed_content_type(content_type) else { error.append("the blob is gone or isn't a video or audio file"); return false; }
    var metadata: u8[>..] = [];
    guard probed_metadata(storage, key, filename, content_type, stored, metadata, error) else { return false; }
    var now: u8[>..] = []; campfire_sql_now(now);
    let failed = write_transaction(db) { save_analysis(db, blob, metadata, now); };
    for e in failed { error.append(e.message); }
    return failed.len == 0;
}

// Message#process_attachment, for a message's attachment: ensure_attachment_analyzed (a video's or
// audio file's ffprobe; an image was analyzed as it was staged), then process_attachment_thumbnail,
// unless too_many_pixels_to_preview?: a video's preview(:poster) (its preview image and that
// image's :poster variant), or an image's representation(:thumb). A preview that fails, as
// PreviewError or Vips::Error do, is logged and the message posted without it. False, with why,
// where Rails raises: the analysis fails, or a video has no previewer.
fn process_attachment(db: sqlite::Db, storage: const u8[:], blob: i64, error: u8[>..]&) -> bool {
    var content_type: u8[>..] = []; var filename: u8[>..] = [];
    let read = sqlite::run() {
        for row in sql_rows(db, "SELECT coalesce(content_type,''),filename FROM active_storage_blobs WHERE id=?", [sql_text(blob)]) {
            content_type.append(cell(row, 0)); filename.append(cell(row, 1));
        }
    };
    if read.len > 0 { for e in read { error.append(e.message); } return false; }
    if probed_content_type(content_type) { guard analyze_blob(db, storage, blob, error) else { return false; } }
    let video = video_content_type(content_type);
    let variable = variable_content_type(content_type);
    guard video || variable else { return true; }
    var metadata: u8[>..] = [];
    let again = sqlite::run() { metadata.append(sql_value(db, "SELECT coalesce(metadata,'') FROM active_storage_blobs WHERE id=?", [sql_text(blob)])); };
    if again.len > 0 { for e in again { error.append(e.message); } return false; }
    if (video || starts_with(content_type, "image")) && too_many_pixels_to_preview(metadata) { return true; }
    if video { guard campfire_ffmpeg_exists() else { error.append("no previewer found: ffmpeg isn't installed"); return false; } }
    var failed: u8[>..] = [];
    let variation = if video { poster_variation() } else { thumb_variation(content_type, filename) };
    let made = if video { ensure_representation(db, storage, blob, variation, failed) } else { ensure_variant(db, storage, blob, variation, failed) };
    if made.id == 0 { write_stderr(str("Posted ", filename, " without a preview: ", failed, "\n")); }
    return true;
}

// MessagesController#create (and Messages::ByBotsController's, and Webhook#receive_attachment_reply_to)
// once process_attachment has run: the waiting exchange gets its answer, then the message is
// broadcast (broadcast_create), the publication's acknowledgement going to that exchange, which
// then sends the answer, and the room's bots get their webhooks. Where processing failed the answer
// is 500 and nothing is broadcast, as Rails raises first. An exchange that no longer waits (it
// timed out, or its client left) doesn't stop the broadcast.
fn finish_post(db: sqlite::Db, writer: const WriterStatements&, settings: const MediaSettings&, job: const MediaJob&, processed: bool, error: u8[>..]&) {
    var html: u8[>..] = []; var room: i64 = 0; var direct = false; var posted_ms: i64 = 0; var creator: i64 = 0;
    if processed {
        let failed = sqlite::run() {
            // The copy-link button's URL: the posting request's, or, for a webhook's reply (a job's
            // render), ApplicationController.renderer's default host.
            var bytes: u8[>..] = []; var ctx = ViewContext { storage_key: settings.key[..], base_url: if job.host.len > 0 { job.host[..] } else { "http://example.org" }, .. };
            let r, d, ms = render_posted_attachment(db, job.record, settings.avatar_key, ctx, bytes, html);
            room = r; direct = d; posted_ms = ms;
            creator = sql_number(db, "SELECT creator_id FROM messages WHERE id=?", [sql_text(job.record)]);
        };
        for e in failed { error.append(e.message); }
        if failed.len > 0 || room == 0 { room = 0; if failed.len == 0 { error.append("the message is gone"); } }
    }
    let status: i32 = if room > 0 { 200 } else { 500 };
    var sent = false;
    if job.posting != POSTED_REPLY {
        var payload: u8[>..] = [];
        format(payload, status, "\n", coding_number(job.coding), "\n", job.posting, "\n", job.host, "/messages/", job.record, "\n");
        payload.append(html);
        sent = mail_shared(job.reply, MEDIA_POSTED, payload);
    }
    guard status == 200 else { return; }
    let permit, admitted = qget<CablePermit>(60000);
    guard admitted else { error.append("live delivery is busy, so the message isn't broadcast"); return; }
    publish(room, if sent { job.reply } else { http::MailAddress { .. } }, html, posted_ms);
    if job.posting != POSTED_REPLY && direct { let mentions: i64[>..] = []; deliver_webhooks_later(writer, room, creator, job.record, true, mentions); }
}

fn run_media_job(db: sqlite::Db, writer: const WriterStatements&, settings: const MediaSettings&, job: const MediaJob&) {
    var error: u8[>..] = [];
    var answer = MediaAnswer { .. };
    if job.kind == MEDIA_ANALYZE && job.posting != 0 {
        let processed = process_attachment(db, settings.storage, job.blob, error);
        finish_post(db, writer, settings, job, processed, error);
    } else if job.kind == MEDIA_ANALYZE {
        // AnalyzeJob, for an avatar's or the logo's video or audio file.
        let analyzed = analyze_blob(db, settings.storage, job.blob, error);
    } else if job.kind == MEDIA_VARIANT || job.kind == MEDIA_REDIRECT {
        let variant = ensure_representation(db, settings.storage, job.blob, job.variation, error);
        if variant.id != 0 {
            answer.status = 302;
            answer.location = str(job.host, disk_path(variant.key, variant.filename, content_type_for_serving(variant.content_type),
                disposition_for_serving(variant.content_type, job.disposition), settings.key));
        }
    } else if job.kind == MEDIA_AVATAR {
        let square_variation = avatar_variation(); let square = ensure_variant(db, settings.storage, job.blob, square_variation, error);
        if job.wait { let failed = sqlite::run() { let pending = avatar_answer(db, job.record, "", false, job.etag, settings.storage, true, answer); }; }
    } else if job.kind == MEDIA_LOGO {
        let large_variation = logo_variation(false); let large = ensure_variant(db, settings.storage, job.blob, large_variation, error);
        let small_variation = logo_variation(true); let small = ensure_variant(db, settings.storage, job.blob, small_variation, error);
        if job.wait { let failed = sqlite::run() { let pending = logo_answer(db, job.record == 1, "", false, job.etag, settings.storage, true, answer); }; }
    } else if job.kind == MEDIA_PROXY {
        let image = ensure_representation(db, settings.storage, job.blob, job.variation, error);
        if image.id != 0 { proxy_answer(settings.storage, image, job, answer); }
    }
    if error.len > 0 { write_stderr(str(if job.kind == MEDIA_ANALYZE { "Media processing" } else { "Image processing" }, " of blob ", job.blob, " failed: ", error, "\n")); }
    if job.wait && job.kind != MEDIA_ANALYZE { mail_answer(job.reply, answer); }
}

// After an upload: the variants Rails would make, made now, so that the first request needn't wait,
// and a video's or audio file's analysis.
fn process_later(kind: i32, blob: i64, record: i64, variation: Variation) {
    if !queue_job(JOBS_MEDIA, MediaJob { kind: kind, blob: blob, record: record, variation: variation, .. }) {
        if kind == MEDIA_ANALYZE { write_stderr(str("Media processing queue is full: blob ", blob, " is not analyzed\n")); }
        else { write_stderr(str("Image processing queue is full: blob ", blob, " is processed on first request\n")); }
    }
}
