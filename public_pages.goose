// What sits above the controllers in Rails' stack, for responses no controller makes:
//
// - ActionDispatch::ShowExceptions with ActionDispatch::PublicExceptions, which render an
//   exception (a routing or record 404, a 422 for a forged request or an invalid record, a 500, a
//   400, a 406...) in the request's first format: a JSON, XML or YAML request gets the
//   `{ status:, error: }` hash in that format, and any other public/<status>.html (404, 422, 500 and
//   502 exist), or, without one, an empty page with the status. A HEAD gets an empty body in the
//   request's format. The type says charset=UTF-8 (ActionDispatch::Response.default_charset), where
//   rendered responses say charset=utf-8; etag.goose tells exception pages by it. The application's
//   response is gone, and with it the version headers its before_action set.
// - ActionDispatch::Static, with Rack::Files: public/robots.txt and the error pages (and the
//   digested assets, from assets/reference) as files, with production.rb's public_file_server
//   headers, Last-Modified, Rack's byte ranges and If-Modified-Since.
// - A controller's `head status`: the status and an empty body, typed as the first format, or
//   text/html from a before_action (the controller's formats are set only after them).
namespace campfire;

import std;
import os;
import http;
import http.compression;
import html;
import view_assets_generated;

// --- Formats -------------------------------------------------------------------------------------

// Mime::Type's registered types: action_dispatch/http/mime_types.rb, then turbo-rails'
// :turbo_stream, in registration order (which text/* and application/* expand in). Each is
// "symbol type synonym... .extension...".
fn mime_entry(i: i64) -> const u8[:] {
    let table: const u8[:][37] = [
        "html text/html application/xhtml+xml .xhtml", "text text/plain .txt",
        "js text/javascript application/javascript application/x-javascript", "css text/css", "ics text/calendar", "csv text/csv",
        "vcf text/vcard", "vtt text/vtt .vtt", "md text/markdown .md .markdown", "png image/png .png",
        "jpeg image/jpeg .jpg .jpeg .jpe .pjpeg", "gif image/gif .gif", "bmp image/bmp .bmp", "tiff image/tiff .tif .tiff",
        "svg image/svg+xml", "webp image/webp .webp", "mpeg video/mpeg .mpg .mpeg .mpe", "mp3 audio/mpeg .mp1 .mp2 .mp3",
        "ogg audio/ogg .oga .ogg .spx .opus", "m4a audio/aac audio/mp4 .m4a .mpg4 .aac", "webm video/webm .webm",
        "mp4 video/mp4 .mp4 .m4v", "otf font/otf .otf", "ttf font/ttf .ttf", "woff font/woff .woff", "woff2 font/woff2 .woff2",
        "xml application/xml text/xml application/x-xml", "rss application/rss+xml", "atom application/atom+xml",
        "yaml application/x-yaml text/yaml .yml .yaml", "multipart_form multipart/form-data",
        "url_encoded_form application/x-www-form-urlencoded",
        "json application/json text/x-json application/jsonrequest application/problem+json", "pdf application/pdf .pdf",
        "zip application/zip .zip", "gzip application/gzip application/x-gzip .gz", "turbo_stream text/vnd.turbo-stream.html"];
    return table[i];
}

let MIME_COUNT: i64 = 37;
// Mime::ALL, the */* wildcard, and no format at all (an unregistered one).
let FORMAT_ALL: i64 = -1;
let FORMAT_NONE: i64 = -2;

// Word n of a table entry.
fn mime_word(entry: const u8[:], n: i64) -> const u8[:] {
    var k: i64 = 0;
    for word in split(entry, ' ') {
        if k == n { return word; }
        k += 1;
    }
    return entry[..0];
}

// A format's type, as Mime[...].to_s gives it.
fn format_name(index: i64) -> const u8[:] {
    if index == FORMAT_ALL { return "*/*"; }
    guard index >= 0 else { return ""; }
    return mime_word(mime_entry(index), 1);
}

fn format_symbol(index: i64) -> const u8[:] {
    guard index >= 0 else { return ""; }
    return mime_word(mime_entry(index), 0);
}

// Mime[extension] (Type.lookup_by_extension): by symbol, or by one of the type's extensions.
fn format_by_extension(extension: const u8[:]) -> i64 {
    guard extension.len > 0 else { return FORMAT_NONE; }
    for i in MIME_COUNT {
        var k: i64 = 0;
        for word in split(mime_entry(i), ' ') {
            if k == 0 && word == extension { return i; }
            if word.len == extension.len + 1 && word[0] == '.' && word[1..] == extension { return i; }
            k += 1;
        }
    }
    return FORMAT_NONE;
}

// Mime::Type.lookup: the type or a synonym, as it is and then lowercased without parameters;
// FORMAT_NONE for a valid type Rails doesn't know, and false for an invalid one (InvalidMimeType).
fn format_by_type(text: const u8[:]) -> i64, bool {
    let exact = format_by_type_exact(text);
    if exact != FORMAT_NONE { return exact, true; }
    let semicolon = find(text, ";");
    let base = html_lower(trim(if semicolon >= 0 { text[..semicolon] } else { text }));
    let lowered = format_by_type_exact(base);
    if lowered != FORMAT_NONE { return lowered, true; }
    if base == "*/*" { return FORMAT_ALL, true; }
    return FORMAT_NONE, valid_mime_type(base);
}

