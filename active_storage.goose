// The Active Storage endpoints Campfire's pages link to (activestorage/config/routes.rb), as the
// engine's controllers serve them: blob and representation redirects and proxies, and the disk
// service's signed GET. They inherit from ActiveStorage::BaseController, not ApplicationController,
// so they need no session: the signed ids are the authorization. Direct uploads (POST
// /rails/active_storage/direct_uploads and the disk PUT) are not served; Campfire uploads
// attachments through its own forms and never uses them.
namespace campfire;

import std;
import os;
import sqlite;
import http;
import database;
import storage;
import media;
import https;
import hash;
import json;
import base64;
import signed_id;
import admin_routes;
import sessions;
import auth;
import auth_routes;
import route_support;
import etag;
import public_pages;
import avatars;

extern fn campfire_now(out: u8[>..]&);

// The path's one or two segments after prefix, percent-decoded into first and second: the signed
// ids, before the filename.
fn storage_segments(path: const u8[:], prefix: const u8[:], count: i64, first: u8[>..]&, second: u8[>..]&) -> bool {
    first.clear(); second.clear();
    guard starts_with(path, prefix) else { return false; }
    var rest = path[prefix.len..];
    for i in count {
        let slash = find(rest, "/");
        guard slash > 0 else { return false; }
        var decoded: u8[>..] = [];
        guard http::decode(rest[..slash], decoded, false) else { return false; }
        if i == 0 { first.append(decoded); } else { second.append(decoded); }
        rest = rest[slash + 1..];
    }
    // The *filename glob is only for the URL's looks; Rails ignores it too.
    return rest.len > 0;
}

fn disposition_param(req: const http::Request&) -> u8[>..] {
    let raw, has = http::query_of(req.target, "disposition");
    var out: u8[>..] = [];
    if has { http::decode(raw, out, true); }
    return out;
}

fn request_host(req: const http::Request&) -> u8[>..] {
    return base_url(req);
}

// head :not_found from a before_action: text/html, no body.
fn storage_not_found(out: http::Reply) {
    http::start(out, 404); http::field(out, "Content-Type", "text/html"); http::finish(out, http::NO_TYPE, "");
}

fn storage_redirect(out: http::Reply, location: const u8[:]) {
    http::start(out, 302);
    http::field(out, "Location", location);
    // expires_in ActiveStorage.service_urls_expire_in
    http::field(out, "Cache-Control", "max-age=300, private");
    http::field(out, "Content-Type", "text/html; charset=utf-8");
    http::finish(out, http::NO_TYPE, "");
}

// The blob a signed id names: id, key, filename and content type; id 0 when there is none.
struct StoredBlob { id: i64 = 0, key: u8[..32] = [], content_type: u8[..256] = [], size: i64 = 0, filename: u8[..1024] = [] }

fn stored_blob(db: sqlite::Db, id: i64) -> StoredBlob {
    var out = StoredBlob { .. };
    for row in sql_rows(db, "SELECT key,filename,coalesce(content_type,''),byte_size FROM active_storage_blobs WHERE id=?", [sql_text(id)]) {
        let size, valid = parse_int(cell(row, 3));
        if cell(row, 0).len <= 32 && cell(row, 2).len <= 256 && cell(row, 1).len <= 1024 { out = StoredBlob { id: id, key: cell(row, 0), content_type: cell(row, 2), size: size, filename: cell(row, 1) }; }
    }
    return out;
}

