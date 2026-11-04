// Active Storage's records and files as Rails 8.2 keeps them for Campfire (activestorage at the
// reference's Rails revision): blob rows and their disk service files at
// <storage>/<key[0..2]>/<key[2..4]>/<key>, Marcel 1.1.0 content type identification, the Vips
// image analyzer, tracked variants (VariantWithRecord) made with libvips as image_processing does,
// variation digests and keys, the video and audio analyzers and the video previewer (ffprobe and
// ffmpeg), and the ActiveStorage verifier's signed messages.
namespace campfire;

import std;
import os;
import sqlite;
import json;
import base64;
import hash;
import database;
import auth;
import html;
import avatars;
import analyzers;

extern fn campfire_md5(data: const u8[:], out: u8[>..]&);
extern fn campfire_after(seconds: i64, out: u8[>..]&);
extern fn campfire_image_analyze(path: const u8[:], info: i64[:]) -> i32;
extern fn campfire_image_variant(path: const u8[:], width: i64, height: i64, suffix: const u8[:], out: u8[>..]&, error: u8[>..]&) -> i32;
extern fn campfire_media_run(args: const u8[:], timeout_ms: i64, max_out: i64, capture_err: bool, out: u8[>..]&, err: u8[>..]&) -> i32;
extern fn campfire_ffmpeg_exists() -> bool;
extern fn campfire_media_link(path: const u8[:], ext: const u8[:], link: u8[>..]&) -> i32;
extern fn campfire_media_unlink(link: const u8[:]);

// ActiveStorage.service_urls_expire_in
let SERVICE_URLS_EXPIRE_IN: i64 = 300;
let BINARY_CONTENT_TYPE = "application/octet-stream";
// Message::THUMBNAIL_MAX_WIDTH, THUMBNAIL_MAX_HEIGHT and THUMBNAIL_MAX_PIXELS
let THUMBNAIL_MAX_WIDTH: i64 = 1200;
let THUMBNAIL_MAX_HEIGHT: i64 = 800;
let THUMBNAIL_MAX_PIXELS: f64 = 250000000.0;

// --- Marcel ------------------------------------------------------------------------------------

// A run of marcel_text.
struct Span { at: i64 = 0, len: i64 = 0 }
// One match of a MAGIC entry, in preorder: its depth, the bytes it looks for at offset (or anywhere
// from offset up to end), and its next sibling.
struct MarcelNode { depth: i64 = 0, offset: i64 = 0, end: i64 = -1, value: Span = Span { .. }, has_value: bool = false, next: i64 = -1 }
// A key of a table, and its values: items[first..first + count], or nodes from first for MAGIC.
struct MarcelRow { key: Span = Span { .. }, first: i64 = 0, count: i64 = 0 }

// data/marcel.txt (scripts/marcel_tables.py), read on a thread's first use.
var marcel_loaded = false;
var marcel_text: u8[>..] = [];
var marcel_exts: MarcelRow[>..] = [];
var marcel_type_exts: MarcelRow[>..] = [];
var marcel_parents: MarcelRow[>..] = [];
var marcel_items: Span[>..] = [];
var marcel_magic: MarcelRow[>..] = [];
var marcel_nodes: MarcelNode[>..] = [];

fn marcel_span(text: const u8[:]) -> Span {
    let at = marcel_text.len; marcel_text.append(text); return Span { at: at, len: text.len };
}

fn marcel_hex(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    return -1;
}

fn marcel_load() {
    if marcel_loaded { return; }
    marcel_loaded = true;
    var file: u8[>..] = [];
    if !read_file("data/marcel.txt", file) { write_stderr("Cannot read data/marcel.txt: content types fall back to the declared type\n"); return; }
    var stack: i64[>..] = [];
    for line in split(file, '\n') {
        if line.len < 2 { continue; }
        let fields = split(line, '\t');
        let kind = fields[0];
        if kind == "e" && fields.len == 3 {
            let key = marcel_span(fields[1]); let value = marcel_span(fields[2]);
            marcel_exts.push(MarcelRow { key: key, first: value.at, count: value.len });
        } else if (kind == "t" || kind == "p") && fields.len >= 2 {
            let row = MarcelRow { key: marcel_span(fields[1]), first: marcel_items.len, count: fields.len - 2 };
            for i in fields.len - 2 { marcel_items.push(marcel_span(fields[i + 2])); }
            if kind == "t" { marcel_type_exts.push(row); } else { marcel_parents.push(row); }
        } else if kind == "m" && fields.len == 2 {
            marcel_magic.push(MarcelRow { key: marcel_span(fields[1]), first: marcel_nodes.len, count: 0 });
            stack.clear();
        } else if kind == "n" && fields.len == 5 {
            let depth, d_ok = parse_int(fields[1]); let offset, o_ok = parse_int(fields[2]);
            let end, e_ok = parse_int(fields[3]);
            var node = MarcelNode { depth: depth, offset: offset, end: if e_ok { end } else { -1 }, .. };
            if fields[4] != "-" {
                var bytes: u8[>..] = [];
                if fields[4] != "=" {
                    var i: i64 = 0;
                    while i + 1 < fields[4].len { bytes.push((marcel_hex(fields[4][i]) * 16 + marcel_hex(fields[4][i + 1])) as! u8); i += 2; }
                }
                node.value = marcel_span(bytes); node.has_value = true;
            }
            let index = marcel_nodes.len;
            // The previous node at this depth, still open on the stack, gets this one as its next sibling.
            while stack.len > depth + 1 { stack.pop(); }
            if stack.len == depth + 1 { marcel_nodes[stack[depth]].next = index; stack[depth] = index; }
            else { stack.push(index); }
            marcel_nodes.push(node);
        }
    }
}

fn marcel_at(s: Span) -> const u8[:] { return marcel_text[s.at..s.at + s.len]; }

fn marcel_find(rows: const MarcelRow[:], key: const u8[:]) -> i64 {
    var lo: i64 = 0; var hi = rows.len;
    while lo < hi {
        let mid = (lo + hi) / 2;
        let c = compare(marcel_at(rows[mid].key), key);
        if c == 0 { return mid; }
        if c < 0 { lo = mid + 1; } else { hi = mid; }
    }
    return -1;
}

// Marcel::Magic.by_extension: case-insensitive, with or without the leading dot; "" for none.
fn marcel_by_extension(extension: const u8[:]) -> u8[>..] {
    marcel_load();
    var ext = str(if starts_with(extension,".") { extension[1..] } else { extension });
    to_lower(ext);
    let i = marcel_find(marcel_exts, ext);
    if i < 0 { return []; }
    return str(marcel_text[marcel_exts[i].first..marcel_exts[i].first + marcel_exts[i].count]);
}

// Marcel::MimeType.for(extension:)
fn content_type_for_extension(extension: const u8[:]) -> u8[>..] {
    let found = marcel_by_extension(extension);
    return if found.len > 0 { found } else { str(BINARY_CONTENT_TYPE) };
}