fn format_by_type_exact(text: const u8[:]) -> i64 {
    for i in MIME_COUNT {
        var k: i64 = 0;
        for word in split(mime_entry(i), ' ') {
            if k > 0 && word.len > 0 && word[0] != '.' && word == text { return i; }
            k += 1;
        }
    }
    return FORMAT_NONE;
}

// Mime::Type::MIME_REGEXP, as the Jai port reads it: type/subtype of name characters.
fn valid_mime_type(base: const u8[:]) -> bool {
    let slash = find(base, "/");
    guard slash > 0 else { return false; }
    return mime_token(base[..slash]) && (base[slash + 1..] == "*" || mime_token(base[slash + 1..]));
}

fn mime_token(s: const u8[:]) -> bool {
    guard s.len > 0 && s.len <= 127 && ascii_alnum(s[0]) else { return false; }
    for c in s { if !ascii_alnum(c) && find("!#$&-^_.+", [c]) < 0 { return false; } }
    return true;
}

fn ascii_alnum(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'); }

// TRAILING_STAR_REGEXP's expansion of text/* or application/*: its first registered type, html
// for both (application/xhtml+xml is html's synonym).
fn trailing_star(item: const u8[:]) -> bool {
    return starts_with(item, "text/*") || starts_with(item, "application/*");
}

// Ruby's to_f of a q value, times 100 and truncated.
fn accept_q(text: const u8[:]) -> i64 {
    var i: i64 = 0;
    while i < text.len && (text[i] == ' ' || text[i] == '\t') { i += 1; }
    var whole: i64 = 0;
    while i < text.len && text[i] >= '0' && text[i] <= '9' && whole < 100000000 { whole = whole * 10 + (text[i] - '0'); i += 1; }
    var hundredths: i64 = 0;
    if i < text.len && text[i] == '.' {
        i += 1;
        var scale: i64 = 10;
        while i < text.len && text[i] >= '0' && text[i] <= '9' {
            hundredths += (text[i] - '0') * scale; scale = scale / 10; i += 1;
        }
    }
    return whole * 100 + hundredths;
}

// PARAMETER_SEPARATOR_REGEXP, /;\s*q="?/: where it starts and where what follows it does; -1 for none.
fn q_separator(s: const u8[:]) -> i64, i64 {
    for c, i in s {
        if c != ';' { continue; }
        var j = i + 1;
        while j < s.len && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r' || s[j] == 12) { j += 1; }
        if j + 1 < s.len && s[j] == 'q' && s[j + 1] == '=' { return i, if j + 2 < s.len && s[j + 2] == '"' { j + 3 } else { j + 2 }; }
    }
    return -1, -1;
}

// The first of Mime::Type.parse(accept), keeping registered types and */* as
// MimeNegotiation#formats does: FORMAT_NONE for none, and false for an invalid type.
fn first_accepted(accept: const u8[:]) -> i64, bool {
    if find(accept, ",") < 0 {
        let start, after = q_separator(accept);
        let single = trim(if start >= 0 { accept[..start] } else { accept });
        guard single.len > 0 else { return FORMAT_NONE, true; }
        if trailing_star(single) { return 0, true; }
        return format_by_type(single);
    }
    // AcceptList: each item's q times 100 (*/* without one is 0), sorted by q and then by order.
    var starts: i64[64] = [0; 64]; var ends: i64[64] = [0; 64]; var qs: i64[64] = [0; 64];
    var count: i64 = 0;
    var i: i64 = 0;
    // ACCEPT_HEADER_REGEXP, /[^,\s"](?:[^,"]|"[^"]*")*/
    while i < accept.len && count < 64 {
        let c = accept[i];
        if c == ',' || c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 12 || c == '"' { i += 1; continue; }
        let begin = i;
        i += 1;
        while i < accept.len && accept[i] != ',' {
            if accept[i] == '"' {
                let close = find(accept[i + 1..], "\"");
                if close < 0 { i += 1; continue; }
                i = i + 1 + close + 1;
            } else { i += 1; }
        }
        let item = accept[begin..i];
        let start, after = q_separator(item);
        let params = trim(if start >= 0 { item[..start] } else { item });
        if params.len == 0 { continue; }
        var q: i64 = if params == "*/*" { 0 } else { 100 };
        if start >= 0 {
            // String#split drops a trailing empty field, so "q=" leaves q at its default.
            let rest = item[after..];
            let next, more = q_separator(rest);
            let value = if next >= 0 { rest[..next] } else { rest };
            if value.len > 0 { q = accept_q(value); }
        }
        // The item starts with no space, so params starts where it does.
        starts[count] = begin;
        ends[count] = begin + params.len;
        qs[count] = q;
        count += 1;
    }
    // A stable sort by descending q.
    var order: i64[64] = [0; 64];
    for k in count { order[k] = k; }
    for k in count {
        var j = k;
        while j > 0 && qs[order[j - 1]] < qs[order[j]] { let t = order[j - 1]; order[j - 1] = order[j]; order[j] = t; j -= 1; }
    }
    // AcceptList#sort!'s XML: text/xml folds into application/xml, which then yields to each +xml
    // type of its q listed after it.
    var text_at: i64 = -1; var app_at: i64 = -1;
    for k in count {
        let name = accept[starts[order[k]]..ends[order[k]]];
        if name == "text/xml" && text_at < 0 { text_at = k; }
        if name == "application/xml" && app_at < 0 { app_at = k; }
    }
    var removed: i64 = -1;
    var app_q: i64 = 0;
    if text_at >= 0 && app_at >= 0 {
        app_q = max(qs[order[app_at]], qs[order[text_at]]);
        if app_at > text_at { let t = order[app_at]; order[app_at] = order[text_at]; order[text_at] = t; let s = app_at; app_at = text_at; text_at = s; }
        removed = text_at;
    } else if text_at >= 0 {
        app_at = text_at; app_q = qs[order[text_at]];
    } else if app_at >= 0 { app_q = qs[order[app_at]]; }
    // The list as AcceptList leaves it: positions, and which holds application/xml.
    var list: i64[64] = [0; 64]; var size: i64 = 0; var xml_at: i64 = -1;
    for k in count {
        if k == removed { continue; }
        if k == app_at { xml_at = size; }
        list[size] = order[k]; size += 1;
    }
    if xml_at >= 0 {
        var k = xml_at;
        let xml = list[xml_at];
        while k < size {
            let q = if list[k] == xml { app_q } else { qs[list[k]] };
            if q < app_q { break; }
            if ends_with(accept[starts[list[k]]..ends[list[k]]], "+xml") {
                let t = list[xml_at]; list[xml_at] = list[k]; list[k] = t; xml_at = k;
            }
            k += 1;
        }
    }
    // Every type is looked up, and one that isn't valid fails them all. (A text/xml left alone is
    // renamed application/xml: the same format.)
    var first = FORMAT_NONE;
    for k in size {
        let name = accept[starts[list[k]]..ends[list[k]]];
        var listed = FORMAT_NONE;
        if trailing_star(name) { listed = 0; }
        else {
            let found, valid = format_by_type(name);
            guard valid else { return FORMAT_NONE, false; }
            listed = found;
        }
        if first == FORMAT_NONE { first = listed; }
    }
    return first, true;
}

// The extension format_from_path_extension reads, /\.(\w+)\z/, of path; "" for none.
fn path_extension(path: const u8[:]) -> const u8[:] {
    var i = path.len;
    while i > 0 && (ascii_alnum(path[i - 1]) || path[i - 1] == '_') { i -= 1; }
    guard i > 0 && i < path.len && path[i - 1] == '.' else { return path[..0]; }
    return path[i..];
}

// The first of request.formats (ActionDispatch::Http::MimeNegotiation#formats): params[:format]
// (format, a route's default, else ?format= in the query; with routed, the path's extension is the
// route's (.:format) and comes first), then a valid Accept (a browser's, which lists */* among
// others, isn't), then the path's extension, then js for an XHR and html. An Accept with an
// invalid type, which ShowExceptions replaces with text/html, is html.
fn request_format(req: const http::Request&, routed: bool = true, default_format: const u8[:] = "") -> i64 {
    let path = http::path_of(req.target);
    let extension = path_extension(path);
    if routed && extension.len > 0 { return format_by_extension(extension); }
    if default_format.len > 0 { return format_by_extension(default_format); }
    let raw, has_param = http::query_of(req.target, "format");
    if has_param {
        var value: u8[>..] = [];
        if !http::decode(raw, value, true) { return FORMAT_NONE; }
        return format_by_extension(value);
    }
    let accept, has_accept = http::field_of(req, "Accept");
    let present = has_accept && trim(accept).len > 0;
    let requested, has_requested = http::field_of(req, "X-Requested-With");
    let xhr = has_requested && requested == "XMLHttpRequest";
    let kind, has_kind = http::field_of(req, "Content-Type");
    var compact: u8[>..] = [];
    if present { for c in accept { if c != ' ' && c != '\t' && c != '\n' && c != '\r' && c != 11 && c != 12 { compact.push(c); } } }
    let browser = find(compact, ",*/*") >= 0 || find(compact, "*/*,") >= 0;
    if (xhr && (present || has_kind && kind.len > 0)) || (present && !browser) {
        if !present {
            // [content_mime_type]
            var end: i64 = 0;
            while end < kind.len && kind[end] != ',' && kind[end] != ';' { end += 1; }
            let base = html_lower(trim(kind[..end]));
            guard base.len > 0 else { return FORMAT_NONE; }
            let found, valid = format_by_type(base);
            return if valid { found } else { 0 };
        }
        let first, valid = first_accepted(trim(accept));
        return if valid { first } else { 0 };
    }
    if extension.len > 0 {
        let found = format_by_extension(extension);
        if found != FORMAT_NONE { return found; }
    }
    return if xhr { 2 } else { 0 };
}

// --- ShowExceptions and PublicExceptions ---------------------------------------------------------

// Rack::Utils::HTTP_STATUS_CODES, for the error PublicExceptions names (500's for one it lacks).
fn status_reason(status: i32) -> const u8[:] {
    let codes = [400, 401, 402, 403, 404, 405, 406, 407, 408, 409, 410, 411, 412, 413, 414, 415, 416, 417, 421, 422, 423, 424, 425,
                 426, 428, 429, 431, 451, 500, 501, 502, 503, 504, 505, 506, 507, 508, 511];
    let reasons: const u8[:][38] = ["Bad Request", "Unauthorized", "Payment Required", "Forbidden", "Not Found", "Method Not Allowed",
        "Not Acceptable", "Proxy Authentication Required", "Request Timeout", "Conflict", "Gone", "Length Required",
        "Precondition Failed", "Content Too Large", "URI Too Long", "Unsupported Media Type", "Range Not Satisfiable",
        "Expectation Failed", "Misdirected Request", "Unprocessable Content", "Locked", "Failed Dependency", "Too Early",
        "Upgrade Required", "Precondition Required", "Too Many Requests", "Request Header Fields Too Large",
        "Unavailable For Legal Reasons", "Internal Server Error", "Not Implemented", "Bad Gateway", "Service Unavailable",
        "Gateway Timeout", "HTTP Version Not Supported", "Variant Also Negotiates", "Insufficient Storage", "Loop Detected",
        "Network Authentication Required"];
    for code, i in codes { if code == status { return reasons[i]; } }
    return "Internal Server Error";
}

// The page PublicExceptions renders for status in format, into content_type and body.
fn exception_page(status: i32, chosen: i64, head: bool, content_type: u8[>..]&, body: u8[>..]&) {
    let symbol = format_symbol(chosen);
    // render_format's "#{content_type}; charset=UTF-8"; no format is html.
    let named = if chosen == FORMAT_NONE { "text/html" } else { format_name(chosen) };
    let error = status_reason(status);
    if head { content_type.append(named); content_type.append("; charset=UTF-8"); return; }
    if symbol == "json" {
        format(body, "{\"status\":", status, ",\"error\":\""); body.append(error); body.append("\"}");
    } else if symbol == "xml" {
        // Hash#to_xml, Builder escaping the text.
        format(body, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<hash>\n  <status type=\"integer\">", status, "</status>\n  <error>");
        body.append(error); body.append("</error>\n</hash>\n");
    } else if symbol == "yaml" {
        format(body, "---\n:status: ", status, "\n:error: "); body.append(error); body.push('\n');
    } else {
        // render_html: public/<status>.html, or ShowExceptions' pass_response, an empty page.
        content_type.append("text/html; charset=UTF-8");
        let read = read_file(str("public/", status, ".html"), body);
        if !read { body.clear(); }
        return;
    }
    content_type.append(named); content_type.append("; charset=UTF-8");
}

// out's common fields without the version headers a controller's before_action set: an exception
// page replaces the controller's response.
fn exception_common(common: const u8[:]) -> u8[>..] {
    var kept: u8[>..] = [];
    var at: i64 = 0;
    while at < common.len {
        let end = find(common[at..], "\r\n");
        let line_end = if end < 0 { common.len } else { at + end + 2 };
        let line = common[at..line_end];
        if !starts_with(line, "X-Version:") && !starts_with(line, "X-Rev:") { kept.append(line); }
        at = line_end;
    }
    return kept;
}

// ShowExceptions' answer for an exception of status raised while answering req. routed: the
// request matched a route, whose (.:format) the path's extension is; format: the route's default
// format, if it has one (the bots' JSON routes).
fn public_exception(out: http::Reply, req: const http::Request&, status: i32, routed: bool = true, default_format: const u8[:] = "") {
    var content_type: u8[>..] = []; var body: u8[>..] = [];
    exception_page(status, request_format(req, routed, default_format), req.method == "HEAD" || out.head, content_type, body);
    let common = exception_common(out.common);
    let reply = http::Reply { buf: out.buf, common: common, keep_alive: out.keep_alive, minor: out.minor, head: out.head, stream: out.stream, fd: out.fd };
    // render_format sets Content-Length itself; Thruster compresses what it may.
    http::respond_compressed(reply, req, status, content_type, body);
}

// public_exception for a request answered later, by a media or unfurl thread, whose formats
// aren't kept: html.
fn public_exception_later(out: http::Reply, status: i32) {
    var content_type: u8[>..] = []; var body: u8[>..] = [];
    exception_page(status, 0, out.head, content_type, body);
    let common = exception_common(out.common);
    let reply = http::Reply { buf: out.buf, common: common, keep_alive: out.keep_alive, minor: out.minor, head: out.head, stream: out.stream, fd: out.fd };
    http::respond(reply, status, content_type, body);
}

// A routing error: no route matched req.
fn routing_error(out: http::Reply, req: const http::Request&) { public_exception(out, req, 404, false); }

// A controller's `head status` from a before_action, or from an action with in_action: an empty
// body, typed as Mime[formats.first] (text/html when that isn't a registered type) with no charset.
// live: an ActionController::Live controller's, whose empty body is streamed (chunked, no
// Content-Length) but for a HEAD.
fn respond_head(out: http::Reply, req: const http::Request&, status: i32, in_action: bool = false, live: bool = false) {
    let typed = status >= 200 && status != 204 && status != 304;
    let chosen = if typed && in_action { request_format(req) } else { 0 };
    if live && typed && !out.head && req.method != "HEAD" {
        http::begin(out, status, -1);
        http::field(out, "Content-Type", if chosen >= 0 { format_name(chosen) } else { "text/html" });
        http::end(out);
        return;
    }
    http::start(out, status);
    if typed { http::field(out, "Content-Type", if chosen >= 0 { format_name(chosen) } else { "text/html" }); }
    http::finish(out, http::NO_TYPE, "");
}

// out without the version headers in its common fields, for a response no controller made.
fn bare_common(out: http::Reply) -> u8[>..] { return exception_common(out.common); }

// --- ActionDispatch::Static ----------------------------------------------------------------------

// FileHandler#clean_path: the path without a trailing slash, percent-decoded, and with
// Rack::Utils.clean_path_info's segments ("", "." and ".." resolved); false for a NUL.
fn static_clean_path(path: const u8[:], out: u8[>..]&) -> bool {
    var chomped = path;
    if chomped.len > 0 && chomped[chomped.len - 1] == '/' { chomped = chomped[..chomped.len - 1]; }
    // URI::RFC2396_Parser#unescape: %XX is a byte, anything else is kept.
    var decoded: u8[>..] = [];
    var i: i64 = 0;
    while i < chomped.len {
        if chomped[i] == '%' && i + 2 < chomped.len && escape_digit(chomped[i + 1]) >= 0 && escape_digit(chomped[i + 2]) >= 0 {
            decoded.push((escape_digit(chomped[i + 1]) * 16 + escape_digit(chomped[i + 2])) as! u8); i += 3;
        } else { decoded.push(chomped[i]); i += 1; }
    }
    for c in decoded { if c == 0 { return false; } }
    var parts: const u8[:][>..] = [];
    for part in split(decoded, '/') {
        if part.len == 0 || part == "." { continue; }
        if part == ".." { if parts.len > 0 { remove_at(parts, parts.len - 1); } continue; }
        parts.push(part);
    }
    for part in parts { out.push('/'); out.append(part); }
    return true;
}

fn escape_digit(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return (c - '0'); }
    if c >= 'a' && c <= 'f' { return (c - 'a') + 10; }
    if c >= 'A' && c <= 'F' { return (c - 'A') + 10; }
    return -1;
}