// GET and HEAD of /rails/active_storage/blobs/... and /representations/...: true when the path is
// one of them. The disk service's own path is the worker loop's (serve_disk), which streams files.
fn active_storage_route(db: sqlite::Db, req: const http::Request&, storage: const u8[:], key: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    guard starts_with(path, "/rails/active_storage/") else { return false; }
    guard req.method == "GET" || req.method == "HEAD" else { return false; }
    var now: u8[>..] = []; campfire_now(now);
    var signed: u8[>..] = []; var variation_token: u8[>..] = [];
    // The proxy routes are serve_proxy's.
    if is_proxy_path(path) { return false; }
    if storage_segments(path, "/rails/active_storage/blobs/redirect/", 1, signed, variation_token) ||
       storage_segments(path, "/rails/active_storage/blobs/", 1, signed, variation_token) {
        let id = verify_blob_id(signed, key, now);
        if id == 0 { storage_not_found(out); return true; }
        var blob = StoredBlob { .. };
        let failed = sqlite::run() { blob = stored_blob(db, id); };
        if failed.len > 0 { public_exception(out, req, 500); return true; }
        if blob.id == 0 { public_exception(out, req, 404); return true; }
        let disposition = disposition_for_serving(blob.content_type, disposition_param(req));
        let location = str(request_host(req), disk_path(blob.key, blob.filename, content_type_for_serving(blob.content_type), disposition, key));
        storage_redirect(out, location);
        return true;
    }
    if storage_segments(path, "/rails/active_storage/representations/redirect/", 2, signed, variation_token) ||
       storage_segments(path, "/rails/active_storage/representations/", 2, signed, variation_token) {
        let id = verify_blob_id(signed, key, now);
        if id == 0 { storage_not_found(out); return true; }
        var blob = StoredBlob { .. }; var variant = VariantBlob { .. };
        var v = Variation { .. }; var decoded = false; var invalid = false; var previewable = false;
        let failed = sqlite::run() {
            blob = stored_blob(db, id);
            if blob.id != 0 {
                // Blob#representation: a video's preview, whose variant defaults to the format of its
                // image, the frame ffmpeg draws as <base>.jpg; or an image's variant.
                previewable = previewable_content_type(blob.content_type);
                let defaults = if previewable { Variation { format: "jpg", .. } } else { default_variant_format(blob.content_type, blob.filename) };
                let result, verified, bad = decode_variation(variation_token, key, now, defaults);
                v = result; decoded = verified; invalid = bad;
                if decoded && !invalid && previewable {
                    let image = find_preview_image(db, blob.id);
                    if image.id != 0 { variant = if v.bare { image } else { find_variant(db, image.id, variation_digest(v)) }; }
                } else if decoded && !invalid && variable_content_type(blob.content_type) { variant = find_variant(db, blob.id, variation_digest(v)); }
            }
        };
        if failed.len > 0 { public_exception(out, req, 500); return true; }
        if blob.id == 0 { public_exception(out, req, 404); return true; }
        if !decoded { storage_not_found(out); return true; }
        // Neither previewable nor variable: UnrepresentableError (a video too while ffmpeg is missing).
        if invalid || !(previewable || variable_content_type(blob.content_type)) {
            public_exception(out, req, 500); return true;
        }
        let disposition = disposition_param(req);
        if variant.id != 0 {
            storage_redirect(out, str(request_host(req), disk_path(variant.key, variant.filename, content_type_for_serving(variant.content_type),
                disposition_for_serving(variant.content_type, disposition), key)));
            return true;
        }
        // VariantWithRecord#processed, or Preview#processed: made off the HTTP worker, which answers
        // when the media thread mails.
        let host = request_host(req);
        guard host.len <= 512 else { http::respond(out, 400, "text/plain", "Bad request"); return true; }
        let job = MediaJob { kind: MEDIA_REDIRECT, blob: blob.id, variation: v, disposition: if disposition == "attachment" { "attachment" } else { "" },
            wait: true, reply: http::later(out, 60000), host: host };
        if !qput(job) { http::respond(out, 503, "text/plain", "Image processing is busy"); }
        return true;
    }
    return false;
}

// The most bytes a request's body may have: the upload limit for the forms that carry files (a
// message's attachment, a bot's, the profile's avatar and the account's logo), 1 MiB otherwise.
fn body_limit(req: const http::Request&, upload: i64) -> i64 {
    guard req.method == "POST" || req.method == "PATCH" || req.method == "PUT" else { return 1 << 20; }
    // DiskController#update's direct upload: the file itself.
    if req.method == "PUT" && starts_with(http::path_of(req.target), "/rails/active_storage/disk/") { return upload; }
    let kind, has_kind = http::field_of(req, "Content-Type");
    guard has_kind && starts_with(kind, "multipart/form-data") else { return 1 << 20; }
    let path = http::path_of(req.target);
    if path == "/users/me/profile" || path == "/account" { return upload; }
    if starts_with(path, "/rooms/") && ends_with(path, "/messages") { return upload; }
    return 1 << 20;
}

fn is_disk_route(req: const http::Request&) -> bool {
    return (req.method == "GET" || req.method == "HEAD") && starts_with(http::path_of(req.target), "/rails/active_storage/disk/");
}