// Marcel::Magic.new(type).extensions.first, "" for none.
fn marcel_first_extension(content_type: const u8[:]) -> u8[>..] {
    marcel_load();
    let i = marcel_find(marcel_type_exts, content_type);
    if i < 0 || marcel_type_exts[i].count == 0 { return []; }
    return str(marcel_at(marcel_items[marcel_type_exts[i].first]));
}

recursive fn marcel_child(child: const u8[:], parent: const u8[:], depth: i64 = 0) -> bool {
    if child == parent { return true; }
    if depth > 16 { return false; }
    let i = marcel_find(marcel_parents, child);
    if i < 0 { return false; }
    for k in marcel_parents[i].count {
        if marcel_child(marcel_at(marcel_items[marcel_parents[i].first + k]), parent, depth + 1) { return true; }
    }
    return false;
}

// IO#read(length) after skipping offset bytes: false at EOF.
fn marcel_read(data: const u8[:], offset: i64, length: i64) -> const u8[:], bool {
    if length == 0 { return data[..0], true; }
    if offset >= data.len { return data[..0], false; }
    return data[offset..min(offset + length, data.len)], true;
}

recursive fn marcel_matches(data: const u8[:], first: i64) -> bool {
    var i = first;
    while i >= 0 {
        let node = marcel_nodes[i];
        if node.has_value {
            let value = marcel_at(node.value);
            var hit = false;
            if node.end >= 0 {
                let window, read = marcel_read(data, node.offset, node.end - node.offset + value.len);
                hit = read && (value.len == 0 || find(window, value) >= 0);
            } else {
                let bytes, read = marcel_read(data, node.offset, value.len);
                hit = read && bytes == value;
            }
            if hit {
                let has_children = i + 1 < marcel_nodes.len && marcel_nodes[i + 1].depth == node.depth + 1;
                if !has_children || marcel_matches(data, i + 1) { return true; }
            }
        }
        i = node.next;
    }
    return false;
}

// Marcel::Magic.by_magic: the first entry whose matches hit, downcased; "" for none.
fn marcel_by_magic(data: const u8[:]) -> u8[>..] {
    marcel_load();
    for row, n in marcel_magic {
        let next = if n + 1 < marcel_magic.len { marcel_magic[n + 1].first } else { marcel_nodes.len };
        if row.first < next && marcel_matches(data, row.first) {
            var out = str(marcel_at(row.key)); to_lower(out); return out;
        }
    }
    return [];
}

// Declared types are downcased, stripped of parameters, and ignored when binary.
fn marcel_declared(declared: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for c in declared {
        if c == ';' || c == ',' || c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 11 || c == 12 { break; }
        out.push(c);
    }
    to_lower(out);
    if find(out, "/") < 0 || out == BINARY_CONTENT_TYPE { out.clear(); }
    return out;
}

// Marcel::MimeType.for(io, name:, declared_type:), as ActiveStorage::Blob#extract_content_type
// calls it: the magic, declared and filename candidates, each later one winning only where it is a
// child type of the pick so far.
fn identify_content_type(data: const u8[:], filename: const u8[:], declared: const u8[:]) -> u8[>..] {
    var candidates: u8[][>..] = [];
    candidates.push(marcel_by_magic(data));
    candidates.push(marcel_declared(declared));
    candidates.push(marcel_by_extension(extname(filename)));
    candidates.push(str(BINARY_CONTENT_TYPE));
    var unique: u8[][>..] = [];
    for c in candidates {
        if c.len == 0 { continue; }
        var seen = false; for u in unique { if u == c { seen = true; } }
        if !seen { unique.push(copy(c)); }
    }
    var pick: u8[>..] = [];
    for c, i in unique { if i == 0 || marcel_child(c, pick) { pick = str(c); } }
    return pick;
}

// --- Filenames ---------------------------------------------------------------------------------

// File.basename
fn basename(path: const u8[:]) -> const u8[:] {
    var end = path.len;
    while end > 0 && path[end - 1] == '/' { end -= 1; }
    if end == 0 { return if path.len == 0 { path } else { path[..1] }; }
    var start = end;
    while start > 0 && path[start - 1] != '/' { start -= 1; }
    return path[start..end];
}

// File.extname: the last "." of the basename and what follows, past any leading dots.
fn extname(path: const u8[:]) -> const u8[:] {
    let base = basename(path);
    var lead: i64 = 0;
    while lead < base.len && base[lead] == '.' { lead += 1; }
    var i = base.len - 1;
    while i >= lead { if base[i] == '.' { return base[i..]; } i -= 1; }
    return base[..0];
}

// ActiveStorage::Filename#extension
fn filename_extension(filename: const u8[:]) -> const u8[:] {
    let ext = extname(filename);
    return if ext.len > 0 { ext[1..] } else { ext };
}

// ActiveStorage::Filename#base: File.basename(filename, extension_with_delimiter).
fn filename_base(filename: const u8[:]) -> const u8[:] {
    let base = basename(filename); let ext = extname(filename);
    if ext.len > 0 && base.len > ext.len && ends_with(base, ext) { return base[..base.len - ext.len]; }
    return base;
}

// The bytes of text as UTF-8, each invalid sequence replaced by U+FFFD (String#scrub).
fn utf8_scrub(text: const u8[:]) -> u8[>..] {
    var out: u8[>..] = []; var i: i64 = 0;
    while i < text.len {
        let c = text[i];
        var n: i64 = if c < 128 { 1 } else if c >= 194 && c < 224 { 2 } else if c >= 224 && c < 240 { 3 } else if c >= 240 && c < 245 { 4 } else { 0 };
        var valid = n > 0 && i + n <= text.len;
        if valid && n > 1 {
            for k in n - 1 { if text[i + 1 + k] < 128 || text[i + 1 + k] >= 192 { valid = false; } }
            if valid && n == 3 && ((c == 224 && text[i + 1] < 160) || (c == 237 && text[i + 1] >= 160)) { valid = false; }
            if valid && n == 4 && ((c == 240 && text[i + 1] < 144) || (c == 244 && text[i + 1] >= 144)) { valid = false; }
        }
        if valid { out.append(text[i..i + n]); i += n; }
        else { out.append("\xEF\xBF\xBD"); i += 1; }
    }
    return out;
}

// ActiveStorage::Filename#sanitized: valid UTF-8, stripped, with path and shell characters and
// U+202E as "-".
fn sanitized_filename(filename: const u8[:]) -> u8[>..] {
    let text = utf8_scrub(filename);
    var start: i64 = 0; var end = text.len;
    while start < end && (text[start] == ' ' || (text[start] >= 9 && text[start] <= 13) || text[start] == 0) { start += 1; }
    while end > start && (text[end - 1] == ' ' || (text[end - 1] >= 9 && text[end - 1] <= 13) || text[end - 1] == 0) { end -= 1; }
    var out: u8[>..] = []; var i = start;
    while i < end {
        if i + 3 <= end && text[i..i + 3] == "\xE2\x80\xAE" { out.push('-'); i += 3; continue; }
        let c = text[i];
        out.push(if find("%$|:;/<>?*\"\t\r\n\\", [c]) >= 0 { '-' } else { c });
        i += 1;
    }
    return out;
}

