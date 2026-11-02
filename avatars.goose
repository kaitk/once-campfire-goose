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

fn initials_avatar(out: u8[>..]&, id: i64, name: const u8[:], bot: bool) {
    out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 512 512\"><rect width=\"512\" height=\"512\" rx=\"50\" fill=\"");
    out.append(avatar_color(id));
    out.append("\"/>");
    if bot {
        out.append("<rect x=\"116\" y=\"146\" width=\"280\" height=\"220\" rx=\"40\" fill=\"white\"/><path d=\"M256 146V90\" stroke=\"white\" stroke-width=\"20\"/><circle cx=\"256\" cy=\"80\" r=\"22\" fill=\"white\"/><circle cx=\"198\" cy=\"230\" r=\"24\"/><circle cx=\"314\" cy=\"230\" r=\"24\"/><path d=\"M190 308H322\" stroke=\"black\" stroke-width=\"18\"/>");
    } else {
        var initials: u8[>..] = [];
        var in_word = false;
        var i: i64 = 0;
        while i < name.len {
            let c = name[i];
            let word = html_word(c) || c >= 128;
            if word && !in_word {
                var width: i64 = if c < 128 { 1 } else if c < 224 { 2 } else if c < 240 { 3 } else { 4 };
                width = min(width, name.len - i);
                initials.append(name[i..i + width]);
            }
            in_word = word;
            i += 1;
        }
        out.append("<text x=\"50%\" y=\"50%\" fill=\"white\" text-anchor=\"middle\" dy=\".35em\" font-family=\"sans-serif\" font-size=\"230\" font-weight=\"800\"");
        if initials.len >= 3 { out.append(" textLength=\"85%\" lengthAdjust=\"spacingAndGlyphs\""); }
        out.push('>'); escape(out, initials); out.append("</text>");
    }
    out.append("</svg>");
}

// User::Avatar's :square variant: resize_to_limit: [512, 512], format: :webp.
fn avatar_variation() -> Variation { return named_variation("webp", 512, 512); }

// Users::AvatarsController#show for user id: the :square variant, else the initials or a bot's
// icon, 304 when previous is the entity tag. Returns the avatar blob whose variant isn't made yet,
// for a media thread, or 0; with fallback, such an avatar gets the initials instead.
fn avatar_answer(db: sqlite::Db, id: i64, previous: const u8[:], storage: const u8[:], fallback: bool, answer: MediaAnswer&) -> i64 {
    var q = sqlite::Stmt {};
    var pending: i64 = 0;
    answer.status = 404; answer.content_type = "image/svg+xml";
    let failed = sqlite::run() {
        // Active Storage's digest for resize_to_limit: [512, 512], format: :webp.
        q = sqlite::prepare(db, "SELECT u.name,u.role,u.updated_at,b.key,b.byte_size,a.id FROM users u LEFT JOIN active_storage_attachments a ON a.record_type='User' AND a.name='avatar' AND a.record_id=u.id LEFT JOIN active_storage_variant_records v ON v.blob_id=a.blob_id AND v.variation_digest='6gwfjNKv9eUy9jNUtEZvQFLU0hQ=' LEFT JOIN active_storage_attachments va ON va.record_type='ActiveStorage::VariantRecord' AND va.name='image' AND va.record_id=v.id LEFT JOIN active_storage_blobs b ON b.id=va.blob_id AND b.content_type='image/webp' WHERE u.id=?");
        sqlite::bind_i64(q, 1, id);
        if sqlite::step(q) {
            var name: u8[>..] = []; sqlite::column_text(q, 0, name);
            var updated: u8[>..] = []; sqlite::column_text(q, 2, updated);
            var file_key: u8[>..] = []; sqlite::column_text(q, 3, file_key);
            let attachment = sqlite::column_i64(q, 5);
            if file_key.len > 0 { answer.content_type = "image/webp"; }
            let digest = hash::sha256(str(id, ":", updated, ":", file_key));
            let digits = "0123456789abcdef";
            var etag: u8[>..] = []; etag.push('"');
            for c in digest { etag.push(digits[c >> 4]); etag.push(digits[c & 15]); }
            etag.push('"');
            answer.etag = etag;
            if file_key.len == 0 && attachment != 0 && !fallback {
                // User#avatar_variant: processed when the avatar is variable, the initials otherwise.
                for row in sql_rows(db, "SELECT b.id,coalesce(b.content_type,'') FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.id=?", [sql_text(attachment)]) {
                    let blob, valid = parse_int(cell(row, 0));
                    if valid && variable_content_type(cell(row, 1)) { pending = blob; }
                }
            }
            if pending != 0 {}
            else if previous.len > 0 && previous == etag { answer.status = 304; }
            else if file_key.len > 0 {
                let size = sqlite::column_i64(q, 4);
                if storage_key_valid(file_key) && size > 0 && size <= 8 * 1024 * 1024 &&
                   read_file(str(storage, "/", file_key[..2], "/", file_key[2..4], "/", file_key), answer.body) && answer.body.len == size {
                    answer.status = 200;
                } else { answer.status = 500; }
            } else {
                initials_avatar(answer.body, id, name, sqlite::column_i64(q, 1) == 2);
                answer.status = 200;
            }
        }
    };
    sqlite::finalize(q);
    if failed.len > 0 { answer.status = 500; pending = 0; }
    answer.cache = "public, max-age=1800, stale-while-revalidate=604800";
    answer.nosniff = true;
    if answer.status == 304 { answer.body.clear(); }
    return pending;
}

