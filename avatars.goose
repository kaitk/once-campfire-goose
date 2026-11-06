namespace campfire;

import std;
import os;
import sqlite;
import http;
import hash;
import html;
import signed_id;
import database;
import storage;
import media;
import messages;
import sessions;
import admin_routes;
import route_support;
import public_pages;
import csp;
import search;
import view_assets_generated;
import shutdown;

fn avatar_path(id: i64, key: const u8[:]) -> u8[>..] {
    return str("/users/", sign_id(id, "user/avatar", key), "/avatar");
}

fn storage_key_valid(key: const u8[:]) -> bool {
    guard key.len >= 4 && key.len <= 128 else { return false; }
    for c in key {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) { return false; }
    }
    return true;
}

fn avatar_color(id: i64) -> const u8[:] {
    var crc: u32 = 0xffffffff;
    for c in str(id) {
        crc ^= c;
        for bit in 8 { crc = (crc >> 1) ^ (if crc & 1 != 0 { 0xedb88320 as u32 } else { 0 as u32 }); }
    }
    let colors = "#AF2E1B#CC6324#3B4B59#BFA07A#ED8008#ED3F1C#BF1B1B#736B1E#D07B53#736356#AD1D1D#BF7C2A#C09C6F#698F9C#7C956B#5D618F#3B3633#67695E";
    let at = ((crc ^ 0xffffffff) % 18) as i64 * 7;
    return colors[at..at + 7];
}

// User#initials, name.scan(/\b\w/).join: Ruby's \w is ASCII, but its \b takes any Unicode word
// character (Letter, Mark, Decimal_Number, Connector_Punctuation) as one, so "Émile" gives none.
fn user_initials(name: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    var previous_word = false;
    var i: i64 = 0;
    while i < name.len {
        let first = name[i];
        var c: u32 = first; var extra: i64 = 0;
        if first >= 240 && first < 248 { c = first & 7; extra = 3; }
        else if first >= 224 && first < 240 { c = first & 15; extra = 2; }
        else if first >= 192 && first < 224 { c = first & 31; extra = 1; }
        var valid = first < 128 || extra > 0 && i + extra < name.len;
        if valid { for j in extra { let next = name[i + 1 + j]; if next & 192 != 128 { valid = false; } else { c = (c << 6) | (next & 63); } } }
        if !valid { previous_word = false; i += 1; continue; }
        let word = query_word(c);
        if first < 128 && word && !previous_word { out.push(first); }
        previous_word = word;
        i += 1 + extra;
    }
    return out;
}

// users/avatars/show.svg.erb for user id, named name.
fn initials_avatar(out: u8[>..]&, id: i64, name: const u8[:]) {
    let initials = user_initials(name);
    out.append("<svg version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"\n  viewBox=\"0 0 512 512\" class=\"avatar\" aria-hidden=\"true\">\n  <defs>\n    <clipPath id=\"porthole\">\n      <circle cx=\"50%\" cy=\"50%\" r=\"50%\" />\n    </clipPath>\n  </defs>\n\n  <g>\n    <rect width=\"100%\" height=\"100%\" rx=\"50\" fill=\"");
    out.append(avatar_color(id));
    out.append("\" />\n\n    <text x=\"50%\" y=\"50%\" fill=\"#FFFFFF\"\n      text-anchor=\"middle\" dy=\"0.35em\"\n      ");
    if initials.len >= 3 { out.append("textLength=\"85%\" lengthAdjust=\"spacingAndGlyphs\""); }
    out.append("\n      font-family=\"-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif\"\n      font-size=\"230\"\n      font-weight=\"800\"\n      letter-spacing=\"-5\">\n      ");
    escape(out, initials);
    out.append("\n    </text>\n  </g>\n</svg>\n");
}

// A record's cache_key_with_version, "table/id-updated_at.utc.to_fs(:usec)", of a stored time.
fn cache_key_with_version(table: const u8[:], id: i64, updated: const u8[:]) -> u8[>..] {
    var out = str(table, "/", id, "-");
    for c in updated[..min(19, updated.len)] { if c >= '0' && c <= '9' { out.push(c); } }
    var digits: i64 = 0;
    if updated.len > 20 && updated[19] == '.' { for c in updated[20..] { if digits < 6 && c >= '0' && c <= '9' { out.push(c); digits += 1; } } }
    while digits < 6 { out.push('0'); digits += 1; }
    return out;
}

// fresh_when's weak ETag of validators already expanded to a cache key:
// W/"#{ActiveSupport::Digest.hexdigest(key)}", the first 32 hex digits of its SHA-256.
fn weak_etag(key: const u8[:]) -> u8[>..] {
    let digest = hash::sha256(key);
    let digits = "0123456789abcdef";
    var etag = str("W/\"");
    for c in digest[..16] { etag.push(digits[c >> 4]); etag.push(digits[c & 15]); }
    etag.push('"');
    return etag;
}