// Rack::Multipart's normalize_filename: percent-decoded when every % starts an escape, scrubbed,
// and the last of its / or \ separated parts.
fn upload_filename(raw: const u8[:]) -> u8[>..] {
    var decoded: u8[>..] = [];
    var escapes = true; var i: i64 = 0;
    while i < raw.len {
        if raw[i] == '%' && !(i + 2 < raw.len && hex_digit(raw[i + 1]) >= 0 && hex_digit(raw[i + 2]) >= 0) { escapes = false; }
        i += 1;
    }
    i = 0;
    while i < raw.len {
        if escapes && raw[i] == '%' { decoded.push((hex_digit(raw[i + 1]) * 16 + hex_digit(raw[i + 2])) as! u8); i += 3; }
        else { decoded.push(raw[i]); i += 1; }
    }
    let text = utf8_scrub(decoded);
    var end = text.len;
    while end > 0 && (text[end - 1] == '/' || text[end - 1] == '\\') { end -= 1; }
    var start = end;
    while start > 0 && text[start - 1] != '/' && text[start - 1] != '\\' { start -= 1; }
    return str(text[start..end]);
}

// A quoted filename parameter as Rack reads it: \" is a quote, any other escape stays as written.
fn unquote_filename(value: const u8[:]) -> u8[>..] {
    var out: u8[>..] = []; var i: i64 = 0;
    while i < value.len {
        if value[i] == '\\' && i + 1 < value.len && value[i + 1] == '"' { out.push('"'); i += 2; }
        else { out.push(value[i]); i += 1; }
    }
    return out;
}

fn percent_escape(out: u8[>..]&, text: const u8[:], keep: const u8[:]) {
    let hex = "0123456789ABCDEF";
    for c in text {
        if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || find(keep, [c]) >= 0 { out.push(c); }
        else { out.push('%'); out.push(hex[c >> 4]); out.push(hex[c & 15]); }
    }
}

// Journey::Router::Utils.escape_segment
fn escape_segment(text: const u8[:]) -> u8[>..] { var out: u8[>..] = []; percent_escape(out, text, "-._~!$&'()*+,;=:@"); return out; }
// Journey::Router::Utils.escape_path
fn escape_path(text: const u8[:]) -> u8[>..] { var out: u8[>..] = []; percent_escape(out, text, "-._~!$&'()*+,;=:@/"); return out; }

// I18n.transliterate for the ASCII filename of Content-Disposition: Latin-1 and a few more letters
// by their approximations, anything else "?".
fn transliterate(text: const u8[:]) -> u8[>..] {
    // U+00C0 to U+00FF, "?" where the approximation takes two letters (handled first) or there is none.
    let single = "AAAAAA?CEEEEIIIIDNOOOOOxOUUUUY??aaaaaa?ceeeeiiiidnooooo/ouuuuy?y";
    var out: u8[>..] = []; var i: i64 = 0;
    while i < text.len {
        let c = text[i];
        if c < 128 { out.push(c); i += 1; continue; }
        var n: i64 = if c >= 240 { 4 } else if c >= 224 { 3 } else { 2 };
        n = min(n, text.len - i);
        var code: i64 = 0;
        let b1: i64 = if n > 1 { text[i + 1] & 63 } else { 0 };
        let b2: i64 = if n > 2 { text[i + 2] & 63 } else { 0 };
        let lead: i64 = c;
        if n == 2 { code = (lead & 31) << 6 | b1; }
        else if n == 3 { code = (lead & 15) << 12 | b1 << 6 | b2; }
        if code == 0xC6 { out.append("AE"); }
        else if code == 0xE6 { out.append("ae"); }
        else if code == 0xDE { out.append("Th"); }
        else if code == 0xFE { out.append("th"); }
        else if code == 0xDF { out.append("ss"); }
        else if code == 0x152 { out.append("OE"); }
        else if code == 0x153 { out.append("oe"); }
        else if code >= 0xC0 && code <= 0xFF { out.push(single[code - 0xC0]); }
        else { out.push('?'); }
        i += n;
    }
    return out;
}

// ActionDispatch::Http::ContentDisposition.format, as ActiveStorage::Service#content_disposition_with
// gives it: anything but "attachment" is "inline".
fn content_disposition(disposition: const u8[:], filename: const u8[:]) -> u8[>..] {
    var out = str(if disposition == "attachment" { "attachment" } else { "inline" }, "; filename=\"");
    percent_escape(out, transliterate(filename), " !#$+.^_`|~-");
    out.append("\"; filename*=UTF-8''");
    percent_escape(out, filename, "!#$&+.^_`|~-");
    return out;
}

// --- Content types -----------------------------------------------------------------------------

// ActiveStorage.variable_content_types, less what config/initializers/vips.rb removes.
fn variable_content_type(content_type: const u8[:]) -> bool {
    return content_type == "image/png" || content_type == "image/gif" || content_type == "image/jpeg" || content_type == "image/tiff" ||
        content_type == "image/webp" || content_type == "image/avif" || content_type == "image/heic" || content_type == "image/heif";
}

// ActiveStorage.web_image_content_types with load_defaults 8.2.
fn web_image_content_type(content_type: const u8[:]) -> bool {
    return content_type == "image/png" || content_type == "image/jpeg" || content_type == "image/gif" || content_type == "image/webp";
}

fn serve_as_binary(content_type: const u8[:]) -> bool {
    return content_type == "text/html" || content_type == "image/svg+xml" || content_type == "application/postscript" ||
        content_type == "application/x-shockwave-flash" || content_type == "text/xml" || content_type == "application/xml" ||
        content_type == "application/xhtml+xml" || content_type == "application/mathml+xml" || content_type == "text/cache-manifest";
}

fn allowed_inline(content_type: const u8[:]) -> bool {
    return content_type == "image/webp" || content_type == "image/avif" || content_type == "image/png" || content_type == "image/gif" ||
        content_type == "image/jpeg" || content_type == "image/tiff" || content_type == "image/bmp" ||
        content_type == "image/vnd.adobe.photoshop" || content_type == "image/vnd.microsoft.icon" || content_type == "application/pdf";
}

// Blob#content_type_for_serving
fn content_type_for_serving(content_type: const u8[:]) -> const u8[:] {
    return if serve_as_binary(content_type) { BINARY_CONTENT_TYPE } else { content_type };
}

// Blob#forced_disposition_for_serving, or the one asked for.
fn disposition_for_serving(content_type: const u8[:], asked: const u8[:]) -> const u8[:] {
    if serve_as_binary(content_type) || !allowed_inline(content_type) { return "attachment"; }
    return if asked == "attachment" { "attachment" } else { "inline" };
}

