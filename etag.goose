namespace campfire;

// Rails' Rack::Head, Rack::ConditionalGet and Rack::ETag (installed as `Rack::ETag, "no-cache"`), the
// three middlewares between the controllers and the cookie, session and flash middleware:
//
// - Rack::ETag gives a 200 or 201 whose body is a string, and that has no ETag or Last-Modified of
//   its own, `ETag: W/"<the first 32 hex digits of the body's SHA-256>"` and, without a Cache-Control,
//   `Cache-Control: max-age=0, private, must-revalidate`. Any other response without a Cache-Control
//   gets `no-cache` (one with validators of its own gets the first already, from
//   ActionDispatch::Response#handle_conditional_get!). It digests the body before Thruster
//   compresses it, so the ETag is the same in every Content-Encoding.
// - Rack::ConditionalGet answers a GET or HEAD whose 200 has an ETag equal to the whole If-None-Match
//   (no list, no `*`), or else a Last-Modified no later than If-Modified-Since, with 304 and no
//   Content-Type, Content-Length or body.
// - Rack::Head answers a HEAD as the GET, without the body.
//
// Routes whose pages are cached (cache.goose) and pages compressed here (respond_typed) are given
// their ETag before the body is compressed or stored; rack_finish gives the rest theirs once they
// are written, and answers the conditional requests.

import std;
import http;
import http.compression;
import hash;

// Rack::ETag's validator of a body: W/"..." with the first 16 bytes of its SHA-256 in hex.
fn rack_etag_value(body: const u8[:]) -> u8[>..] {
    let digest = hash::sha256(body);
    let digits = "0123456789abcdef";
    var tag: u8[>..] = [];
    tag.append("W/\"");
    for c in digest[..16] { tag.push(digits[c >> 4]); tag.push(digits[c & 15]); }
    tag.push('"');
    return tag;
}

// The value of field name among header lines, `Name: value` each, ending in a newline or CRLF.
fn field_line(lines: const u8[:], name: const u8[:]) -> const u8[:], bool {
    var at: i64 = 0;
    while at < lines.len {
        var end = find(lines[at..], "\n");
        let next = if end < 0 { lines.len } else { at + end + 1 };
        var line = lines[at..if end < 0 { lines.len } else { at + end }];
        if line.len > 0 && line[line.len - 1] == '\r' { line = line[..line.len - 1]; }
        let colon = find(line, ":");
        if colon > 0 && http::same_name(line[..colon], name) { return trim(line[colon + 1..]), true; }
        at = next;
    }
    return "", false;
}

// Header lines, `Name: value` each and newline-separated, as field lines ending in CRLF; a line
// http::field would refuse is dropped.
fn wire_fields(lines: const u8[:]) -> u8[>..] {
    var wire: u8[>..] = [];
    for line in split(lines, '\n') {
        let colon = find(line, ": ");
        if colon > 0 && http::is_field(line[..colon], line[colon + 2..]) { wire.append(line); wire.append("\r\n"); }
    }
    return wire;
}

// The field lines Rack::ETag adds to a response of status with body whose own fields are wire:
// the ETag, and its Cache-Control unless wire has one, for a 200 or 201 with a body and no ETag or
// Last-Modified; nothing otherwise.
fn rack_etag_wire(status: i32, body: const u8[:], wire: const u8[:]) -> u8[>..] {
    var lines: u8[>..] = [];
    guard (status == 200 || status == 201) && body.len > 0 else { return lines; }
    let tag, tagged = field_line(wire, "ETag");
    let modified, dated = field_line(wire, "Last-Modified");
    guard !tagged && !dated else { return lines; }
    lines.append("ETag: "); lines.append(rack_etag_value(body)); lines.append("\r\n");
    let control, controlled = field_line(wire, "Cache-Control");
    if !controlled { lines.append("Cache-Control: max-age=0, private, must-revalidate\r\n"); }
    return lines;
}

// Rack::ConditionalGet's fresh? for a GET's or HEAD's 200 with etag and modified (either may be
// empty): an If-None-Match equal to the ETag as a whole, or, without one, an If-Modified-Since no
// earlier than the Last-Modified.
fn rack_fresh(req: const http::Request&, etag: const u8[:], modified: const u8[:]) -> bool {
    guard req.method == "GET" || req.method == "HEAD" else { return false; }
    let tags, has_tags = http::field_of(req, "If-None-Match");
    if has_tags { return etag.len > 0 && tags == etag; }
    let since, has_since = http::field_of(req, "If-Modified-Since");
    guard has_since && since.len >= 16 && modified.len > 0 else { return false; }
    let t, valid = http::parse_date(since);
    let m, known = http::parse_date(modified);
    return valid && known && t >= m;
}