// The public/ file Static serves for a cleaned path, and its type (Rack::Mime's, by extension, or
// text/html for a path without one that names a .html file); "" for none. public/ holds Rails'
// robots.txt and error pages (views/public.json).
fn public_file(clean: const u8[:]) -> const u8[:], const u8[:] {
    if clean == "/robots.txt" { return "robots.txt", "text/plain"; }
    let pages: const u8[:][4] = ["404.html", "422.html", "500.html", "502.html"];
    for page in pages {
        if clean.len == page.len + 1 && clean[1..] == page { return page, "text/html"; }
        // A path without an extension tries .html (and /index.html, which public/ hasn't).
        if clean.len == page.len - 4 && clean[1..] == page[..page.len - 5] { return page, "text/html"; }
    }
    return "", "";
}

// Whether ActionDispatch::Static answers a GET or HEAD for path, with a public/ file or an asset:
// such a response never reaches the middlewares below it (etag.goose).
fn static_path(path: const u8[:]) -> bool {
    guard static_candidate(path) else { return false; }
    var clean: u8[>..] = [];
    guard static_clean_path(path, clean) else { return false; }
    if starts_with(clean, "/assets/") { return asset_public_index(clean) >= 0; }
    let file, content_type = public_file(clean);
    return file.len > 0;
}