// Blob#video? and Blob#audio?
fn video_content_type(content_type: const u8[:]) -> bool { return starts_with(content_type, "video"); }
fn audio_content_type(content_type: const u8[:]) -> bool { return starts_with(content_type, "audio"); }

// The types ffprobe analyzes: VideoAnalyzer's and AudioAnalyzer's.
fn probed_content_type(content_type: const u8[:]) -> bool { return video_content_type(content_type) || audio_content_type(content_type); }

// Blob#previewable?: VideoPreviewer.accept?, a video while `ffmpeg -version` succeeds. The PDF
// previewers never accept, as the Rails image has neither poppler nor mupdf.
fn previewable_content_type(content_type: const u8[:]) -> bool { return video_content_type(content_type) && campfire_ffmpeg_exists(); }

// --- The ActiveStorage verifier ----------------------------------------------------------------

// ActiveStorage.verifier.generate(data, purpose:, expires_at:): data is JSON; expiry "" for none.
fn storage_generate(data: const u8[:], purpose: const u8[:], expiry: const u8[:], key: const u8[:]) -> u8[>..] {
    var envelope: u8[>..] = []; format(envelope, "{\"_rails\":{\"data\":", data);
    if expiry.len > 0 { envelope.append(",\"exp\":"); json::format_string(envelope, expiry); }
    envelope.append(",\"pur\":"); json::format_string(envelope, purpose); envelope.append("}}");
    var out: u8[>..] = []; base64::encode(out, envelope); let mac = hmac_sha1(key, out); out.append("--");
    let digits = "0123456789abcdef"; for c in mac { out.push(digits[c >> 4]); out.push(digits[c & 15]); }
    return out;
}

// ActiveStorage.verifier.verified(token, purpose:): the data's JSON text into data, false for a bad
// signature, another purpose or an expired message.
fn storage_verify(token: const u8[:], purpose: const u8[:], key: const u8[:], now: const u8[:], data: u8[>..]&) -> bool {
    guard token.len < 16384 else { return false; }
    let split = find(token, "--");
    guard split > 0 && token.len - split - 2 == 40 else { return false; }
    var supplied: u8[20] = [0; 20];
    for i in 20 {
        let hi = hex_digit(token[split + 2 + i * 2]); let lo = hex_digit(token[split + 3 + i * 2]);
        guard hi >= 0 && lo >= 0 else { return false; }
        supplied[i] = (hi * 16 + lo) as u8;
    }
    let payload = token[..split];
    guard hash::equal(supplied, hmac_sha1(key, payload)) else { return false; }
    var text: u8[>..] = [];
    guard base64::decode(text, payload) else { return false; }
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let root, error = json::parse(text, nodes, strings);
    let envelope = json::member(root, "_rails");
    guard envelope else { return false; }
    let actual, has_purpose = json::as_string(json::member(envelope, "pur"));
    guard has_purpose && actual == purpose else { return false; }
    let expiry = json::member(envelope, "exp");
    if expiry {
        match expiry.val {
            Null => {},
            Str s => { guard s.s.len == 24 && now.len == 24 && compare(s.s, now) > 0 else { return false; } },
            _ => { return false; },
        }
    }
    // The data is the text between "data": and the envelope's next key, re-read from the decoded
    // JSON: the verifier signs exactly what generate wrote.
    let start = find(text, "{\"_rails\":{\"data\":");
    guard start == 0 else { return false; }
    let rest = text[18..];
    var end = rfind(rest, ",\"pur\":");
    let exp_at = rfind(rest, ",\"exp\":");
    if exp_at >= 0 && exp_at < end { end = exp_at; }
    guard end > 0 else { return false; }
    data.append(rest[..end]);
    return true;
}

// blob.signed_id: purpose "blob_id", no expiry.
fn signed_blob_id(blob: i64, key: const u8[:]) -> u8[>..] { return storage_generate(str(blob), "blob_id", "", key); }

// ActiveStorage::Blob.find_signed: the blob id, or 0.
fn verify_blob_id(token: const u8[:], key: const u8[:], now: const u8[:]) -> i64 {
    var data: u8[>..] = [];
    guard storage_verify(token, "blob_id", key, now, data) else { return 0; }
    let id, valid = parse_int(data);
    return if valid && id > 0 { id } else { 0 };
}

// --- Variations --------------------------------------------------------------------------------

// The transformations Campfire's named variants and previews use, after default_to: format (a
// Ruby Symbol where the app names it, a String where a URL key or the blob's extension gives it),
// then resize_to_limit, if any (-1 for a nil dimension). bare is a decoded key with neither, whose
// preview is the preview image itself (Preview#variant? is false).
struct Variation { format: u8[..32] = [], symbol: bool = false, resize: bool = false, width: i64 = 0, height: i64 = 0, bare: bool = false }

fn named_variation(format: const u8[:], width: i64, height: i64) -> Variation {
    return Variation { format: format, symbol: true, resize: true, width: width, height: height };
}

// Blob#default_variant_format for a blob of this type and filename: its own format for web
// images (String), :png otherwise.
fn default_variant_format(content_type: const u8[:], filename: const u8[:]) -> Variation {
    if web_image_content_type(content_type) {
        let ext = filename_extension(filename);
        if ext.len > 0 && ext.len <= 32 && marcel_by_extension(ext) == content_type { return Variation { format: ext, .. }; }
        let first = marcel_first_extension(content_type);
        if first.len > 0 && first.len <= 32 { return Variation { format: first, .. }; }
    }
    return Variation { format: "png", symbol: true, .. };
}

// The attachment's :poster variant, which a video's preview(:poster) makes of its preview image.
fn poster_variation() -> Variation { return named_variation("webp", THUMBNAIL_MAX_WIDTH, THUMBNAIL_MAX_HEIGHT); }

// Message#too_many_pixels_to_preview? for an image or a video with this metadata: no width or
// height (the analyzer couldn't read its header), or more than THUMBNAIL_MAX_PIXELS.
fn too_many_pixels_to_preview(metadata: const u8[:]) -> bool {
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let root, error = json::parse(metadata, nodes, strings);
    let width, has_width = json::as_f64(json::member(root, "width"));
    let height, has_height = json::as_f64(json::member(root, "height"));
    return !has_width || !has_height || width * height > THUMBNAIL_MAX_PIXELS;
}

// attachment.representation(:thumb) for a variable blob: { format: <default>, resize_to_limit: [1200, 800] }.
fn thumb_variation(content_type: const u8[:], filename: const u8[:]) -> Variation {
    var v = default_variant_format(content_type, filename);
    v.resize = true; v.width = THUMBNAIL_MAX_WIDTH; v.height = THUMBNAIL_MAX_HEIGHT;
    return v;
}