// ActiveStorage::DiskController#show: the file the signed key names, with its content type and
// disposition, ranges and conditional requests as Rack::Files answers them, and the initializer's
// Cache-Control. body takes what is left to send at each MORE.
fn serve_disk(req: const http::Request&, storage: const u8[:], key: const u8[:], out: http::Reply, body: http::FileBody&) {
    var signed: u8[>..] = []; var variation_token: u8[>..] = [];
    var now: u8[>..] = []; campfire_now(now);
    var file_key: u8[>..] = []; var content_type: u8[>..] = []; var disposition: u8[>..] = [];
    guard storage_segments(http::path_of(req.target), "/rails/active_storage/disk/", 1, signed, variation_token) &&
          decode_disk_key(signed, key, now, file_key, content_type, disposition) else {
        respond_head(out, req, 404, true); return;
    }
    let f, status = http::open_file(blob_file(storage, file_key));
    if status != 200 { respond_head(out, req, 404, true); return; }
    // Rack::Files sends Last-Modified, but no ETag: an If-None-Match never matches.
    let tag = "";
    var modified: u8[>..] = []; http::format_date(modified, max(f.modified, 0));
    body.fd = f.fd; body.off = 0; body.left = 0;
    if content_type.len == 0 { content_type.append(BINARY_CONTENT_TYPE); }
    if http::not_modified(req, tag, f.modified) {
        http::start(out, 304); http::field(out, "Content-Disposition", disposition); http::field(out, "Cache-Control", "max-age=3600, public");
        http::field(out, "Last-Modified", modified); http::finish(out, "", ""); http::close_body(body); return;
    }
    let a, e, range = http::range_of(req, f.size, tag);
    if range == 416 {
        http::start(out, 416); http::content_range(out, 0, 0, f.size); http::finish(out, http::NO_TYPE, ""); http::close_body(body); return;
    }
    http::begin(out, range, e - a);
    if range == 206 { http::content_range(out, a, e, f.size); }
    http::field(out, "Content-Type", content_type);
    http::field(out, "Content-Disposition", disposition);
    http::field(out, "Cache-Control", "max-age=3600, public");
    http::field(out, "Last-Modified", modified);
    body.off = a; body.left = e - a;
    if out.head || body.left == 0 { http::end(out); http::close_body(body); }
}

// --- The proxy controllers -----------------------------------------------------------------------

fn is_proxy_path(path: const u8[:]) -> bool {
    return starts_with(path, "/rails/active_storage/blobs/proxy/") || starts_with(path, "/rails/active_storage/representations/proxy/");
}

fn is_proxy_route(req: const http::Request&) -> bool {
    return (req.method == "GET" || req.method == "HEAD") && is_proxy_path(http::path_of(req.target));
}

// http_cache_forever's validators: Time.new(2011, 1, 1).utc as Last-Modified, and
// expires_in 100.years, public: true, immutable: true.
let PROXY_MODIFIED = "Sat, 01 Jan 2011 00:00:00 GMT";
let PROXY_CACHE = "max-age=3155695200, public, immutable";

// http_cache_forever's stale?(etag: request.fullpath, ...): the weak ETag of the full path, with
// the etaggers' (no template has the action's name, and DisableSession leaves no flash).
fn proxy_etag(req: const http::Request&) -> u8[>..] {
    var target = req.target;
    if target.len > 0 && target[0] != '/' {
        // An absolute-form target's path and query.
        let path = http::path_of(target);
        let at = find(target, path);
        if at >= 0 { target = target[at..]; }
    }
    return weak_etag(str(target, etagger_suffix(req, "")));
}

// request.fresh?(response) for http_cache_forever: an If-None-Match listing the ETag (or *), or,
// without one, an If-Modified-Since no earlier than 2011; false with neither. 1 for the first, 2
// for the second, 0 for stale.
fn proxy_fresh(req: const http::Request&, etag: const u8[:]) -> i32 {
    let none_match, has_none_match = http::field_of(req, "If-None-Match");
    if has_none_match {
        for tag in split(none_match, ',') { if trim(tag) == etag || trim(tag) == "*" { return 1; } }
        return 0;
    }
    let since, has_since = http::field_of(req, "If-Modified-Since");
    guard has_since else { return 0; }
    let t, valid = http::parse_date(since);
    let m, known = http::parse_date(PROXY_MODIFIED);
    return if valid && known && t >= m { 2 } else { 0 };
}

// ActionDispatch::Http::ContentDisposition.format(disposition:, filename:), the disposition as given.
fn send_disposition(disposition: const u8[:], filename: const u8[:]) -> u8[>..] {
    var out = str(disposition, "; filename=\"");
    percent_escape(out, transliterate(filename), " !#$+.^_`|~-");
    out.append("\"; filename*=UTF-8''");
    percent_escape(out, filename, "!#$&+.^_`|~-");
    return out;
}

// send_blob_stream's disposition: blob.forced_disposition_for_serving || params[:disposition] || "inline".
fn stream_disposition(content_type: const u8[:], asked: const u8[:], has_asked: bool) -> u8[>..] {
    if serve_as_binary(content_type) || !allowed_inline(content_type) { return str("attachment"); }
    return if has_asked { str(asked) } else { str("inline") };
}

// A proxy's `head status`, a Live controller's (its empty body streamed but for a HEAD), with the
// default headers: from a before_action typed application/octet-stream, as the Rails image's are;
// in the action typed as Mime[formats.first].
fn proxy_head(out: http::Reply, req: const http::Request&, status: i32, in_action: bool) {
    let chosen = if in_action { request_format(req) } else { -1 };
    let content_type = if !in_action { BINARY_CONTENT_TYPE } else if chosen >= 0 { format_name(chosen) } else { "text/html" };
    let head = out.head || req.method == "HEAD";
    if head { http::start(out, status); } else { http::begin(out, status, -1); }
    out.buf.append(DEFAULT_HEADERS);
    http::field(out, "Content-Type", content_type);
    if head { http::finish(out, http::NO_TYPE, ""); } else { http::end(out); }
}

