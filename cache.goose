namespace campfire;

import std;
import http;
import http.compression;
import compress;

struct CachedPage {
    user: i64 = 0,
    target_start: i64 = 0,
    fields_start: i64 = 0,
    extra_start: i64 = 0,
    plain_start: i64 = 0,
    gzip_start: i64 = 0,
    end: i64 = 0,
    coding: http::Coding = http::Coding.Identity,
}

struct CacheState {
    version: i64 = -1,
    enabled: bool = true,
    diagnostics: bool = false,
    byte_limit: i64 = 16 * 1024 * 1024,
    count: i64 = 0,
    used: i64 = 0,
    auth_user: i64 = 0,
    auth_cookie: u8[..8192] = [],
    auth_expiry: u8[..24] = [],
    // A session whose hourly resume is due; request writes it after the read snapshot ends.
    resume_session: i64 = 0,
}

fn clear_cache(state: CacheState&) {
    state.count = 0;
    state.used = 0;
    state.auth_user = 0;
}

fn find_page(entries: const CachedPage[:], bytes: const u8[:], state: const CacheState&, user: i64, target: const u8[:], fields: const u8[:] = "") -> i64 {
    for i in state.count {
        let entry = entries[i];
        if entry.user == user && bytes[entry.target_start..entry.fields_start] == target &&
           bytes[entry.fields_start..entry.plain_start] == fields { return i; }
    }
    return -1;
}

// Storage grows to its high-water mark within byte_limit and is reused across
// generations. Entries contain offsets, so growth cannot invalidate their locations.
fn store_page(entries: CachedPage[:], bytes: u8[>..]&, state: CacheState&, user: i64,
              target: const u8[:], plain: const u8[:], packed: const u8[:], fields: const u8[:] = "",
              coding: http::Coding = http::Coding.Identity, extra: const u8[:] = "") {
    let size = target.len + fields.len + extra.len + plain.len + packed.len;
    if entries.len == 0 || size > 1024 * 1024 || size > state.byte_limit || target.len > 2048 || fields.len > 16384 { return; }
    if state.count >= entries.len || state.used + size > state.byte_limit { clear_cache(state); }
    let start = state.used;
    let fields_start = start + target.len;
    let extra_start = fields_start + fields.len;
    let plain_start = extra_start + extra.len;
    let gzip_start = plain_start + plain.len;
    let end = gzip_start + packed.len;
    for i in max(0, end - bytes.len) { bytes.push(0); }
    copy_into(bytes[start..fields_start], target);
    copy_into(bytes[fields_start..extra_start], fields);
    copy_into(bytes[extra_start..plain_start], extra);
    copy_into(bytes[plain_start..gzip_start], plain);
    copy_into(bytes[gzip_start..end], packed);
    entries[state.count] = CachedPage { user: user, target_start: start, fields_start: fields_start, extra_start: extra_start, plain_start: plain_start,
                                       gzip_start: gzip_start, end: end, coding: coding };
    state.count += 1;
    state.used = end;
}

// Header lines, `Name: value` each and newline-separated, as fields of the response.
fn header_lines(out: http::Reply, extra: const u8[:]) {
    for line in split(extra, '\n') {
        let colon = find(line, ": ");
        if colon > 0 { http::field(out, line[..colon], line[colon + 2..]); }
    }
}

// http::respond_compressed for an HTML page, with extra header lines.
fn respond_html(out: http::Reply, req: const http::Request&, status: i32, body: const u8[:], extra: const u8[:]) {
    http::start(out, status);
    header_lines(out, extra);
    http::field(out, "Content-Type", "text/html; charset=utf-8");
    http::field(out, "Vary", "Accept-Encoding");
    let c = http::Compression { .. };
    let coding = if out.head || out.stream.bodyless || body.len < c.min_size { http::Coding.Identity } else { http::coding_for(req, c) };
    if coding == http::Coding.Identity { http::finish(out, http::NO_TYPE, body); return; }
    out.buf.append(http::coding_field(coding));
    var compressed: u8[>..] = [];
    http::compress_whole(body, compressed, coding, c);
    http::finish(out, http::NO_TYPE, compressed);
}

fn send_page(out: http::Reply, req: const http::Request&, plain: const u8[:], gzip: const u8[:],
             accepted: http::Coding, diagnostics: bool, hit: bool, snapshot: bool = false, extra: const u8[:] = "") {
    let coding = if out.head { http::Coding.Identity } else { accepted };
    if coding == http::Coding.Deflate || coding == http::Coding.Zstd {
        if extra.len == 0 { http::respond_compressed(out, req, 200, "text/html; charset=utf-8", plain); }
        else { respond_html(out, req, 200, plain, extra); }
        return;
    }
    http::start(out, 200);
    header_lines(out, extra);
    http::field(out, "Content-Type", "text/html; charset=utf-8");
    http::field(out, "Vary", "Accept-Encoding");
    if diagnostics {
        http::field(out, "X-Campfire-Cache", if hit { "hit" } else { "miss" });
        http::field(out, "X-Campfire-Snapshot", if snapshot { "wal" } else { "transaction" });
    }
    if coding == http::Coding.Gzip {
        http::field(out, "Content-Encoding", "gzip");
        http::finish(out, http::NO_TYPE, gzip);
    } else {
        http::finish(out, http::NO_TYPE, plain);
    }
}

fn cached_page(entries: const CachedPage[:], bytes: const u8[:], state: const CacheState&, user: i64, req: const http::Request&, out: http::Reply, snapshot: bool = false) -> bool {
    if !state.enabled { return false; }
    let index = find_page(entries, bytes, state, user, req.target, req.fields);
    if index < 0 { return false; }
    let entry = entries[index];
    send_page(out, req, bytes[entry.plain_start..entry.gzip_start], bytes[entry.gzip_start..entry.end], entry.coding, state.diagnostics, true, snapshot, bytes[entry.extra_start..entry.plain_start]);
    return true;
}

fn cache_page(entries: CachedPage[:], bytes: u8[>..]&, state: CacheState&,
              user: i64, req: const http::Request&, body: const u8[:], out: http::Reply, extra: const u8[:] = "") {
    if !state.enabled {
        respond_html(out, req, 200, body, extra);
        return;
    }
    var packed: u8[>..] = [];
    if body.len >= 1024 {
        var encoder = compress::encoder(compress::GZIP, 6);
        compress::write(encoder, body, packed);
        compress::finish(encoder, packed);
    }
    // Exact header bytes are part of the cache key, so negotiation is stable on a hit.
    let coding = if body.len < 1024 { http::Coding.Identity } else { http::coding_for(req, http::Compression { .. }) };
    send_page(out, req, body, packed, coding, state.diagnostics, false, false, extra);
    store_page(entries, bytes, state, user, req.target, body, packed, req.fields, coding, extra);
}
