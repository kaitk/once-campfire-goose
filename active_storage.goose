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
    let host, exists = http::field_of(req, "Host");
    return str("http://", if exists { host } else { "localhost" });
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
    // The proxy routes, which Campfire never links, redirect as the redirect routes do.
    if storage_segments(path, "/rails/active_storage/blobs/redirect/", 1, signed, variation_token) || storage_segments(path, "/rails/active_storage/blobs/proxy/", 1, signed, variation_token) ||
       storage_segments(path, "/rails/active_storage/blobs/", 1, signed, variation_token) {
        let id = verify_blob_id(signed, key, now);
        if id == 0 { storage_not_found(out); return true; }
        var blob = StoredBlob { .. };
        let failed = sqlite::run() { blob = stored_blob(db, id); };
        if failed.len > 0 { http::respond(out, 500, "text/plain", "Database error"); return true; }
        if blob.id == 0 { http::respond(out, 404, "text/plain", "Not found"); return true; }
        let disposition = disposition_for_serving(blob.content_type, disposition_param(req));
        let location = str(request_host(req), disk_path(blob.key, blob.filename, content_type_for_serving(blob.content_type), disposition, key));
        storage_redirect(out, location);
        return true;
    }
    if storage_segments(path, "/rails/active_storage/representations/redirect/", 2, signed, variation_token) ||
       storage_segments(path, "/rails/active_storage/representations/proxy/", 2, signed, variation_token) ||
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
        if failed.len > 0 { http::respond(out, 500, "text/plain", "Database error"); return true; }
        if blob.id == 0 { http::respond(out, 404, "text/plain", "Not found"); return true; }
        if !decoded { storage_not_found(out); return true; }
        // Neither previewable nor variable: UnrepresentableError (a video too while ffmpeg is missing).
        if invalid || !(previewable || variable_content_type(blob.content_type)) {
            http::respond(out, 500, "text/plain", "This blob can't be represented"); return true;
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
        http::respond(out, 404, "text/plain", ""); return;
    }
    let f, status = http::open_file(blob_file(storage, file_key));
    if status != 200 { http::respond(out, 404, "text/plain", ""); return; }
    let tag = http::file_tag(f);
    body.fd = f.fd; body.off = 0; body.left = 0;
    if content_type.len == 0 { content_type.append(BINARY_CONTENT_TYPE); }
    if http::not_modified(req, tag, f.modified) {
        http::start(out, 304); http::file_fields(out, f, tag); http::field(out, "Cache-Control", "max-age=3600, public");
        http::finish(out, "", ""); http::close_body(body); return;
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
    http::file_fields(out, f, tag);
    body.off = a; body.left = e - a;
    if out.head || body.left == 0 { http::end(out); http::close_body(body); }
}