// The fields every proxy 200 and 304 has: the default headers (Live controllers send them in Rails
// main), the validators and the Cache-Control.
fn proxy_validators(out: http::Reply, etag: const u8[:]) {
    out.buf.append(DEFAULT_HEADERS);
    http::field(out, "ETag", etag);
    http::field(out, "Last-Modified", PROXY_MODIFIED);
    http::field(out, "Cache-Control", PROXY_CACHE);
}

// http_cache_forever's head :not_modified. fresh 1, for an If-None-Match: with the 200's fields too,
// as Thruster's cache answers it (once the 200 is stored, a matching If-None-Match never reaches
// Rails; an If-Modified-Since alone does).
fn proxy_not_modified(out: http::Reply, etag: const u8[:], fresh: i32, blob: bool, disposition: const u8[:]) {
    http::start(out, 304); proxy_validators(out, etag);
    if fresh == 1 && blob { http::field(out, "Accept-Ranges", "bytes"); }
    if fresh == 1 && disposition.len > 0 { http::field(out, "Content-Disposition", disposition); }
    http::finish(out, "", "");
}

// send_blob_stream of the file at path, typed content_type, with disposition (a Content-Disposition):
// streamed from body at each MORE, chunked (the Live response drops the blob proxy's own
// Content-Length), a HEAD's empty. A file gone is ActiveStorage::FileNotFoundError's expires_now
// and head :not_found. blob: the blob proxy's Accept-Ranges.
fn proxy_stream(req: const http::Request&, out: http::Reply, body: http::FileBody&, path: const u8[:], etag: const u8[:],
                content_type: const u8[:], disposition: const u8[:], blob: bool) {
    let f, status = http::open_file(path);
    let head = out.head || req.method == "HEAD";
    if status != 200 {
        if head { http::start(out, 404); } else { http::begin(out, 404, -1); }
        out.buf.append(DEFAULT_HEADERS);
        http::field(out, "ETag", etag); http::field(out, "Last-Modified", PROXY_MODIFIED); http::field(out, "Cache-Control", "no-cache");
        if blob { http::field(out, "Accept-Ranges", "bytes"); }
        let chosen = request_format(req);
        http::field(out, "Content-Type", if chosen >= 0 { format_name(chosen) } else { "text/html" });
        if head { http::finish(out, http::NO_TYPE, ""); } else { http::end(out); }
        return;
    }
    if head { http::start(out, 200); } else { http::begin(out, 200, -1); }
    proxy_validators(out, etag);
    if blob { http::field(out, "Accept-Ranges", "bytes"); }
    http::field(out, "Content-Type", content_type);
    http::field(out, "Content-Disposition", disposition);
    if head { http::finish(out, http::NO_TYPE, ""); http::close_file(f); return; }
    body.fd = f.fd; body.off = 0; body.left = f.size;
    if body.left == 0 { http::end(out); http::close_body(body); }
}

// send_blob_byte_range_data(blob, range): Rack's byte range of the blob, 206 streamed from the file;
// an unsatisfiable or unreadable Range, or more ranges than ActiveStorage.streaming_max_ranges (1),
// is head :range_not_satisfiable. The disposition is the blob's own, never the one asked for.
fn proxy_ranges(req: const http::Request&, out: http::Reply, body: http::FileBody&, path: const u8[:], blob: const StoredBlob&) {
    let range, has_range = http::field_of(req, "Range");
    var firsts: i64[>..] = []; var lasts: i64[>..] = [];
    let size = max(blob.size, 0);
    let ranged = rack_byte_ranges(range, has_range, size, firsts, lasts);
    if ranged != 1 || firsts.len != 1 { proxy_head(out, req, 416, true); return; }
    let content_type = content_type_for_serving(blob.content_type);
    let disposition = send_disposition(stream_disposition(blob.content_type, "", false), sanitized_filename(blob.filename));
    let f, status = http::open_file(path);
    if status != 200 { public_exception(out, req, 500); return; }
    // The Live response drops the Content-Length send_blob_byte_range_data sets: chunked.
    let head = out.head || req.method == "HEAD";
    let length = lasts[0] - firsts[0] + 1;
    if head { http::start(out, 206); } else { http::begin(out, 206, -1); }
    out.buf.append(DEFAULT_HEADERS);
    format(out.buf, "Content-Range: bytes ", firsts[0], "-", lasts[0], "/", size, "\r\n");
    http::field(out, "Accept-Ranges", "bytes");
    http::field(out, "Content-Type", content_type);
    http::field(out, "Content-Disposition", disposition);
    http::field(out, "Content-Transfer-Encoding", "binary");
    if head { http::finish(out, http::NO_TYPE, ""); http::close_file(f); return; }
    body.fd = f.fd; body.off = firsts[0]; body.left = length;
}