// The etaggers' parts after a controller's own validator, as cache-key segments: turbo-rails'
// :frame for a Turbo-Frame request, then EtagWithTemplateDigest's digest of the action's template
// where its lookup finds one (template_digest, for formats that find it).
fn etagger_suffix(req: const http::Request&, template_digest: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    let frame, framed = http::field_of(req, "Turbo-Frame");
    if framed { out.append("/frame"); }
    if template_digest.len > 0 { out.push('/'); out.append(template_digest); }
    return out;
}

// ActionView::Digestor's digest of users/avatars/show.svg.erb (it renders nothing else), which
// EtagWithTemplateDigest adds when the request's formats find the template: */* or svg among
// them, or no registered format at all.
let AVATAR_TEMPLATE_DIGEST = "d500db55e2a67222018ef0156839c3c9";

fn avatar_etag_suffix(req: const http::Request&) -> u8[>..] {
    let chosen = request_format(req);
    let found = chosen == FORMAT_ALL || chosen == FORMAT_NONE || format_symbol(chosen) == "svg";
    return etagger_suffix(req, if found { AVATAR_TEMPLATE_DIGEST } else { "" });
}

// request.fresh?(response) for an ETag alone: an If-None-Match listing it (or *). Without one, an
// If-Modified-Since is never satisfied, as there's no Last-Modified; with one, it isn't read.
fn etag_fresh(none_match: const u8[:], since: bool, etag: const u8[:]) -> bool {
    guard none_match.len > 0 else { return false; }
    for tag in split(none_match, ',') { if trim(tag) == etag || trim(tag) == "*" { return true; } }
    return false;
}

// An avatar's user, its attachment, and its :square variant's blob, by the user's id (Active
// Storage's digest for resize_to_limit: [512, 512], format: :webp).
let AVATAR_SQL = "SELECT u.name,u.role,u.updated_at,b.key,b.byte_size,a.id FROM users u LEFT JOIN active_storage_attachments a ON a.record_type='User' AND a.name='avatar' AND a.record_id=u.id LEFT JOIN active_storage_variant_records v ON v.blob_id=a.blob_id AND v.variation_digest='6gwfjNKv9eUy9jNUtEZvQFLU0hQ=' LEFT JOIN active_storage_attachments va ON va.record_type='ActiveStorage::VariantRecord' AND va.name='image' AND va.record_id=v.id LEFT JOIN active_storage_blobs b ON b.id=va.blob_id AND b.content_type='image/webp' WHERE u.id=?";

// User::Avatar's :square variant: resize_to_limit: [512, 512], format: :webp.
fn avatar_variation() -> Variation { return named_variation("webp", 512, 512); }

// Users::AvatarsController#show for user id, an ActionController::Live controller's: stale?(etag:
// @user) (with the etaggers' suffix), then expires_in 30.minutes, public: true,
// stale_while_revalidate: 1.week, and send_file of the :square variant or the default bot avatar,
// or the initials rendered; 304 when none_match holds the ETag (and since, an If-Modified-Since,
// is absent). A missing user is ActiveRecord::RecordNotFound's 404. Returns the avatar blob whose
// variant isn't made yet, for a media thread, or 0; with fallback, such an avatar gets the
// initials instead. query is the worker's prepared AVATAR_SQL (WriterStatements), or 0 for none.
fn avatar_answer(db: sqlite::Db, query: sqlite::Stmt, id: i64, none_match: const u8[:], since: bool, suffix: const u8[:], storage: const u8[:], fallback: bool, answer: MediaAnswer&) -> i64 {
    var q = sqlite::Stmt {};
    var pending: i64 = 0;
    answer.status = 404;
    let failed = sqlite::run() {
        q = if query.id != 0 { query } else { sqlite::prepare(db, AVATAR_SQL) };
        sqlite::bind_i64(q, 1, id);
        if sqlite::step(q) {
            var name: u8[>..] = []; sqlite::column_text(q, 0, name);
            var updated: u8[>..] = []; sqlite::column_text(q, 2, updated);
            var file_key: u8[>..] = []; sqlite::column_text(q, 3, file_key);
            let attachment = sqlite::column_i64(q, 5);
            let etag = weak_etag(str(cache_key_with_version("users", id, updated), suffix));
            answer.etag = etag;
            answer.cache = "max-age=1800, public, stale-while-revalidate=604800";
            let fresh = etag_fresh(none_match, since, etag);
            if file_key.len == 0 && attachment != 0 && !fallback && !fresh {
                // User#avatar_variant: processed when the avatar is variable, the initials otherwise.
                for row in sql_rows(db, "SELECT b.id,coalesce(b.content_type,'') FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.id=?", [sql_text(attachment)]) {
                    let blob, valid = parse_int(cell(row, 0));
                    if valid && variable_content_type(cell(row, 1)) { pending = blob; }
                }
            }
            // The 304 has the 200's disposition, as Thruster's cache answers it.
            if pending != 0 {}
            else if file_key.len > 0 {
                // send_file ActiveStorage::Blob.service.path_for(key), content_type: "image/webp", disposition: :inline
                answer.disposition = content_disposition("inline", file_key); answer.binary = true; answer.content_type = "image/webp";
                let size = sqlite::column_i64(q, 4);
                if fresh { answer.status = 304; }
                else if storage_key_valid(file_key) && size > 0 && size <= 8 * 1024 * 1024 &&
                   read_file(str(storage, "/", file_key[..2], "/", file_key[2..4], "/", file_key), answer.body) && answer.body.len == size {
                    answer.status = 200;
                } else { answer.status = 500; }
            } else if sqlite::column_i64(q, 1) == 2 {
                // send_file Rails.root.join("app/assets/images/default-bot-avatar.svg"), content_type: "image/svg+xml", disposition: :inline
                answer.disposition = content_disposition("inline", "default-bot-avatar.svg"); answer.binary = true; answer.content_type = "image/svg+xml";
                let index = asset_logical_index("default-bot-avatar.svg");
                if fresh { answer.status = 304; }
                else if index >= 0 && read_file(str("assets/reference/", asset_filename(index)), answer.body) { answer.status = 200; }
                else { answer.status = 500; }
            } else {
                // render formats: :svg, streamed by the Live response
                answer.content_type = "image/svg+xml; charset=utf-8"; answer.streamed = true;
                if fresh { answer.status = 304; }
                else { initials_avatar(answer.body, id, name); answer.status = 200; }
            }
        }
    };
    if query.id != 0 { sqlite::reset(query); } else { sqlite::finalize(q); }
    if failed.len > 0 { answer.status = 500; pending = 0; }
    // head :not_modified comes before expires_in; Thruster's cache answers with the 200's fields.
    if answer.status == 304 { answer.body.clear(); answer.streamed = false; }
    answer.versioned = true;
    if answer.status != 200 && answer.status != 304 { answer.body.clear(); }
    return pending;
}