// http::respond_compressed with wire, field lines ending in CRLF, and Rack::ETag's fields, the ETag
// taken of the body before it is compressed.
fn respond_typed(out: http::Reply, req: const http::Request&, status: i32, content_type: const u8[:], body: const u8[:], wire: const u8[:]) {
    let c = http::Compression { .. };
    http::start(out, status);
    out.buf.append(wire);
    out.buf.append(rack_etag_wire(status, body, wire));
    http::field(out, "Content-Type", content_type);
    guard http::compressible(content_type) else { http::finish(out, http::NO_TYPE, body); return; }
    http::field(out, "Vary", "Accept-Encoding");
    let coding = if out.head || out.stream.bodyless || status == 206 || body.len < c.min_size { http::Coding.Identity } else { http::coding_for(req, c) };
    if coding == http::Coding.Identity { http::finish(out, http::NO_TYPE, body); return; }
    out.buf.append(http::coding_field(coding));
    var compressed: u8[>..] = [];
    http::compress_whole(body, compressed, coding, c);
    http::finish(out, http::NO_TYPE, compressed);
}

// http::respond_compressed, with Rack::ETag's fields.
fn respond_rack(out: http::Reply, req: const http::Request&, status: i32, content_type: const u8[:], body: const u8[:]) {
    respond_typed(out, req, status, content_type, body, "");
}

// The request the application answers for req: Rack::Head passes a HEAD on as it is, and the
// application answers it as a GET, body and all, which rack_finish drops. Its body goes
// uncompressed, as a HEAD's always has here, so its Accept-Encoding is left out (into fields).
fn rack_app_request(req: const http::Request&, fields: u8[>..]&) -> http::Request {
    guard req.method == "HEAD" else { return req; }
    var at: i64 = 0;
    while at < req.fields.len {
        let end = find(req.fields[at..], "\r\n");
        let next = if end < 0 { req.fields.len } else { at + end + 2 };
        let line = req.fields[at..next];
        let colon = find(line, ":");
        if !(colon > 0 && http::same_name(line[..colon], "Accept-Encoding")) { fields.append(line); }
        at = next;
    }
    return http::Request { method: req.method, target: req.target, minor: req.minor, keep_alive: req.keep_alive, body: req.body,
                           chunked: req.chunked, expect: req.expect, len: req.len, fields: fields };
}

// Whether Rack::ETag sees a response of status with a body of length: every one a controller
// answers, but not the static files ActionDispatch::Static serves above it, nor the exception
// pages ShowExceptions renders (a routing or record 404, a 406 for an unknown format, a 422 for a
// forged request, a 500), which have bodies where a controller's `head` has none. 401, 403 and 429
// are only ever the controllers' (head, or the sign-in form rendered again).
fn rack_inside(status: i32, length: i64, path: const u8[:]) -> bool {
    if starts_with(path, "/assets/") { return false; }
    if status < 400 { return true; }
    if status >= 500 || status == 405 || status == 406 { return false; }
    if status == 401 || status == 403 || status == 429 { return true; }
    return length == 0;
}

// What rack_head found in a response's head.
struct RackHead {
    status: i64 = 0,
    first: i64 = 0,     // the first field line's offset
    head_end: i64 = -1, // the blank line's offset, after the last field line's CRLF; -1 for a head still open
    etag: u8[..256] = [],
    modified: u8[..64] = [],
    tagged: bool = false,   // an ETag, or a Last-Modified, though too long to keep
    dated: bool = false,
    controlled: bool = false,
    coded: bool = false,
    chunked: bool = false,
    length: i64 = -1,
}

// The status and fields of the response in resp, which a status line begins.
fn rack_head(resp: const u8[:]) -> RackHead {
    var h = RackHead { .. };
    guard resp.len >= 12 && resp[..9] == "HTTP/1.1 " else { return h; }
    let status, valid = parse_int(resp[9..12]);
    guard valid else { return h; }
    h.status = status;
    let end = find(resp, "\r\n\r\n");
    guard end >= 0 else { return h; }
    h.first = find(resp, "\r\n") + 2;
    h.head_end = end + 2;
    var at = h.first;
    while at < h.head_end {
        let line_end = at + find(resp[at..h.head_end], "\r\n");
        let colon = find(resp[at..line_end], ":");
        if colon > 0 {
            let name = resp[at..at + colon];
            let value = trim(resp[at + colon + 1..line_end]);
            if http::same_name(name, "ETag") { h.tagged = true; if value.len <= 256 { h.etag = value; } }
            else if http::same_name(name, "Last-Modified") { h.dated = true; if value.len <= 64 { h.modified = value; } }
            else if http::same_name(name, "Cache-Control") { h.controlled = true; }
            else if http::same_name(name, "Content-Encoding") { h.coded = true; }
            else if http::same_name(name, "Transfer-Encoding") { h.chunked = true; }
            else if http::same_name(name, "Content-Length") { let n, ok = parse_int(value); if ok { h.length = n; } }
        }
        at = line_end + 2;
    }
    return h;
}