// A media thread's answer for a representation it processed for the proxy (MEDIA_PROXY): its
// bytes, with send_blob_stream's fields.
fn proxy_answer(storage: const u8[:], image: const VariantBlob&, job: const MediaJob&, answer: MediaAnswer&) {
    answer.body.clear();
    guard read_file(blob_file(storage, image.key), answer.body) else { answer.status = 500; answer.body.clear(); return; }
    answer.status = 200;
    answer.content_type = content_type_for_serving(image.content_type);
    answer.etag = job.etag;
    answer.modified = PROXY_MODIFIED;
    answer.cache = PROXY_CACHE;
    answer.disposition = send_disposition(stream_disposition(image.content_type, job.asked, job.has_asked), sanitized_filename(image.filename));
    answer.streamed = true;
    answer.defaults = true;
}

// ActiveStorage::Blobs::ProxyController#show and ActiveStorage::Representations::ProxyController#show,
// Live controllers (ActiveStorage::Streaming) without a session: the blob or its representation
// streamed, with http_cache_forever's validators and 304; a blob's Range, as
// send_blob_byte_range_data. A bad signed id or variation key is head :not_found from a
// before_action, a missing blob ActiveRecord::RecordNotFound's 404. body takes what is left to
// send at each MORE.
fn serve_proxy(db: sqlite::Db, req: const http::Request&, storage: const u8[:], key: const u8[:], out: http::Reply, body: http::FileBody&) {
    let path = http::path_of(req.target);
    var now: u8[>..] = []; campfire_now(now);
    var signed: u8[>..] = []; var variation_token: u8[>..] = [];
    let blobs = starts_with(path, "/rails/active_storage/blobs/proxy/");
    let matched = if blobs { storage_segments(path, "/rails/active_storage/blobs/proxy/", 1, signed, variation_token) }
                  else { storage_segments(path, "/rails/active_storage/representations/proxy/", 2, signed, variation_token) };
    if !matched { routing_error(out, req); return; }
    let id = verify_blob_id(signed, key, now);
    // SetBlob's head :not_found. (The Rails image's Live response sends it chunked, or, now and
    // then, with Content-Length 0.)
    if id == 0 { proxy_head(out, req, 404, false); return; }
    var blob = StoredBlob { .. };
    let failed = sqlite::run() { blob = stored_blob(db, id); };
    if failed.len > 0 { public_exception(out, req, 500); return; }
    if blob.id == 0 { public_exception(out, req, 404); return; }
    let raw, has_asked = http::query_of(req.target, "disposition");
    var asked: u8[>..] = [];
    if has_asked { http::decode(raw, asked, true); }
    if blobs {
        let range, has_range = http::field_of(req, "Range");
        if has_range && trim(range).len > 0 { proxy_ranges(req, out, body, blob_file(storage, blob.key), blob); return; }
        let etag = proxy_etag(req);
        let disposition = send_disposition(stream_disposition(blob.content_type, asked, has_asked), sanitized_filename(blob.filename));
        let fresh = proxy_fresh(req, etag);
        if fresh > 0 { proxy_not_modified(out, etag, fresh, true, disposition); return; }
        proxy_stream(req, out, body, blob_file(storage, blob.key), etag, content_type_for_serving(blob.content_type), disposition, true);
        return;
    }
    // set_representation: @blob.representation(params[:variation_key]).processed
    var variant = VariantBlob { .. };
    var v = Variation { .. }; var decoded = false; var invalid = false; var previewable = false;
    let found = sqlite::run() {
        previewable = previewable_content_type(blob.content_type);
        let defaults = if previewable { Variation { format: "jpg", .. } } else { default_variant_format(blob.content_type, blob.filename) };
        let result, verified, bad = decode_variation(variation_token, key, now, defaults);
        v = result; decoded = verified; invalid = bad;
        if decoded && !invalid && previewable {
            let image = find_preview_image(db, blob.id);
            if image.id != 0 { variant = if v.bare { image } else { find_variant(db, image.id, variation_digest(v)) }; }
        } else if decoded && !invalid && variable_content_type(blob.content_type) { variant = find_variant(db, blob.id, variation_digest(v)); }
    };
    if found.len > 0 { public_exception(out, req, 500); return; }
    if !decoded { proxy_head(out, req, 404, false); return; }
    if invalid || !(previewable || variable_content_type(blob.content_type)) { public_exception(out, req, 500); return; }
    let etag = proxy_etag(req);
    if variant.id != 0 {
        let disposition = send_disposition(stream_disposition(variant.content_type, asked, has_asked), sanitized_filename(variant.filename));
        let fresh = proxy_fresh(req, etag);
        if fresh > 0 { proxy_not_modified(out, etag, fresh, false, disposition); return; }
        proxy_stream(req, out, body, blob_file(storage, variant.key), etag, content_type_for_serving(variant.content_type), disposition, false);
        return;
    }
    // Processed (before http_cache_forever, as the before_action does) off the HTTP worker, which
    // answers when the media thread mails.
    guard etag.len <= 96 && asked.len <= 256 else { public_exception(out, req, 500); return; }
    let fresh = proxy_fresh(req, etag);
    if fresh > 0 {
        let job = MediaJob { kind: MEDIA_VARIANT, blob: blob.id, variation: v, .. };
        if !qput(job) { write_stderr(str("Image processing queue is full: blob ", blob.id, " is processed on first request\n")); }
        proxy_not_modified(out, etag, fresh, false, ""); return;
    }
    let job = MediaJob { kind: MEDIA_PROXY, blob: blob.id, variation: v, wait: true, reply: http::later(out, 60000), etag: etag, asked: asked, has_asked: has_asked, .. };
    if !qput(job) { http::respond(out, 503, "text/plain", "Image processing is busy"); }
}