// Ruby's String#to_i of a byte range's bound: leading spaces, a sign, then digits.
fn ruby_to_i(text: const u8[:]) -> i64 {
    var i: i64 = 0;
    while i < text.len && (text[i] == ' ' || (text[i] >= 9 && text[i] <= 13)) { i += 1; }
    var negative = false;
    if i < text.len && (text[i] == '+' || text[i] == '-') { negative = text[i] == '-'; i += 1; }
    var n: i64 = 0;
    while i < text.len && text[i] >= '0' && text[i] <= '9' && n < 100000000000000000 { n = n * 10 + (text[i] - '0'); i += 1; }
    return if negative { -n } else { n };
}

// Rack::Utils.get_byte_ranges of a Range header for size bytes, as firsts and lasts (inclusive):
// 0 for none (no header, a size of 0, or one Rack can't read: the whole file), 1 for ranges, and 2
// for an unsatisfiable one.
fn rack_byte_ranges(header: const u8[:], has_header: bool, size: i64, firsts: i64[>..]&, lasts: i64[>..]&) -> i32 {
    guard has_header && size > 0 else { return 0; }
    // /bytes=([^;]+)/, anywhere in the header.
    let at = find(header, "bytes=");
    guard at >= 0 else { return 0; }
    var spec = header[at + 6..];
    let semicolon = find(spec, ";");
    if semicolon >= 0 { spec = spec[..semicolon]; }
    guard spec.len > 0 else { return 0; }
    // At most 99 commas (Rack's guard against many ranges), then split(/,[ \t]*/), which drops
    // trailing empty fields.
    var commas: i64 = 0;
    for c in spec { if c == ',' { commas += 1; } }
    guard commas < 100 else { return 0; }
    var specs: const u8[:][>..] = [];
    for raw, n in split(spec, ',') {
        var part = raw;
        if n > 0 { while part.len > 0 && (part[0] == ' ' || part[0] == '\t') { part = part[1..]; } }
        specs.push(part);
    }
    var kept = specs.len;
    while kept > 0 && specs[kept - 1].len == 0 { kept -= 1; }
    var total: i64 = 0;
    for part, n in specs {
        if n >= kept { break; }
        guard find(part, "-") >= 0 else { return 0; }
        // range_spec.split("-"), which drops trailing empty fields too: r0 and r1 may be nil.
        let fields = split(part, '-');
        var count = fields.len;
        while count > 0 && fields[count - 1].len == 0 { count -= 1; }
        var first: i64 = 0; var last: i64 = 0;
        if count == 0 || fields[0].len == 0 {
            guard count > 1 else { return 0; }
            first = max(size - ruby_to_i(fields[1]), 0);
            last = size - 1;
        } else {
            first = ruby_to_i(fields[0]);
            if count < 2 { last = size - 1; }
            else {
                last = ruby_to_i(fields[1]);
                guard last >= first else { return 0; }
                if last >= size { last = size - 1; }
            }
        }
        if first <= last { firsts.push(first); lasts.push(last); total += last - first + 1; }
    }
    if total > size { firsts.clear(); lasts.clear(); }
    return if firsts.len == 0 { 2 } else { 1 };
}