fn marshal_long(out: u8[>..]&, n: i64) {
    if n == 0 { out.push(0); return; }
    if n > 0 && n < 123 { out.push((n + 5) as! u8); return; }
    if n < 0 && n > -124 { out.push(((n - 5) & 255) as! u8); return; }
    var bytes: u8[>..] = []; var x = n;
    for i in 8 {
        bytes.push((x & 255) as! u8); x = x >> 8;
        if x == 0 { out.push((i + 1) as! u8); out.append(bytes); return; }
        if x == -1 { out.push(((-(i + 1)) & 255) as! u8); out.append(bytes); return; }
    }
}

fn marshal_symbol(out: u8[>..]&, name: const u8[:]) { out.push(':'); marshal_long(out, name.len); out.append(name); }

// Variation#digest: SHA1.base64digest(Marshal.dump(transformations)).
fn variation_digest(v: const Variation&) -> u8[>..] {
    var dump: u8[>..] = []; dump.append("\x04\x08{"); marshal_long(dump, if v.resize { 2 } else { 1 });
    marshal_symbol(dump, "format");
    if v.symbol { marshal_symbol(dump, v.format); }
    else { dump.append("I\""); marshal_long(dump, v.format.len); dump.append(v.format); marshal_long(dump, 1); marshal_symbol(dump, "E"); dump.push('T'); }
    if v.resize {
        marshal_symbol(dump, "resize_to_limit"); dump.push('['); marshal_long(dump, 2);
        if v.width < 0 { dump.push('0'); } else { dump.push('i'); marshal_long(dump, v.width); }
        if v.height < 0 { dump.push('0'); } else { dump.push('i'); marshal_long(dump, v.height); }
    }
    var out: u8[>..] = []; base64::encode(out, hash::sha1(dump)); return out;
}

fn variation_json(v: const Variation&) -> u8[>..] {
    var out: u8[>..] = []; out.append("{\"format\":"); json::format_string(out, v.format);
    if v.resize {
        out.append(",\"resize_to_limit\":[");
        if v.width < 0 { out.append("null"); } else { format(out, v.width); }
        out.push(',');
        if v.height < 0 { out.append("null"); } else { format(out, v.height); }
        out.push(']');
    }
    out.push('}'); return out;
}

// Variation#key
fn variation_key(v: const Variation&, key: const u8[:]) -> u8[>..] { return storage_generate(variation_json(v), "variation", "", key); }

// Variation.decode(key).default_to(blob's defaults): false for a bad signature, and invalid for a
// transformation this server doesn't make.
fn decode_variation(token: const u8[:], key: const u8[:], now: const u8[:], defaults: const Variation&) -> Variation, bool, bool {
    var data: u8[>..] = [];
    var v = defaults;
    guard storage_verify(token, "variation", key, now, data) else { return v, false, false; }
    v.resize = false;
    var invalid = false;
    var scratch: u8[>..] = [];
    var r = json::reader(data);
    guard json::peek(r) == '{' else { return v, true, true; }
    var members: i64 = 0;
    json::each_member(r) { name =>
        members += 1;
        if name == "format" {
            if json::peek(r) == '"' {
                let text = json::read_string(r, scratch);
                if text.len > 0 && text.len <= 32 { v.format = text; v.symbol = false; } else { invalid = true; }
            } else { json::skip(r); invalid = true; }
        } else if name == "resize_to_limit" {
            var dims: i64[>..] = [];
            if json::peek(r) == '[' {
                json::each_element(r) {
                    if json::peek(r) == 'n' { json::skip(r); dims.push(-1); }
                    else { let n = json::read_int(r); if n >= 0 && n < 100000 { dims.push(n); } else { invalid = true; } }
                };
            } else { json::skip(r); invalid = true; }
            if dims.len == 2 && (dims[0] >= 0 || dims[1] >= 0) { v.resize = true; v.width = dims[0]; v.height = dims[1]; } else { invalid = true; }
        } else { json::skip(r); invalid = true; }
    };
    if !json::finish(r) { invalid = true; }
    v.bare = members == 0;
    // Variation#format checks the format against Marcel's extensions.
    if !invalid && marcel_by_extension(v.format).len == 0 { invalid = true; }
    return v, true, invalid;
}

// --- Blobs -------------------------------------------------------------------------------------

fn blob_file(storage: const u8[:], key: const u8[:]) -> u8[>..] {
    return str(storage, "/", key[..2], "/", key[2..4], "/", key);
}

// ActiveStorage::Blob.generate_unique_secure_token: 28 base36 characters.
fn new_blob_key() -> u8[>..] {
    let alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";
    var out: u8[>..] = []; var bytes: u8[64] = [0; 64];
    while out.len < 28 {
        hash::random_bytes(bytes);
        for b in bytes { if b < 252 && out.len < 28 { out.push(alphabet[b % 36]); } }
    }
    return out;
}

// DiskService#upload: the file at the key's path, written whole or not at all.
fn write_blob_file(storage: const u8[:], key: const u8[:], data: const u8[:]) -> bool {
    make_dir(storage); make_dir(str(storage, "/", key[..2])); make_dir(str(storage, "/", key[..2], "/", key[2..4]));
    return write_file_atomic(blob_file(storage, key), data);
}

fn delete_blob_file(storage: const u8[:], key: const u8[:]) {
    if storage_key_valid(key) { delete_file(blob_file(storage, key)); }
}

// Blob#compute_checksum_in_chunks: the MD5, Base64.
fn blob_checksum(data: const u8[:]) -> u8[>..] {
    var digest: u8[>..] = []; campfire_md5(data, digest);
    var out: u8[>..] = []; base64::encode(out, digest); return out;
}

// ImageAnalyzer::Vips#metadata for the file at path, as blob.analyze merges it: width and height
// for an image libvips reads, nothing otherwise; analyzed is added after.
fn image_metadata(path: const u8[:]) -> u8[>..] {
    var info: i64[2] = [0; 2];
    if campfire_image_analyze(path, info) != 1 { return []; }
    return str(",\"width\":", info[0], ",\"height\":", info[1]);
}

// metadata.merge(analyzer.metadata.merge(analyzed: true)) for a blob just identified: images by
// the Vips analyzer, the types no analyzer accepts by the null analyzer. Videos and audio are
// ffprobe's, on a media thread (analyze_blob).
fn analyzed_metadata(path: const u8[:], content_type: const u8[:]) -> u8[>..] {
    let image = if starts_with(content_type, "image") { image_metadata(path) } else { str("") };
    return str("{\"identified\":true", image, ",\"analyzed\":true}");
}

// The blob row of create_after_unfurling!, whose file is already written.
fn insert_blob(db, key: const u8[:], filename: const u8[:], content_type: const u8[:], metadata: const u8[:], size: i64, checksum: const u8[:], now: const u8[:]) -> i64 {
    sql_rows(db, "INSERT INTO active_storage_blobs(key,filename,content_type,metadata,service_name,byte_size,checksum,created_at) VALUES(?,?,?,?,'local',?,?,?)",
        [sql_text(key), sql_text(filename), sql_text(content_type), sql_text(metadata), sql_text(size), sql_text(checksum), sql_text(now)]);
    return sqlite::last_insert_rowid(db);
}