// --- Direct uploads ------------------------------------------------------------------------------


// ActiveStorageAuthentication#require_active_storage_authentication (config/initializers): head
// :unauthorized from a before_action unless the session_token cookie finds a session. False when
// it answered.
fn require_active_storage_authentication(db: sqlite::Db, req: const http::Request&, out: http::Reply) -> bool {
    let raw, has_cookie = http::cookie_of(req, "session_token");
    var found = false;
    if has_cookie {
        var now: u8[>..] = []; campfire_now(now);
        var token: u8[>..] = []; var valid_until: u8[>..] = [];
        if now.len == 24 && verify_cookie(raw, auth_config.cookie_key, now, token, valid_until) {
            let failed = sqlite::run() { found = sql_number(db, "SELECT count(*) FROM sessions WHERE token=?", [sql_text(token)]) > 0; };
            if failed.len > 0 { public_exception(out, req, 500); return false; }
        }
    }
    if !found { respond_head(out, req, 401); }
    return found;
}

// A JSON value as Ruby's to_json writes the Hash it was parsed into.
recursive fn json_text(out: u8[>..]&, n: json::Node?, unprotected: bool = false) {
    guard n else { out.append("null"); return; }
    match n.val {
        Null => { out.append("null"); },
        Bool b => { out.append(if b.v { "true" } else { "false" }); },
        Int i => { format(out, i.v); },
        Num x => { format(out, x.v); },
        Str t => { json::format_string(out, t.s); },
        Arr => {
            out.push('['); var first = true;
            var c = n.first;
            while c { if !first { out.push(','); } first = false; json_text(out, c); c .= c.next; }
            out.push(']');
        },
        Obj => {
            out.push('{'); var first = true;
            var c = n.first;
            while c {
                // Blob.filter_metadata: a hash's PROTECTED_METADATA keys go.
                if !unprotected || (c.key != "analyzed" && c.key != "identified" && c.key != "composed") {
                    if !first { out.push(','); } first = false; json::format_string(out, c.key); out.push(':'); json_text(out, c);
                }
                c .= c.next;
            }
            out.push('}');
        },
    }
}

// What params.expect(blob: [:filename, :byte_size, :checksum, :content_type, metadata: {}]) gives
// create_before_direct_upload!, from a JSON body or a form.
struct DirectBlob {
    present: bool = false,     // blob is a hash
    filename: u8[..1024] = [], has_filename: bool = false,
    checksum: u8[..256] = [], has_checksum: bool = false,
    content_type: u8[..256] = [], has_content_type: bool = false,
    size: i64 = 0, has_size: bool = false,
    metadata: u8[..8192] = [], has_metadata: bool = false,
}