// Rack::Files#serving for data, the file at path, as content_type, then FileHandler#serve's
// content headers: 304 for an If-Modified-Since equal to its Last-Modified, Rack's byte ranges,
// and production.rb's Cache-Control. A whole file Thruster compresses as it may. (Thruster's own
// cache, which answers a warm URL's Range and If-Modified-Since with the whole file, isn't kept.)
fn rack_file(given: http::Reply, req: const http::Request&, path: const u8[:], content_type: const u8[:], data: const u8[:]) {
    let common = bare_common(given);
    let out = http::Reply { buf: given.buf, common: common, keep_alive: given.keep_alive, minor: given.minor, head: given.head, stream: given.stream, fd: given.fd };
    let f, opened = http::open_file(path);
    var modified: u8[>..] = []; http::format_date(modified, max(f.modified, 0)); http::close_file(f);
    let since, has_since = http::field_of(req, "If-Modified-Since");
    if has_since && since == modified { http::start(out, 304); http::finish(out, "", ""); return; }
    let range, has_range = http::field_of(req, "Range");
    var firsts: i64[>..] = []; var lasts: i64[>..] = [];
    let ranged = rack_byte_ranges(range, has_range, data.len, firsts, lasts);
    if ranged == 2 {
        // Rack::Files#fail, its type replaced by the file's.
        http::start(out, 416);
        http::field(out, "Content-Type", content_type);
        http::field(out, "X-Cascade", "pass");
        format(out.buf, "Content-Range: bytes */", data.len, "\r\n");
        http::finish(out, http::NO_TYPE, "Byte range unsatisfiable\n");
        return;
    }
    if ranged == 0 {
        var fields: u8[>..] = [];
        fields.append("Last-Modified: "); fields.append(modified); fields.append("\r\nCache-Control: public, max-age=2592000\r\n");
        respond_fields_compressed(out, req, content_type, fields, data);
        return;
    }
    http::start(out, 206);
    http::field(out, "Last-Modified", modified);
    // A multipart body's type too is the file's: Static replaces Rack's.
    http::field(out, "Content-Type", content_type);
    http::field(out, "Cache-Control", "public, max-age=2592000");
    if firsts.len == 1 {
        format(out.buf, "Content-Range: bytes ", firsts[0], "-", lasts[0], "/", data.len, "\r\n");
        http::finish(out, http::NO_TYPE, data[firsts[0]..lasts[0] + 1]);
        return;
    }
    var body: u8[>..] = [];
    for first, i in firsts {
        format(body, "\r\n--AaB03x\r\ncontent-type: ", content_type, "\r\ncontent-range: bytes ", first, "-", lasts[i], "/", data.len, "\r\n\r\n");
        body.append(data[first..lasts[i] + 1]);
    }
    body.append("\r\n--AaB03x--\r\n");
    http::finish(out, http::NO_TYPE, body);
}