fn attach_blob(db, name: const u8[:], record_type: const u8[:], record: i64, blob: i64, now: const u8[:]) {
    sql_rows(db, "INSERT INTO active_storage_attachments(name,record_type,record_id,blob_id,created_at) VALUES(?,?,?,?,?)",
        [sql_text(name), sql_text(record_type), sql_text(record), sql_text(blob), sql_text(now)]);
}

// An uploaded file, written to the service and identified, before its rows are saved.
struct Upload { key: u8[..32] = [], filename: u8[..1024] = [], content_type: u8[..256] = [], metadata: u8[..512] = [], size: i64 = 0, checksum: u8[..32] = [] }

// The file half of Blob.build_after_unfurling for an uploaded file: written, checksummed,
// identified and, for an image or a type no analyzer accepts, analyzed (as
// Message#process_attachment does at once and AnalyzeJob soon after for other attachments). False
// when the file can't be written, or its name is past 1 KiB.
fn stage_upload(storage: const u8[:], data: const u8[:], raw_filename: const u8[:], declared: const u8[:], upload: Upload&) -> bool {
    let filename = upload_filename(raw_filename);
    guard filename.len <= 1024 else { return false; }
    let key = new_blob_key();
    guard write_blob_file(storage, key, data) else { return false; }
    var content_type = identify_content_type(data, filename, declared);
    if content_type.len > 256 { content_type = str(BINARY_CONTENT_TYPE); }
    // A video or audio file is analyzed with ffprobe on a media thread once its rows are saved.
    let metadata = if probed_content_type(content_type) { str("{\"identified\":true}") } else { analyzed_metadata(blob_file(storage, key), content_type) };
    upload = Upload { key: key, filename: filename, content_type: content_type, metadata: metadata, size: data.len, checksum: blob_checksum(data) };
    return true;
}

// The rows of an attachment: the blob, then the attachment (record.attachment = upload, saved).
fn save_upload(db, upload: const Upload&, name: const u8[:], record_type: const u8[:], record: i64, now: const u8[:]) -> i64 {
    let blob = insert_blob(db, upload.key, upload.filename, upload.content_type, upload.metadata, upload.size, upload.checksum, now);
    attach_blob(db, name, record_type, record, blob, now);
    return blob;
}

// Deletes the attachments `condition` selects and, once nothing else holds them, their blobs,
// variants and preview images (Blob#purge). The blobs' keys go to `keys`, for their files to be
// deleted after the transaction commits.
fn purge_attachments(db, condition: const u8[:], args: u8[][], keys: u8[][>..]&) {
    let blobs = sql_rows(db, str("SELECT DISTINCT blob_id FROM active_storage_attachments WHERE ", condition), copy(args));
    sql_rows(db, str("DELETE FROM active_storage_attachments WHERE ", condition), copy(args));
    for row in blobs { purge_blob(db, cell(row, 0), keys); }
}

// Blob#purge for a blob nothing holds: its preview image (a video's, made by Rails), its variants,
// and itself.
fn purge_blob(db, blob: const u8[:], keys: u8[][>..]&) {
    if sql_number(db, "SELECT count(*) FROM active_storage_attachments WHERE blob_id=?", [sql_text(blob)]) > 0 { return; }
    let previews = sql_rows(db, "SELECT DISTINCT blob_id FROM active_storage_attachments WHERE record_type='ActiveStorage::Blob' AND name='preview_image' AND record_id=?", [sql_text(blob)]);
    sql_rows(db, "DELETE FROM active_storage_attachments WHERE record_type='ActiveStorage::Blob' AND name='preview_image' AND record_id=?", [sql_text(blob)]);
    purge_blob_rows(db, blob, keys);
    for row in previews {
        if sql_number(db, "SELECT count(*) FROM active_storage_attachments WHERE blob_id=?", [sql_text(cell(row, 0))]) == 0 { purge_blob_rows(db, cell(row, 0), keys); }
    }
}

fn purge_blob_rows(db, blob: const u8[:], keys: u8[][>..]&) {
    let variants = sql_rows(db, "SELECT va.id,vb.id,vb.key FROM active_storage_variant_records v JOIN active_storage_attachments va ON va.record_type='ActiveStorage::VariantRecord' AND va.name='image' AND va.record_id=v.id JOIN active_storage_blobs vb ON vb.id=va.blob_id WHERE v.blob_id=?", [sql_text(blob)]);
    for variant in variants {
        sql_rows(db, "DELETE FROM active_storage_attachments WHERE id=?", [sql_text(cell(variant, 0))]);
        sql_rows(db, "DELETE FROM active_storage_blobs WHERE id=?", [sql_text(cell(variant, 1))]);
        keys.push(str(cell(variant, 2)));
    }
    sql_rows(db, "DELETE FROM active_storage_variant_records WHERE blob_id=?", [sql_text(blob)]);
    for row in sql_rows(db, "SELECT key FROM active_storage_blobs WHERE id=?", [sql_text(blob)]) { keys.push(str(cell(row, 0))); }
    sql_rows(db, "DELETE FROM active_storage_blobs WHERE id=?", [sql_text(blob)]);
}

fn delete_blob_files(storage: const u8[:], keys: const u8[][:]) {
    for key in keys { delete_blob_file(storage, key); }
}

// --- Variants ----------------------------------------------------------------------------------

// The variant's image blob: its id, key, filename and content type; id 0 when it hasn't been made.
struct VariantBlob { id: i64 = 0, key: u8[..32] = [], filename: u8[..1024] = [], content_type: u8[..256] = [] }

fn find_variant(db, blob: i64, digest: const u8[:]) -> VariantBlob {
    var out = VariantBlob { .. };
    for row in sql_rows(db, "SELECT vb.id,vb.key,vb.filename,vb.content_type FROM active_storage_variant_records v JOIN active_storage_attachments va ON va.record_type='ActiveStorage::VariantRecord' AND va.name='image' AND va.record_id=v.id JOIN active_storage_blobs vb ON vb.id=va.blob_id WHERE v.blob_id=? AND v.variation_digest=? ORDER BY va.id LIMIT 1", [sql_text(blob), str(digest)]) {
        let id, valid = parse_int(cell(row, 0));
        if valid && cell(row, 1).len <= 32 && cell(row, 3).len <= 256 && cell(row, 2).len <= 1024 { out = VariantBlob { id: id, key: cell(row, 1), filename: cell(row, 2), content_type: cell(row, 3) }; }
    }
    return out;
}

// The made variant before its rows are saved.
struct StagedVariant { key: u8[..32] = [], filename: u8[..1024] = [], content_type: u8[..256] = [], metadata: u8[..256] = [], size: i64 = 0, checksum: u8[..32] = [] }