fn direct_blob_params(req: const http::Request&, body: const u8[:]) -> DirectBlob {
    var b = DirectBlob { .. };
    let kind, typed = http::field_of(req, "Content-Type");
    if typed && starts_with(html_lower(kind), "application/json") {
        var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
        let root, error = json::parse(body, nodes, strings);
        let blob = json::member(root, "blob");
        guard blob else { return b; }
        match blob.val { Obj => { b.present = true; }, _ => { return b; } }
        let filename, has_filename = json::as_string(json::member(blob, "filename"));
        if has_filename && filename.len <= 1024 { b.filename = filename; b.has_filename = true; }
        let checksum, has_checksum = json::as_string(json::member(blob, "checksum"));
        if has_checksum && checksum.len <= 256 { b.checksum = checksum; b.has_checksum = true; }
        let content_type, has_content_type = json::as_string(json::member(blob, "content_type"));
        if has_content_type && content_type.len <= 256 { b.content_type = content_type; b.has_content_type = true; }
        let size_node = json::member(blob, "byte_size");
        let n, is_int = json::as_i64(size_node);
        let x, is_number = json::as_f64(size_node);
        let text, is_text = json::as_string(size_node);
        // The integer attribute's cast: a string's to_i.
        if is_int { b.size = n; b.has_size = true; }
        else if is_number { b.size = x as! i64; b.has_size = true; }
        else if is_text { b.size = ruby_to_i(text); b.has_size = true; }
        let metadata = json::member(blob, "metadata");
        if metadata {
            match metadata.val {
                Obj => { var m: u8[>..] = []; json_text(m, metadata, true); if m.len <= 8192 { b.metadata = m; b.has_metadata = true; } },
                _ => {},
            }
        }
        return b;
    }
    var value: u8[>..] = [];
    if form_has_prefix(body, "blob[") { b.present = true; }
    if http::form_value(body, "blob[filename]", value) && value.len <= 1024 { b.filename = value; b.has_filename = true; }
    value.clear(); if http::form_value(body, "blob[checksum]", value) && value.len <= 256 { b.checksum = value; b.has_checksum = true; }
    value.clear(); if http::form_value(body, "blob[content_type]", value) && value.len <= 256 { b.content_type = value; b.has_content_type = true; }
    value.clear(); if http::form_value(body, "blob[byte_size]", value) { b.size = ruby_to_i(value); b.has_size = true; }
    return b;
}

// ActiveStorage::DirectUploadsController#create, behind protect_from_forgery and
// require_active_storage_authentication: the blob, then its JSON with the signed id and the disk
// service's direct-upload URL and headers. A missing filename, byte size or checksum is the
// keyword's ArgumentError (a 500), a blank checksum the validation's RecordInvalid (a 422); a
// missing content type is null in the blob, the token and the upload's headers.
fn direct_uploads_create(db: sqlite::Db, req: const http::Request&, body: const u8[:], key: const u8[:], sgid_key: const u8[:], out: http::Reply) {
    guard same_origin(req) else { public_exception(out, req, 422); return; }
    guard require_active_storage_authentication(db, req, out) else { return; }
    let b = direct_blob_params(req, body);
    guard b.present else { public_exception(out, req, 400); return; }
    guard b.has_filename && b.has_size && b.has_checksum else { public_exception(out, req, 500); return; }
    guard b.checksum.len > 0 else { public_exception(out, req, 422); return; }
    let blob_key = new_blob_key();
    var now: u8[>..] = []; campfire_sql_now(now);
    var id: i64 = 0;
    let failed = write_transaction(db) {
        sql_rows(db, "INSERT INTO active_storage_blobs(key,filename,content_type,metadata,service_name,byte_size,checksum,created_at) VALUES(?,?,iif(?,?,NULL),iif(?,?,NULL),'local',?,?,?)",
            [sql_text(blob_key), sql_text(b.filename), sql_text(if b.has_content_type { 1 } else { 0 }), sql_text(b.content_type),
             sql_text(if b.has_metadata { 1 } else { 0 }), sql_text(b.metadata), sql_text(b.size), sql_text(b.checksum), sql_text(now)]);
        id = sqlite::last_insert_rowid(db);
    };
    if failed.len > 0 { for e in failed { write_stderr(str("direct upload failed: ", e.message, "\n")); } public_exception(out, req, 500); return; }
    var token: u8[>..] = [];
    token.append("{\"key\":"); json::format_string(token, blob_key);
    token.append(",\"content_type\":"); json_string_or_null(token, b.content_type, b.has_content_type);
    format(token, ",\"content_length\":", b.size, ",\"checksum\":"); json::format_string(token, b.checksum);
    token.append(",\"service_name\":\"local\"}");
    var expiry: u8[>..] = []; campfire_after(SERVICE_URLS_EXPIRE_IN, expiry);
    let url = str(request_host(req), "/rails/active_storage/disk/", escape_segment(storage_generate(token, "blob_token", expiry, key)));
    // blob.as_json(root: false, methods: :signed_id), with ActionText::Attachable's attachable_sgid,
    // then direct_upload.
    var text: u8[>..] = [];
    format(text, "{\"id\":", id, ",\"byte_size\":", b.size, ",\"checksum\":"); json::format_string(text, b.checksum);
    text.append(",\"content_type\":"); json_string_or_null(text, b.content_type, b.has_content_type);
    text.append(",\"created_at\":"); json::format_string(text, json_time(now));
    text.append(",\"filename\":"); json::format_string(text, b.filename);
    text.append(",\"key\":"); json::format_string(text, blob_key);
    text.append(",\"metadata\":"); text.append(if b.has_metadata { b.metadata[..] } else { "{}" });
    text.append(",\"service_name\":\"local\",\"attachable_sgid\":"); json::format_string(text, blob_sgid(id, sgid_key));
    text.append(",\"signed_id\":"); json::format_string(text, signed_blob_id(id, key));
    text.append(",\"direct_upload\":{\"url\":"); json::format_string(text, url);
    text.append(",\"headers\":{\"Content-Type\":"); json_string_or_null(text, b.content_type, b.has_content_type); text.append("}}}");
    respond_rack(out, req, 200, "application/json; charset=utf-8", text);
}