fn avatar(db: sqlite::Db, req: const http::Request&, token: const u8[:], key: const u8[:],
          storage: const u8[:], now: const u8[:], out: http::Reply) {
    let id = verify_id(token, "user/avatar", key, now);
    if id <= 0 { http::respond(out, 404, "text/plain", "Not found"); return; }
    let previous, has_previous = http::field_of(req, "If-None-Match");
    var answer = MediaAnswer { .. };
    let pending = avatar_answer(db, id, previous, storage, false, answer);
    if pending > 0 {
        if qput(MediaJob { kind: MEDIA_AVATAR, blob: pending, record: id, wait: true, reply: http::later(out, 60000), .. }) { return; }
        answer = MediaAnswer { .. };
        let fallback = avatar_answer(db, id, previous, storage, true, answer);
    }
    send_answer(out, answer);
}

// Users::AvatarsController#destroy: Current.user.avatar.destroy, whatever user the path names; the
// attachment touches the user, and its blob and variants are purged.
fn destroy_avatar(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], storage: const u8[:], out: http::Reply) {
    var method = str(req.method);
    if method == "POST" {
        var override: u8[>..] = [];
        if http::form_value(body, "_method", override) && html_lower(override) == "delete" { method = str("DELETE"); }
    }
    guard method == "DELETE" else { http::respond(out, 404, "text/plain", "Not found"); return; }
    guard same_origin(req) else { http::respond(out, 422, "text/plain", "Invalid origin"); return; }
    var keys: u8[][>..] = [];
    campfire_writer_enter();
    let failed = sqlite::run() {
        sqlite::exec(db, "BEGIN IMMEDIATE");
        if sql_number(db, "SELECT count(*) FROM active_storage_attachments WHERE record_type='User' AND name='avatar' AND record_id=?", [sql_text(user)]) > 0 {
            purge_attachments(db, "record_type='User' AND name='avatar' AND record_id=?", [sql_text(user)], keys);
            var now: u8[>..] = []; campfire_sql_now(now);
            sql_rows(db, "UPDATE users SET updated_at=? WHERE id=?", [sql_text(now), sql_text(user)]);
        }
        sqlite::exec(db, "COMMIT");
    };
    let cleanup = sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db, "ROLLBACK"); } };
    campfire_writer_leave();
    if failed.len > 0 {
        for e in failed { write_stderr(str(e.message, "\n")); }
        http::respond(out, 500, "text/plain", "Unable to complete request");
        return;
    }
    delete_blob_files(storage, keys);
    http::start(out, 302); http::field(out, "Location", "/users/me/profile"); http::finish(out, http::TEXT, "Redirecting");
}