// The file half of VariantWithRecord#process: the source blob's file transformed and written to
// the service as <base>.<format>, analyzed as AnalyzeJob would. False with why in error.
fn transform_variant(storage: const u8[:], source_key: const u8[:], source_filename: const u8[:], v: const Variation&, staged: StagedVariant&, error: u8[>..]&) -> bool {
    guard storage_key_valid(source_key) else { error.append("invalid key"); return false; }
    var format = str(v.format); to_lower(format);
    var bytes: u8[>..] = [];
    guard campfire_image_variant(blob_file(storage, source_key), if v.resize { v.width } else { -1 }, if v.resize { v.height } else { -1 },
        str(".", format), bytes, error) == 1 else { return false; }
    let key = new_blob_key();
    guard write_blob_file(storage, key, bytes) else { error.append("cannot write the variant"); return false; }
    var content_type = content_type_for_extension(format);
    if content_type.len > 256 { content_type = str(BINARY_CONTENT_TYPE); }
    let metadata = analyzed_metadata(blob_file(storage, key), content_type);
    staged = StagedVariant { key: key, filename: str(filename_base(source_filename), ".", format), content_type: content_type, metadata: metadata,
        size: bytes.len, checksum: blob_checksum(bytes) };
    return true;
}

// The record half: create_or_find_by!(variation_digest:) with the image attached. False when
// another writer recorded it first; the caller then deletes the staged file.
fn record_variant(db, blob: i64, digest: const u8[:], staged: const StagedVariant&, now: const u8[:]) -> bool {
    if find_variant(db, blob, digest).id != 0 { return false; }
    sql_rows(db, "INSERT INTO active_storage_variant_records(blob_id,variation_digest) VALUES(?,?)", [sql_text(blob), str(digest)]);
    let record = sqlite::last_insert_rowid(db);
    let image = insert_blob(db, staged.key, staged.filename, staged.content_type, staged.metadata, staged.size, staged.checksum, now);
    attach_blob(db, "image", "ActiveStorage::VariantRecord", record, image, now);
    return true;
}

// --- Video and audio ---------------------------------------------------------------------------

// How long ffprobe may read a file's streams, and ffmpeg draw a preview frame, before it is killed:
// ffmpeg's is TimeLimitedVideoPreviewer::TIME_LIMIT. Rails sets no limit for ffprobe; a crafted or
// hour-long video shouldn't hold a media thread, so it has the Rust port's.
let FFPROBE_TIMEOUT_MS: i64 = 30000;
let FFMPEG_TIMEOUT_MS: i64 = 10000;
// The most output kept: ffprobe's JSON, and ffmpeg's frame.
let FFPROBE_OUTPUT_MAX: i64 = 16 << 20;
let FFMPEG_OUTPUT_MAX: i64 = 128 << 20;
// What campfire_media_run answers for a program that isn't installed (Errno::ENOENT), and for one
// that ran past its time.
let MEDIA_RUN_MISSING: i32 = -2;
let MEDIA_RUN_TIMED_OUT: i32 = -3;

// config.active_storage.video_preview_arguments, as Shellwords.split gives them, each ended by a
// NUL: load_defaults 7.0's, with any frame from 5 seconds on selected too, so ffmpeg stops there.
let VIDEO_PREVIEW_ARGUMENTS = "-vf\x00select=eq(n\\,0)+eq(key\\,1)+gt(scene\\,0.015)+gte(t\\,5),loop=loop=-1:size=2,trim=start_frame=1\x00-frames:v\x001\x00-f\x00image2\x00";

// Blob#open for ffprobe and ffmpeg: the blob's file under a name ending in its extension, as the
// tempfile download_blob_to_tempfile hands them (ffmpeg takes the extension as a hint). The caller
// removes it with campfire_media_unlink.
fn media_input(storage: const u8[:], key: const u8[:], filename: const u8[:], link: u8[>..]&) -> bool {
    guard storage_key_valid(key) else { return false; }
    let ext = extname(filename);
    return campfire_media_link(blob_file(storage, key), if ext.len <= 64 { ext } else { ext[..0] }, link) == 1;
}

// Blob#analyze's metadata for a video or an audio file: ffprobe -print_format json -show_streams
// -show_format -v error <file>, its stderr going where the server's does, read by VideoAnalyzer or
// AudioAnalyzer and merged into stored. Without ffprobe the probe is {}, as in Rails. False, with
// why, where Rails raises: ffprobe can't run or runs past FFPROBE_TIMEOUT_MS, its output isn't
// JSON, or a value doesn't convert.
fn probed_metadata(storage: const u8[:], key: const u8[:], filename: const u8[:], content_type: const u8[:], stored: const u8[:], metadata: u8[>..]&, error: u8[>..]&) -> bool {
    var link: u8[>..] = [];
    guard media_input(storage, key, filename, link) else { error.append("cannot open the blob's file"); return false; }
    var args: u8[>..] = [];
    args.append("ffprobe\x00-print_format\x00json\x00-show_streams\x00-show_format\x00-v\x00error\x00"); args.append(link); args.push(0);
    var output: u8[>..] = []; var ignored: u8[>..] = [];
    let status = campfire_media_run(args, FFPROBE_TIMEOUT_MS, FFPROBE_OUTPUT_MAX, false, output, ignored);
    campfire_media_unlink(link);
    if status == MEDIA_RUN_MISSING { output.clear(); output.append("{}"); }
    else if status == MEDIA_RUN_TIMED_OUT { error.append(str("ffprobe timed out after ", FFPROBE_TIMEOUT_MS, " ms")); return false; }
    else if status < 0 { error.append(str("ffprobe could not run (", status, ")")); return false; }
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let root, parse_error = json::parse(output, nodes, strings);
    guard root else { error.append(str("ffprobe output: ", parse_error)); return false; }
    var members: u8[][>..] = [];
    let extracted = if video_content_type(content_type) { video_metadata(root, members, error) } else { audio_metadata(root, members, error) };
    guard extracted else { return false; }
    metadata.append(merged_metadata(stored, members));
    return true;
}

// Blob#analyze's update!, then touch_attachments: each record holding the blob is touched, a
// message touching its room as well (belongs_to :room, touch: true).
fn save_analysis(db, blob: i64, metadata: const u8[:], now: const u8[:]) {
    sql_rows(db, "UPDATE active_storage_blobs SET metadata=? WHERE id=?", [sql_text(metadata), sql_text(blob)]);
    let holders = "SELECT record_id FROM active_storage_attachments WHERE blob_id=? AND record_type=";
    sql_rows(db, str("UPDATE messages SET updated_at=? WHERE id IN (", holders, "'Message')"), [sql_text(now), sql_text(blob)]);
    sql_rows(db, str("UPDATE rooms SET updated_at=? WHERE id IN (SELECT room_id FROM messages WHERE id IN (", holders, "'Message'))"), [sql_text(now), sql_text(blob)]);
    sql_rows(db, str("UPDATE users SET updated_at=? WHERE id IN (", holders, "'User')"), [sql_text(now), sql_text(blob)]);
    sql_rows(db, str("UPDATE accounts SET updated_at=? WHERE id IN (", holders, "'Account')"), [sql_text(now), sql_text(blob)]);
}