fn json_string_or_null(out: u8[>..]&, value: const u8[:], present: bool) {
    if present { json::format_string(out, value); } else { out.append("null"); }
}

// ActiveStorage::DiskController#update, behind require_active_storage_authentication (no forgery
// protection): the token's file, when the request's type and length are the token's, and its MD5
// the checksum. 204; head :not_found for a bad token, :unprocessable_entity otherwise.
fn disk_update(db: sqlite::Db, req: const http::Request&, body: const u8[:], storage: const u8[:], key: const u8[:], out: http::Reply) {
    guard require_active_storage_authentication(db, req, out) else { return; }
    var signed: u8[>..] = []; var unused: u8[>..] = [];
    let path = http::path_of(req.target);
    var data: u8[>..] = [];
    var now: u8[>..] = []; campfire_now(now);
    var encoded: u8[>..] = [];
    let raw = path[27..];
    guard http::decode(raw, encoded, false) && storage_verify(encoded, "blob_token", key, now, data) else { respond_head(out, req, 404, true); return; }
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let root, error = json::parse(data, nodes, strings);
    let file_key, has_key = json::as_string(json::member(root, "key"));
    let checksum, has_checksum = json::as_string(json::member(root, "checksum"));
    let content_type, typed = json::as_string(json::member(root, "content_type"));
    let length, has_length = json::as_i64(json::member(root, "content_length"));
    guard has_key && storage_key_valid(file_key) else { respond_head(out, req, 404, true); return; }
    // token[:content_type] == request.content_mime_type && token[:content_length] == request.content_length
    let kind, has_kind = http::field_of(req, "Content-Type");
    var end: i64 = 0;
    while has_kind && end < kind.len && kind[end] != ';' && kind[end] != ',' { end += 1; }
    let request_type = if has_kind { html_lower(trim(kind[..end])) } else { str("") };
    let same_type = if typed { request_type.len > 0 && request_type == html_lower(content_type) } else { request_type.len == 0 };
    let sent, has_sent = http::field_of(req, "Content-Length");
    let sent_length, numeric = parse_int(trim(sent));
    guard same_type && has_sent && numeric && has_length && sent_length == length else { respond_head(out, req, 422, true); return; }
    // DiskService#upload: ensure_integrity_of the checksum, the file gone if it fails.
    guard !has_checksum || blob_checksum(body) == checksum else { respond_head(out, req, 422, true); return; }
    guard write_blob_file(storage, file_key, body) else { public_exception(out, req, 500); return; }
    respond_head(out, req, 204, true);
}

fn is_direct_upload_path(path: const u8[:]) -> bool {
    return path == "/rails/active_storage/direct_uploads" || path == "/rails/active_storage/direct_uploads.json";
}

// POST /rails/active_storage/direct_uploads and PUT /rails/active_storage/disk/:encoded_token.
fn direct_upload_route(db: sqlite::Db, req: const http::Request&, body: const u8[:], storage: const u8[:], key: const u8[:], sgid_key: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    if req.method == "POST" && is_direct_upload_path(path) { direct_uploads_create(db, req, body, key, sgid_key, out); return true; }
    if req.method == "PUT" && starts_with(path, "/rails/active_storage/disk/") && path.len > 27 && find(path[27..], "/") < 0 {
        disk_update(db, req, body, storage, key, out); return true;
    }
    return false;
}

// blob.attachable_sgid: to_sgid(expires_in: nil, for: "attachable") of
// gid://campfire/ActiveStorage::Blob/<id>, as signed_id.goose's attachable_sgid signs a user's.
fn blob_sgid(id: i64, key: const u8[:]) -> u8[>..] {
    var encoded: u8[>..] = [];
    base64::encode(encoded, str("{\"_rails\":{\"data\":\"gid://campfire/ActiveStorage::Blob/", id, "?expires_in\",\"pur\":\"attachable\"}}"));
    var out: u8[>..] = [];
    for c in encoded { out.push(if c == '+' { '-' } else if c == '/' { '_' } else { c }); }
    let mac = hmac_sha1(key, out);
    out.append("--");
    let digits = "0123456789abcdef";
    for c in mac { out.push(digits[c >> 4]); out.push(digits[c & 15]); }
    return out;
}