// http::respond_compressed's 200 with fields, field lines ending in CRLF, before the type.
fn respond_fields_compressed(out: http::Reply, req: const http::Request&, content_type: const u8[:], fields: const u8[:], body: const u8[:]) {
    let c = http::Compression { .. };
    http::start(out, 200);
    out.buf.append(fields);
    http::field(out, "Content-Type", content_type);
    guard http::compressible(content_type) else { http::finish(out, http::NO_TYPE, body); return; }
    out.buf.append("Vary: Accept-Encoding\r\n");
    let coding = if out.head || req.method == "HEAD" || body.len < c.min_size { http::Coding.Identity } else { http::coding_for(req, c) };
    if coding == http::Coding.Identity { http::finish(out, http::NO_TYPE, body); return; }
    out.buf.append(http::coding_field(coding));
    var compressed: u8[>..] = [];
    http::compress_whole(body, compressed, coding, c);
    http::finish(out, http::NO_TYPE, compressed);
}

// ActionDispatch::Static: a GET or HEAD for a public/ file or a digested asset. False for any
// other request, which goes on to the routes.
fn static_route(req: const http::Request&, out: http::Reply) -> bool {
    guard req.method == "GET" || req.method == "HEAD" else { return false; }
    let path = http::path_of(req.target);
    guard static_candidate(path) else { return false; }
    var clean: u8[>..] = [];
    guard static_clean_path(path, clean) else { return false; }
    var data: u8[>..] = [];
    if starts_with(clean, "/assets/") {
        let index = asset_public_index(clean);
        guard index >= 0 else { return false; }
        let file = str("assets/reference/", asset_filename(index));
        guard read_file(file, data) else { return false; }
        rack_file(out, req, file, asset_mime(index), data);
        return true;
    }
    let name, content_type = public_file(clean);
    guard name.len > 0 else { return false; }
    let file = str("public/", name);
    guard read_file(file, data) else { return false; }
    rack_file(out, req, file, content_type, data);
    return true;
}