// The field lines Rack::ETag adds to the response in resp, of the request for path, whose head h
// read; h takes the ETag it adds. A body that isn't whole in resp (a file's, or one coded already)
// is not a string Rack::ETag could digest.
fn rack_added(resp: const u8[:], h: RackHead&, path: const u8[:], open: bool) -> u8[>..] {
    var add: u8[>..] = [];
    guard h.status >= 200 && h.head_end >= 0 else { return add; }
    let body = resp[h.head_end + 2..];
    guard rack_inside(h.status as! i32, if h.length >= 0 { h.length } else { body.len }, path) else { return add; }
    let whole = !h.chunked && !h.coded && !open && h.length == body.len;
    if (h.status == 200 || h.status == 201) && !h.tagged && !h.dated && whole && body.len > 0 {
        h.etag = rack_etag_value(body); h.tagged = true;
        add.append("ETag: "); add.append(h.etag); add.append("\r\n");
    }
    if !h.controlled {
        add.append(if h.tagged || h.dated { "Cache-Control: max-age=0, private, must-revalidate\r\n" } else { "Cache-Control: no-cache\r\n" });
    }
    return add;
}

// Whether the middlewares may have to rewrite req's response, not only add fields to it: a HEAD's
// loses its body (Rack::Head), and a conditional GET's may become a 304 (Rack::ConditionalGet).
fn rack_rewrites(req: const http::Request&) -> bool {
    if req.method == "HEAD" { return true; }
    guard req.method == "GET" else { return false; }
    let tags, has_tags = http::field_of(req, "If-None-Match");
    let since, has_since = http::field_of(req, "If-Modified-Since");
    return has_tags || has_since;
}

// Rack::ETag on the response the application wrote to out.buf from mark, for req, when
// rack_rewrites is false: its fields go in before the head's blank line. (The write buffer only
// grows: out may hold slices of it.)
fn rack_finish(req: const http::Request&, out: http::Reply, mark: i64) {
    guard mark >= 0 && out.buf.len > mark else { return; }
    var h = rack_head(out.buf[mark..]);
    let add = rack_added(out.buf[mark..], h, http::path_of(req.target), out.stream.open);
    guard add.len > 0 else { return; }
    let at = mark + h.head_end;
    let old = out.buf.len;
    out.buf.append(add);
    reverse(out.buf[at..old]);
    reverse(out.buf[old..]);
    reverse(out.buf[at..]);
}

// The three middlewares on response, which the application wrote apart for req (a HEAD, or a
// conditional GET), appended to out.buf: Rack::ETag's fields unless done (the page cache's
// answer has them, and its 304), Rack::ConditionalGet's 304, and Rack::Head's dropped body.
fn rack_finish_into(req: const http::Request&, response: const u8[:], out: http::Reply, done: bool) {
    var h = rack_head(response);
    let head = req.method == "HEAD";
    guard h.head_end >= 0 && h.status >= 200 && (!done || head) else { out.buf.append(response); return; }
    let add: u8[>..] = if done { [] } else { rack_added(response, h, http::path_of(req.target), out.stream.open) };
    let fresh = !done && h.status == 200 && rack_fresh(req, h.etag, h.modified);
    out.buf.append(if fresh { "HTTP/1.1 304 Not Modified\r\n" } else { response[..h.first] });
    var at = h.first;
    while at < h.head_end {
        let line_end = at + find(response[at..h.head_end], "\r\n");
        let colon = find(response[at..line_end], ":");
        let name = if colon > 0 { response[at..at + colon] } else { response[at..at] };
        let dropped = fresh && (http::same_name(name, "Content-Type") || http::same_name(name, "Content-Length") || http::same_name(name, "Content-Encoding"));
        if !dropped { out.buf.append(response[at..line_end + 2]); }
        at = line_end + 2;
    }
    out.buf.append(add);
    out.buf.append("\r\n");
    if !fresh && !head { out.buf.append(response[h.head_end + 2..]); }
    if fresh { out.stream.status = 304; out.stream.bodyless = true; }
}

// rack_finish for a response written after its request was answered, which a media or unfurl
// thread finished: Rack::ETag's fields only (the requests that wait so are a POST's, or a GET's
// with validators of its own).
fn rack_finish_later(out: http::Reply, mark: i64) {
    let none = http::Request { .. };
    rack_finish(none, out, mark);
}