// True for an answer made now, a 200 or 304, that follows from the request and the database alone:
// one the page cache may keep (store_reply) until the database changes. A token with an expiry
// (Rails' avatar_token has none) depends on the time too.
fn avatar(db: sqlite::Db, query: sqlite::Stmt, req: const http::Request&, token: const u8[:], key: const u8[:],
          storage: const u8[:], now: const u8[:], out: http::Reply) -> bool {
    var expires = false;
    let id = verify_expiring_id(token, "user/avatar", key, now, expires);
    // rescue_from(ActiveSupport::MessageVerifier::InvalidSignature) { head :not_found }
    // rescue_from InvalidSignature: no after_action runs.
    if id <= 0 { rails_halted(); respond_head(out, req, 404, true, true); return false; }
    let none_match, has_none_match = http::field_of(req, "If-None-Match");
    let since_value, since = http::field_of(req, "If-Modified-Since");
    let suffix = avatar_etag_suffix(req);
    var answer = MediaAnswer { .. };
    let pending = avatar_answer(db, query, id, none_match, since, suffix, storage, false, answer);
    if pending > 0 {
        if suffix.len <= 96 && queue_job(JOBS_MEDIA, MediaJob { kind: MEDIA_AVATAR, blob: pending, record: id, wait: true, reply: http::later(out, 60000), etag: suffix, .. }) { return false; }
        answer = MediaAnswer { .. };
        let fallback = avatar_answer(db, query, id, none_match, since, suffix, storage, true, answer);
    }
    if answer.status != 200 && answer.status != 304 { public_exception(out, req, answer.status); return false; }
    send_answer(out, answer);
    // The initials' fallback stands in for a variant still to be made: not kept.
    return pending == 0 && !expires;
}

// Users::AvatarsController#destroy: Current.user.avatar.destroy, whatever user the path names; the
// attachment touches the user, and its blob and variants are purged.
fn destroy_avatar(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], storage: const u8[:], out: http::Reply) {
    guard effective_method(req, body) == "DELETE" else { routing_error(out, req); return; }
    guard same_origin(req) else { public_exception(out, req, 422); return; }
    var keys: u8[][>..] = [];
    let failed = write_transaction(db) {
        if sql_number(db, "SELECT count(*) FROM active_storage_attachments WHERE record_type='User' AND name='avatar' AND record_id=?", [sql_text(user)]) > 0 {
            purge_attachments(db, "record_type='User' AND name='avatar' AND record_id=?", [sql_text(user)], keys);
            var now: u8[>..] = []; campfire_sql_now(now);
            sql_rows(db, "UPDATE users SET updated_at=? WHERE id=?", [sql_text(now), sql_text(user)]);
        }
    };
    if failed.len > 0 {
        for e in failed { write_stderr(str(e.message, "\n")); }
        public_exception(out, req, 500);
        return;
    }
    delete_blob_files(storage, keys);
    redirect_found(out, str(site_base(req), "/users/me/profile"));
}