// Whether path could name a public/ file or an asset once cleaned: it holds one of their names, or
// an escape. (Most paths don't, and aren't cleaned.)
fn static_candidate(path: const u8[:]) -> bool {
    return find(path, "assets") >= 0 || find(path, "robots") >= 0 || find(path, "404") >= 0 || find(path, "422") >= 0 ||
           find(path, "500") >= 0 || find(path, "502") >= 0 || find(path, "%") >= 0;
}

// --- Routing -------------------------------------------------------------------------------------

// The routes `bin/rails routes` lists, in the order Rails draws them (a resource's nested routes
// before its own; the first match wins): config/routes.rb at the reference's revision, resources
// expanded, then the engines' (Turbo Native navigation, Action Mailbox and its conductor, Active
// Storage). Each is "verbs pattern": G GET (and HEAD), P POST, U PATCH or PUT, T PUT, D DELETE,
// then ! for a route whose controller lacks the action (AbstractController::ActionNotFound's 404,
// before any callback). A pattern's segments are literal, :name (no '.'), @:name, or * (a glob,
// the rest); every route but the root takes an optional .format on its last segment. Action
// Cable's /cable is the worker loop's.
fn rails_route_entry(i: i64) -> const u8[:] {
    let table: const u8[:][158] = [
        "G ",
        "P first_run",
        "G! first_run/new",
        "G! first_run/edit",
        "G first_run",
        "U! first_run",
        "D! first_run",
        "G session/transfers/:id",
        "U session/transfers/:id",
        "P session",
        "G session/new",
        "G! session/edit",
        "G! session",
        "U! session",
        "D session",
        "G account/users",
        "P! account/users",
        "G! account/users/new",
        "G! account/users/:id/edit",
        "G! account/users/:id",
        "U account/users/:id",
        "D account/users/:id",
        "U account/bots/:bot_id/key",
        "G account/bots",
        "P account/bots",
        "G account/bots/new",
        "G account/bots/:id/edit",
        "G! account/bots/:id",
        "U account/bots/:id",
        "D account/bots/:id",
        "P account/join_code",
        "G account/logo",
        "D account/logo",
        "G account/custom_styles/edit",
        "U account/custom_styles",
        "P! account",
        "G! account/new",
        "G account/edit",
        "G! account",
        "U account",
        "D! account",
        "G join/:join_code",
        "P join/:join_code",
        "G qr_code/:id",
        "G users/:user_id/avatar",
        "D users/:user_id/avatar",
        "P users/:user_id/ban",
        "D users/:user_id/ban",
        "G users/:user_id/sidebar",
        "P! users/:user_id/profile",
        "G! users/:user_id/profile/new",
        "G! users/:user_id/profile/edit",
        "G users/:user_id/profile",
        "U users/:user_id/profile",
        "D! users/:user_id/profile",
        "P users/:user_id/push_subscriptions/:push_subscription_id/test_notifications",
        "G users/:user_id/push_subscriptions",
        "P users/:user_id/push_subscriptions",
        "G! users/:user_id/push_subscriptions/new",
        "G! users/:user_id/push_subscriptions/:id/edit",
        "G! users/:user_id/push_subscriptions/:id",
        "U! users/:user_id/push_subscriptions/:id",
        "D users/:user_id/push_subscriptions/:id",
        "G users/:id",
        "G autocompletable/users",
        "G rooms/:room_id/messages",
        "P rooms/:room_id/messages",
        "G! rooms/:room_id/messages/new",
        "G rooms/:room_id/messages/:id/edit",
        "G rooms/:room_id/messages/:id",
        "U rooms/:room_id/messages/:id",
        "D rooms/:room_id/messages/:id",
        "P rooms/:room_id/:bot_key/messages/:message_id/boosts",
        "D rooms/:room_id/:bot_key/messages/:message_id/boosts/:id",
        "G rooms/:room_id/:bot_key/messages",
        "P rooms/:room_id/:bot_key/messages",
        "U rooms/:room_id/:bot_key/messages/:id",
        "D rooms/:room_id/:bot_key/messages/:id",
        "G rooms/:room_id/refresh",
        "G rooms/:room_id/settings",
        "G rooms/:room_id/involvement",
        "U rooms/:room_id/involvement",
        "G rooms/:room_id/@:message_id",
        "G rooms",
        "P! rooms",
        "G! rooms/new",
        "G! rooms/:id/edit",
        "G rooms/:id",
        "U! rooms/:id",
        "D rooms/:id",
        "G rooms/opens",
        "P rooms/opens",
        "G rooms/opens/new",
        "G rooms/opens/:id/edit",
        "G rooms/opens/:id",
        "U rooms/opens/:id",
        "D rooms/opens/:id",
        "G rooms/closeds",
        "P rooms/closeds",
        "G rooms/closeds/new",
        "G rooms/closeds/:id/edit",
        "G rooms/closeds/:id",
        "U rooms/closeds/:id",
        "D rooms/closeds/:id",
        "G rooms/directs",
        "P rooms/directs",
        "G rooms/directs/new",
        "G rooms/directs/:id/edit",
        "G rooms/directs/:id",
        "U! rooms/directs/:id",
        "D rooms/directs/:id",
        "G messages/:message_id/boosts",
        "P messages/:message_id/boosts",
        "G messages/:message_id/boosts/new",
        "G! messages/:message_id/boosts/:id/edit",
        "G! messages/:message_id/boosts/:id",
        "U! messages/:message_id/boosts/:id",
        "D messages/:message_id/boosts/:id",
        "G messages",
        "P messages",
        "G! messages/new",
        "G messages/:id/edit",
        "G messages/:id",
        "U messages/:id",
        "D messages/:id",
        "D searches/clear",
        "G searches",
        "P searches",
        "P unfurl_link",
        "G webmanifest",
        "G service-worker",
        "G up",
        "G recede_historical_location",
        "G resume_historical_location",
        "G refresh_historical_location",
        "P rails/action_mailbox/postmark/inbound_emails",
        "P rails/action_mailbox/relay/inbound_emails",
        "P rails/action_mailbox/sendgrid/inbound_emails",
        "G rails/action_mailbox/mandrill/inbound_emails",
        "P rails/action_mailbox/mandrill/inbound_emails",
        "P rails/action_mailbox/mailgun/inbound_emails/mime",
        "G rails/conductor/action_mailbox/inbound_emails",
        "P rails/conductor/action_mailbox/inbound_emails",
        "G rails/conductor/action_mailbox/inbound_emails/new",
        "G rails/conductor/action_mailbox/inbound_emails/:id",
        "G rails/conductor/action_mailbox/inbound_emails/sources/new",
        "P rails/conductor/action_mailbox/inbound_emails/sources",
        "P rails/conductor/action_mailbox/:inbound_email_id/reroute",
        "P rails/conductor/action_mailbox/:inbound_email_id/incinerate",
        "G rails/active_storage/blobs/redirect/:signed_id/*",
        "G rails/active_storage/blobs/proxy/:signed_id/*",
        "G rails/active_storage/blobs/:signed_id/*",
        "G rails/active_storage/representations/redirect/:signed_blob_id/:variation_key/*",
        "G rails/active_storage/representations/proxy/:signed_blob_id/:variation_key/*",
        "G rails/active_storage/representations/:signed_blob_id/:variation_key/*",
        "G rails/active_storage/disk/:encoded_key/*",
        "T rails/active_storage/disk/:encoded_token",
        "P rails/active_storage/direct_uploads"];
    return table[i];
}

