namespace campfire;

import std;
import http;
import http.compression;
import compress;
import etag;
import csp;

struct CachedPage {
    user: i64 = 0,
    target_start: i64 = 0,
    fields_start: i64 = 0,
    extra_start: i64 = 0,
    plain_start: i64 = 0,
    gzip_start: i64 = 0,
    end: i64 = 0,
    // The identity body's length, which HEAD sends: a gzip entry keeps no identity body.
    length: i64 = 0,
    coding: http::Coding = http::Coding.Identity,
    // Rack::ConditionalGet's 304, for the validators of the request it was stored for.
    not_modified: bool = false,
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
    // The cached sign-in's push_subscription_session_marker.
    auth_marker: u8[..64] = [],
    // A session whose hourly resume is due; request writes it after the read snapshot ends.
    resume_session: i64 = 0,
    // Its token, whose session_token cookie is signed again with the resume (sessions.goose).
    resume_token: u8[..256] = [],
    // Whether the page cache answered the request, Rack::ETag and Rack::ConditionalGet included (etag.goose).
    rack_done: bool = false,
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
           bytes[entry.fields_start..entry.extra_start] == fields { return i; }
    }
    return -1;
}

// Storage grows to its high-water mark within byte_limit and is reused across
// generations. Entries contain offsets, so growth cannot invalidate their locations.
// length is the identity body's, plain's own unless only the gzip body is kept.
fn store_page(entries: CachedPage[:], bytes: u8[>..]&, state: CacheState&, user: i64,
              target: const u8[:], plain: const u8[:], packed: const u8[:], fields: const u8[:] = "",
              coding: http::Coding = http::Coding.Identity, extra: const u8[:] = "", not_modified: bool = false,
              length: i64 = -1) {
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
                                       gzip_start: gzip_start, end: end, length: if length < 0 { plain.len } else { length },
                                       coding: coding, not_modified: not_modified };
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

// http::respond_compressed for an HTML page, with extra header lines and Rack::ETag's.
fn respond_html(out: http::Reply, req: const http::Request&, status: i32, body: const u8[:], extra: const u8[:]) {
    respond_typed(out, req, status, "text/html; charset=utf-8", body, wire_fields(extra));
}

// Rack::ConditionalGet's 304 for a page with wire, its field lines (Vary among them): no
// Content-Type or body.
fn send_not_modified(out: http::Reply, wire: const u8[:]) {
    http::start(out, 304);
    out.buf.append(wire);
    http::finish(out, http::NO_TYPE, "");
}

// A page, with wire, its field lines (the ETag, the policy and Vary among them), as they are.
// length is the identity body's, which a HEAD sends without plain, as a gzip entry keeps none.
fn send_page(out: http::Reply, req: const http::Request&, plain: const u8[:], gzip: const u8[:], length: i64,
             accepted: http::Coding, diagnostics: bool, hit: bool, snapshot: bool = false, wire: const u8[:] = "") {
    let coding = if out.head { http::Coding.Identity } else { accepted };
    if coding == http::Coding.Deflate || coding == http::Coding.Zstd {
        respond_typed(out, req, 200, "text/html; charset=utf-8", plain, wire);
        return;
    }
    http::start(out, 200);
    out.buf.append(wire);
    http::field(out, "Content-Type", "text/html; charset=utf-8");
    if diagnostics {
        http::field(out, "X-Campfire-Cache", if hit { "hit" } else { "miss" });
        http::field(out, "X-Campfire-Snapshot", if snapshot { "wal" } else { "transaction" });
    }
    if coding == http::Coding.Gzip {
        http::field(out, "Content-Encoding", "gzip");
        http::finish(out, http::NO_TYPE, gzip);
    } else if out.head {
        // http::finish's fields for a HEAD, from the length alone.
        out.buf.append(http::NO_TYPE);
        format(out.buf, length);
        out.buf.append("\r\n\r\n");
    } else {
        http::finish(out, http::NO_TYPE, plain);
    }
}

fn cached_page(entries: const CachedPage[:], bytes: const u8[:], state: CacheState&, user: i64, req: const http::Request&, out: http::Reply, snapshot: bool = false) -> bool {
    if !state.enabled { return false; }
    let index = find_page(entries, bytes, state, user, req.target, req.fields);
    if index < 0 { return false; }
    let entry = entries[index];
    state.rack_done = true;
    if entry.not_modified { send_not_modified(out, bytes[entry.extra_start..entry.plain_start]); return true; }
    send_page(out, req, bytes[entry.plain_start..entry.gzip_start], bytes[entry.gzip_start..entry.end], entry.length, entry.coding,
              state.diagnostics, true, snapshot, bytes[entry.extra_start..entry.plain_start]);
    return true;
}

// A page answered and stored, with extra header lines and Rack::ETag's (its ETag is taken once,
// here, and replayed on hits) as its field lines, or Rack::ConditionalGet's 304 for the request's
// validators. The policy and Vary (csp.goose) follow the request's Host and Accept, which are part
// of the key.
fn cache_page(entries: CachedPage[:], bytes: u8[>..]&, state: CacheState&,
              user: i64, req: const http::Request&, body: const u8[:], out: http::Reply, extra: const u8[:] = "") {
    if !state.enabled {
        respond_html(out, req, 200, body, extra);
        return;
    }
    var wire = wire_fields(extra);
    wire.append(rack_etag_wire(200, body, wire));
    let framing, framed = field_line(wire, "X-Frame-Options");
    if !framed { wire.append(DEFAULT_HEADERS); }
    let tag, tagged = field_line(wire, "ETag");
    let modified, dated = field_line(wire, "Last-Modified");
    let fresh = rack_fresh(req, tag, modified);
    wire.append(rails_fields(if fresh { 304 } else { 200 }, true, true, "", false));
    state.rack_done = true;
    // Exact header bytes are part of the cache key, so negotiation and freshness are stable on a hit.
    if fresh {
        send_not_modified(out, wire);
        store_page(entries, bytes, state, user, req.target, "", "", req.fields, http::Coding.Identity, wire, true);
        return;
    }
    // An entry answers only its exact header bytes, so it only ever sends its negotiated coding, or
    // a HEAD's identity length: it keeps the gzip body for gzip, and the plain body otherwise.
    let coding = if body.len < 1024 { http::Coding.Identity } else { http::coding_for(req, http::Compression { .. }) };
    let gzipped = coding == http::Coding.Gzip;
    var packed: u8[>..] = [];
    // The worker's one-shot encoder, reset in place: a new compress::Encoder is built through
    // several whole copies of its 450 KB, each leaving its pages on a data stack of its own.
    if gzipped { compress::compress(body, packed, compress::GZIP, 6); }
    send_page(out, req, body, packed, body.len, coding, state.diagnostics, false, false, wire);
    store_page(entries, bytes, state, user, req.target, if gzipped { body[..0] } else { body }, packed, req.fields, coding, wire,
               false, body.len);
}