// VideoPreviewer#draw_relevant_frame_from: the stdout of `ffmpeg -i <file>
// <video_preview_arguments> -`, a JPEG. False, with Previewer#capture's message, when ffmpeg fails,
// and when it runs past FFMPEG_TIMEOUT_MS.
fn draw_preview(storage: const u8[:], key: const u8[:], filename: const u8[:], frame: u8[>..]&, error: u8[>..]&) -> bool {
    var link: u8[>..] = [];
    guard media_input(storage, key, filename, link) else { error.append("cannot open the blob's file"); return false; }
    var args: u8[>..] = [];
    args.append("ffmpeg\x00-i\x00"); args.append(link); args.push(0); args.append(VIDEO_PREVIEW_ARGUMENTS); args.append("-\x00");
    var stderr: u8[>..] = [];
    let status = campfire_media_run(args, FFMPEG_TIMEOUT_MS, FFMPEG_OUTPUT_MAX, true, frame, stderr);
    campfire_media_unlink(link);
    if status == MEDIA_RUN_TIMED_OUT { error.append(str("ffmpeg timed out after ", FFMPEG_TIMEOUT_MS, " ms")); return false; }
    if status < 0 { error.append(str("ffmpeg could not run (", status, ")")); return false; }
    if status != 0 {
        var end = stderr.len;
        if end > 0 && stderr[end - 1] == '\n' { end -= 1; }
        if end > 0 && stderr[end - 1] == '\r' { end -= 1; }
        error.append(str("ffmpeg failed (status ", status, "): ", stderr[..end]));
        return false;
    }
    guard frame.len > 0 else { error.append("ffmpeg drew no frame"); return false; }
    return true;
}

// The file half of Preview#process: the video's frame written as the preview image's blob,
// "<base>.jpg", identified (image/jpeg) and analyzed as its AnalyzeJob would.
fn stage_preview_image(storage: const u8[:], source_key: const u8[:], source_filename: const u8[:], staged: StagedVariant&, error: u8[>..]&) -> bool {
    let filename = str(filename_base(source_filename), ".jpg");
    guard filename.len <= 1024 else { error.append("the filename is too long"); return false; }
    var frame: u8[>..] = [];
    guard draw_preview(storage, source_key, source_filename, frame, error) else { return false; }
    let key = new_blob_key();
    guard write_blob_file(storage, key, frame) else { error.append("cannot write the preview image"); return false; }
    var content_type = identify_content_type(frame, filename, "image/jpeg");
    if content_type.len > 256 { content_type = str(BINARY_CONTENT_TYPE); }
    let metadata = analyzed_metadata(blob_file(storage, key), content_type);
    staged = StagedVariant { key: key, filename: filename, content_type: content_type, metadata: metadata, size: frame.len, checksum: blob_checksum(frame) };
    return true;
}

// blob.preview_image: its blob; id 0 when none is attached.
fn find_preview_image(db, blob: i64) -> VariantBlob {
    var out = VariantBlob { .. };
    for row in sql_rows(db, "SELECT b.id,b.key,b.filename,b.content_type FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='ActiveStorage::Blob' AND a.name='preview_image' AND a.record_id=? ORDER BY a.id LIMIT 1", [sql_text(blob)]) {
        let id, valid = parse_int(cell(row, 0));
        if valid && cell(row, 1).len <= 32 && cell(row, 3).len <= 256 && cell(row, 2).len <= 1024 { out = VariantBlob { id: id, key: cell(row, 1), filename: cell(row, 2), content_type: cell(row, 3) }; }
    }
    return out;
}

// The record half: blob.preview_image.attach(...). False when another writer attached one first;
// the caller then deletes the staged file.
fn record_preview_image(db, blob: i64, staged: const StagedVariant&, now: const u8[:]) -> bool {
    if find_preview_image(db, blob).id != 0 { return false; }
    let image = insert_blob(db, staged.key, staged.filename, staged.content_type, staged.metadata, staged.size, staged.checksum, now);
    attach_blob(db, "preview_image", "ActiveStorage::Blob", blob, image, now);
    return true;
}

// --- URLs --------------------------------------------------------------------------------------

// rails_blob_path(blob, disposition:)
fn blob_redirect_path(blob: i64, filename: const u8[:], disposition: const u8[:], key: const u8[:]) -> u8[>..] {
    var out = str("/rails/active_storage/blobs/redirect/", escape_segment(signed_blob_id(blob, key)), "/", escape_path(sanitized_filename(filename)));
    if disposition.len > 0 { out.append("?disposition="); out.append(disposition); }
    return out;
}

// url_for(blob.representation(variation))
fn representation_path(blob: i64, filename: const u8[:], v: const Variation&, key: const u8[:]) -> u8[>..] {
    return str("/rails/active_storage/representations/redirect/", escape_segment(signed_blob_id(blob, key)), "/",
        escape_segment(variation_key(v, key)), "/", escape_path(sanitized_filename(filename)));
}

// DiskService#url: the signed /rails/active_storage/disk/... path, which expires in five minutes.
fn disk_path(file_key: const u8[:], filename: const u8[:], content_type: const u8[:], disposition: const u8[:], key: const u8[:]) -> u8[>..] {
    let sanitized = sanitized_filename(filename);
    var data: u8[>..] = []; data.append("{\"key\":"); json::format_string(data, file_key);
    data.append(",\"disposition\":"); json::format_string(data, content_disposition(disposition, sanitized));
    data.append(",\"content_type\":"); json::format_string(data, content_type);
    data.append(",\"service_name\":\"local\"}");
    var expiry: u8[>..] = []; campfire_after(SERVICE_URLS_EXPIRE_IN, expiry);
    return str("/rails/active_storage/disk/", escape_segment(storage_generate(data, "blob_key", expiry, key)), "/", escape_path(sanitized));
}

// DiskController#decode_verified_key: the file's key, content type and disposition.
fn decode_disk_key(token: const u8[:], key: const u8[:], now: const u8[:], file_key: u8[>..]&, content_type: u8[>..]&, disposition: u8[>..]&) -> bool {
    var data: u8[>..] = [];
    guard storage_verify(token, "blob_key", key, now, data) else { return false; }
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let root, error = json::parse(data, nodes, strings);
    let k, has_key = json::as_string(json::member(root, "key"));
    let d, has_disposition = json::as_string(json::member(root, "disposition"));
    let t, has_type = json::as_string(json::member(root, "content_type"));
    guard has_key && has_disposition && storage_key_valid(k) else { return false; }
    file_key.append(k); disposition.append(d); if has_type { content_type.append(t); }
    return true;
}