let RAILS_ROUTE_COUNT: i64 = 158;

// A dynamic segment's value, [^/.?]+, with the format's [^/.?]+ after a '.' when last.
fn route_dynamic(segment: const u8[:], last: bool) -> bool {
    let dot = find(segment, ".");
    if dot < 0 { return segment.len > 0; }
    return last && dot > 0 && dot + 1 < segment.len && find(segment[dot + 1..], ".") < 0;
}

// A literal segment, or with last, the literal and a .format.
fn route_literal(segment: const u8[:], literal: const u8[:], last: bool) -> bool {
    if segment == literal { return true; }
    return last && segment.len > literal.len + 1 && starts_with(segment, literal) && segment[literal.len] == '.' &&
           find(segment[literal.len + 1..], ".") < 0;
}

fn route_matches(pattern: const u8[:], segments: const u8[:][:]) -> bool {
    if pattern.len == 0 { return segments.len == 0; }
    let parts = split(pattern, '/');
    let count = parts.len;
    for part, i in parts {
        if part == "*" { return segments.len > i; }
        guard i < segments.len else { return false; }
        let last = i == count - 1;
        if starts_with(part, "@:") {
            guard segments[i].len > 1 && segments[i][0] == '@' && route_dynamic(segments[i][1..], last) else { return false; }
        } else if part.len > 0 && part[0] == ':' {
            guard route_dynamic(segments[i], last) else { return false; }
        } else {
            guard route_literal(segments[i], part, last) else { return false; }
        }
    }
    return segments.len == count;
}

// Whether the first of Rails' routes to take method (after Rack::MethodOverride) and path, with
// Journey::Router::Utils.normalize_path's squeezed slashes and no trailing one, has its action.
fn rails_route(method: const u8[:], path: const u8[:]) -> bool {
    let verb: u8 = if method == "GET" || method == "HEAD" { 'G' } else if method == "POST" { 'P' }
                   else if method == "PATCH" { 'U' } else if method == "PUT" { 'T' } else if method == "DELETE" { 'D' } else { 0 };
    guard verb != 0 else { return false; }
    var segments: const u8[:][>..] = [];
    for part in split(path, '/') { if part.len > 0 { segments.push(part); } }
    for i in RAILS_ROUTE_COUNT {
        let entry = rails_route_entry(i);
        let space = find(entry, " ");
        let verbs = entry[..space];
        let takes = find(verbs, [verb]) >= 0 || verb == 'T' && find(verbs, "U") >= 0;
        if takes && route_matches(entry[space + 1..], segments) { return find(verbs, "!") < 0; }
    }
    return false;
}
