// Link previews: UnfurlLinksController#create (POST /unfurl_link) over Opengraph::Metadata, Location,
// Fetch and Document (app/models/opengraph). The composer posts a pasted URL; the page's OpenGraph
// title, description, canonical URL and image come back as JSON, or 204 when there's no preview.
// Every address is resolved through the private network guard (push_crypto.c's, Rails'
// RestrictedHTTP::PrivateNetworkGuard) and the connection pinned to it, every redirect is resolved
// and checked again, at most 10 responses are followed, and a document must be a 200 text/html of
// at most 5MB. Fetching blocks, so it runs on unfurl threads, never on an HTTP worker: the request
// waits (http::later) and the thread mails its answer back (UNFURL_DONE).
namespace campfire;

import std;
import public_pages;
import json;
import http;
import http.client;
import http.shared;
import html;
import rich_html;
import push;
import webhooks;
import admin_routes;
import route_support;
import cable;

// The tag of an unfurl thread's mail to the waiting exchange, apart from media.goose's and cable.goose's.
let UNFURL_DONE: i32 = 270;
let UNFURL_QUEUE: i64 = 256;
// Each connect, send and read; Rails leaves Net::HTTP's 60 seconds. Each unfurl stops following
// links after UNFURL_DEADLINE_MS, and the request waits at most UNFURL_WAIT_MS for an answer.
let UNFURL_IO_MS: i64 = 5000;
let UNFURL_DEADLINE_MS: i64 = 10000;
let UNFURL_WAIT_MS: i64 = 60000;
let OPENGRAPH_MAX_BODY: i64 = 5 * 1024 * 1024;
let OPENGRAPH_MAX_REDIRECTS: i64 = 10;

struct UnfurlJob {
    reply: http::MailAddress = http::MailAddress { .. },
    url: u8[..8192] = [],
}

// TEST ONLY: CAMPFIRE_UNFURL_TEST_CONNECT, an address every unfurl connects to once the guard has
// admitted the URL's (test_ui_messages.py, with CAMPFIRE_PUSH_TEST_RESOLVE). Never in production.
struct UnfurlSettings { test_connect: u8[..256] = [] }

// --- The controller ----------------------------------------------------------------------------

// What `params[:url]` is: 0 missing or blank (`require` raises ParameterMissing: 400), 1 a string,
// 2 anything else present, which URI.parse can't take, so nothing unfurls (204).
fn unfurl_param(req: const http::Request&, body: const u8[:], url: u8[>..]&) -> i32 {
    if content_type_is(req,"application/json") {
        var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
        let root, error = json::parse(body,nodes,strings);
        if error.len == 0 {
            let node = json::member(root,"url");
            if node {
                let text, is_text = json::as_string(node);
                if is_text { url.append(text); return if trim(text).len > 0 { 1 } else { 0 }; }
                let flag, is_bool = json::as_bool(node); if is_bool { return if flag { 2 } else { 0 }; }
                let number, is_number = json::as_f64(node); if is_number { return 2; }
                if node.first { return 2; }
                return 0;
            }
        }
    } else if http::form_value(body,"url",url) { return if trim(url).len > 0 { 1 } else { 0 }; }
    else if form_has_prefix(body,"url[") { return 2; }
    // Query parameters are params too.
    let raw, has_query = http::query_of(req.target,"url");
    url.clear();
    if has_query && http::decode(raw,url,true) { return if trim(url).len > 0 { 1 } else { 0 }; }
    return 0;
}

// POST /unfurl_link (resource :unfurl_link, only: :create); false for any other path.
fn unfurl_route(req: const http::Request&, body: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    if path != "/unfurl_link" && path != "/unfurl_link.json" { return false; }
    if req.method != "POST" { routing_error(out,req); return true; }
    if !same_origin(req) { public_exception(out,req,422); return true; }
    var url: u8[>..] = [];
    let kind = unfurl_param(req,body,url);
    if kind == 0 { public_exception(out,req,400); return true; }
    if kind == 2 || url.len > 8192 { respond_empty(out,204); return true; }
    var job = UnfurlJob { reply: http::later(out,UNFURL_WAIT_MS), .. };
    job.url.append(url);
    if !qput(job) { http::respond(out,503,"text/plain","Link previews are busy"); }
    return true;
}

// The worker's WAKE with UNFURL_DONE: the status and body an unfurl thread made.
fn unfurl_reply(data: const u8[:], out: http::Reply) {
    guard data.len == 8 else { public_exception_later(out,500); return; }
    var h: i64 = 0;
    for i in 8 { h = h | ((data[i] as i64) << (8 * i)); }
    let blob = http::Shared { h: h };
    var bytes: u8[>..] = [];
    let copied = http::shared_append(blob,0,http::shared_len(blob),bytes);
    http::shared_release(blob);
    guard copied && bytes.len >= 3 else { public_exception_later(out,500); return; }
    let status, valid = parse_int(bytes[..3]);
    if !valid || status == 500 { public_exception_later(out,500); }
    else if status == 200 { http::respond(out,200,"application/json; charset=utf-8",bytes[3..]); }
    else { respond_empty(out,status as! i32); }
}

thread_fn unfurl_worker(settings: UnfurlSettings) {
    loop {
        let job = qget<UnfurlJob>();
        if !http::mail_live(job.reply) { continue; }
        var answer: u8[>..] = [];
        let status = unfurl(job.url[..],settings,answer);
        var mail: u8[>..] = []; format(mail,status); mail.append(answer);
        let blob, failed = http::shared_put(mail,1);
        if failed != 0 { continue; }
        var handle: u8[8] = [0; 8];
        for i in 8 { handle[i] = ((blob.h >> (8 * i)) & 255) as! u8; }
        if http::mail_send(job.reply,UNFURL_DONE,handle) != http::SENT { http::shared_release(blob); }
    }
}

// --- URI.parse ---------------------------------------------------------------------------------

struct ParsedUri {
    ok: bool = false,
    scheme: u8[] = [],
    host: u8[] = [],
    host_start: i64 = 0,
    host_end: i64 = 0,
    path: u8[] = [],
}

// URI.parse (RFC 3986): characters a URI may hold, and its scheme, host and path.
fn parse_uri(text: const u8[:]) -> ParsedUri {
    var i: i64 = 0;
    while i < text.len {
        let c = text[i];
        var plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        for allowed in "-._~:/?#[]@!$&'()*+,;=" { if c == allowed { plain = true; } }
        if c == '%' {
            if i + 2 >= text.len || !html_hex(text[i+1]) || !html_hex(text[i+2]) { return ParsedUri { .. }; }
        } else if !plain { return ParsedUri { .. }; }
        i += 1;
    }
    var scheme_end: i64 = -1;
    for c, k in text {
        if c == ':' { scheme_end = k; break; }
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (k > 0 && ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'))) { break; }
    }
    var scheme: u8[>..] = []; var rest_at: i64 = 0;
    if scheme_end > 0 { scheme = html_lower(text[..scheme_end]); rest_at = scheme_end + 1; }
    var host_start: i64 = rest_at; var host_end: i64 = rest_at; var path_at: i64 = rest_at;
    if starts_with(text[rest_at..],"//") {
        var end = rest_at + 2; while end < text.len && text[end] != '/' && text[end] != '?' && text[end] != '#' { end += 1; }
        let authority = text[rest_at+2..end];
        let at = rfind(authority,"@");
        host_start = rest_at + 2 + (if at >= 0 { at + 1 } else { 0 });
        host_end = end;
        if host_start < end && text[host_start] == '[' {
            let close = find(text[host_start..end],"]");
            if close < 0 { return ParsedUri { .. }; }
            host_end = host_start + close + 1;
        } else {
            let colon = find(text[host_start..end],":"); if colon >= 0 { host_end = host_start + colon; }
        }
        if host_end < end {
            if text[host_end] != ':' { return ParsedUri { .. }; }
            for c in text[host_end+1..end] { if c < '0' || c > '9' { return ParsedUri { .. }; } }
        }
        path_at = end;
    }
    var path_end = path_at; while path_end < text.len && text[path_end] != '?' && text[path_end] != '#' { path_end += 1; }
    return ParsedUri { ok: true, scheme: scheme, host: str(text[host_start..host_end]), host_start: host_start, host_end: host_end, path: str(text[path_at..path_end]) };
}

fn html_hex(c: u8) -> bool { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }

// --- Opengraph::Location and Fetch ------------------------------------------------------------------

// Location#valid?: an http(s) URL whose host the guard resolves to a public address, into ip.
fn location_valid(url: const u8[:], ip: u8[>..]&) -> bool {
    let parsed = parse_uri(url);
    if !parsed.ok || (parsed.scheme != "http" && parsed.scheme != "https") || parsed.host.len == 0 { return false; }
    ip.clear();
    return campfire_push_resolve(parsed.host,ip) == 0;
}

// Location#read_html: nothing for files and media (FILES_AND_MEDIA_URL_REGEX).
fn files_and_media(url: const u8[:]) -> bool {
    let extensions = ["zip","tar","tar.gz","tar.bz2","tar.xz","gz","bz2","rar","7z","dmg","exe","msi","pkg","deb","iso","jpg","jpeg","png","gif","bmp","mp4","mov","avi","mkv","wmv","flv","heic","heif","mp3","wav","ogg","aac","wma","webm","ogv","mpg","mpeg"];
    var i: i64 = 0;
    while i < url.len {
        let scheme = if starts_with(url[i..],"https://") { 8 } else if starts_with(url[i..],"http://") { 7 } else { 0 };
        if scheme == 0 || (i > 0 && html_word(url[i-1]) && url[i-1] != '-') { i += 1; continue; }
        var end = i + scheme; while end < url.len && !html_space(url[end]) { end += 1; }
        // \S+\.(ext)\b: a dot after at least one character, an extension, then a word boundary.
        var k = i + scheme + 1;
        while k < end {
            if url[k] == '.' {
                for extension in extensions {
                    let after = k + 1 + extension.len;
                    if after <= url.len && url[k+1..after] == extension && (after == url.len || !(html_word(url[after]) && url[after] != '-')) { return true; }
                }
            }
            k += 1;
        }
        i += 1;
    }
    return false;
}

// Opengraph::Fetch#request: GET or HEAD against the pinned address, following redirects (any 3xx)
// to http(s) URLs the guard admits, up to 10 responses. False when it raised, which Location
// rescues (nothing).
fn opengraph_request(method: const u8[:], start_url: const u8[:], start_ip: const u8[:], settings: const UnfurlSettings&, deadline: i64) -> http::ClientResponse, bool {
    var url: u8[>..] = str(start_url); var ip: u8[>..] = str(start_ip);
    for attempt in OPENGRAPH_MAX_REDIRECTS {
        if campfire_clock_ms() > deadline { break; }
        var session = http::session(UNFURL_IO_MS);
        session.max_body = OPENGRAPH_MAX_BODY;
        session.via = if settings.test_connect.len > 0 { settings.test_connect[..] } else { ip[..] };
        let got, err = http::request(session,method,url) { req => };
        http::free(session);
        if err.code != 0 { break; }
        if got.status >= 300 && got.status < 400 {
            let location, has_location = http::header(got,"Location");
            if !has_location { break; }
            let next = parse_uri(location);
            if !next.ok || (next.scheme != "http" && next.scheme != "https") { break; }
            ip.clear();
            if next.host.len == 0 || campfire_push_resolve(next.host,ip) != 0 { break; }
            url.clear(); url.append(location);
            continue;
        }
        return got, true;
    }
    return http::ClientResponse { .. }, false;
}

// Net::HTTPHeader#content_type: the media type, without parameters, lowercased.
fn media_type_of(response: const http::ClientResponse&) -> u8[>..] {
    let field, has = http::header(response,"Content-Type");
    if !has { return []; }
    let semi = find(field,";");
    return html_lower(trim(if semi < 0 { field } else { field[..semi] }));
}

// Location#read_html, through Fetch#fetch_document: a 200 text/html body of at most 5MB.
fn read_html(url: const u8[:], settings: const UnfurlSettings&, deadline: i64, html_out: u8[>..]&) -> bool {
    var ip: u8[>..] = [];
    if !location_valid(url,ip) || files_and_media(url) { return false; }
    let response, fetched = opengraph_request("GET",url,ip,settings,deadline);
    if !fetched { return false; }
    if response.status != 200 || media_type_of(response) != "text/html" { return false; }
    let length, has_length = http::header(response,"Content-Length");
    if has_length { let n, numeric = parse_int(trim(length)); if numeric && n > OPENGRAPH_MAX_BODY { return false; } }
    html_out.append(response.body);
    return true;
}

// Location#fetch_content_type, through Fetch#fetch_content_type: the final response's Content-Type.
fn fetch_content_type(url: const u8[:], settings: const UnfurlSettings&, deadline: i64, kind: u8[>..]&) -> bool {
    var ip: u8[>..] = [];
    if !location_valid(url,ip) { return false; }
    let response, fetched = opengraph_request("HEAD",url,ip,settings,deadline);
    if !fetched { return false; }
    let field, has = http::header(response,"Content-Type");
    if has { kind.append(field); }
    return has;
}

// --- Opengraph::Document ---------------------------------------------------------------------------

// Nokogiri's meta_encoding: a <meta charset> or a Content-Type <meta http-equiv> with a charset.
fn meta_encoding(page: const u8[:]) -> bool {
    var i: i64 = 0;
    while i < page.len {
        if page[i] != '<' { i += 1; continue; }
        var attrs: RichAttr[>..] = []; let tag = rich_tag(page,i,attrs);
        if !tag.closing && html_lower(tag.name) == "meta" {
            for a in attrs {
                let name = html_lower(a.name);
                if name == "charset" && trim(a.value).len > 0 { return true; }
            }
            var equiv = false; var charset = false;
            for a in attrs {
                let name = html_lower(a.name);
                if name == "http-equiv" && html_lower(trim(html_decode(a.value))) == "content-type" { equiv = true; }
                if name == "content" && find(html_lower(a.value),"charset=") >= 0 { charset = true; }
            }
            if equiv && charset { return true; }
        }
        i = tag.end;
    }
    return false;
}

// What a page's OpenGraph tags gave: which of title, url, image and description it had.
struct OgFound { has_title: bool = false, has_url: bool = false, has_image: bool = false, has_description: bool = false }

// Document#opengraph_attributes: from each <meta> whose property or name starts with "og:" and
// whose content isn't blank, title, url, image and description, the last of each winning.
fn opengraph_attributes(page: const u8[:], found: OgFound&, title: u8[>..]&, og_url: u8[>..]&, image: u8[>..]&, description: u8[>..]&) {
    let encoded = meta_encoding(page);
    var i: i64 = 0;
    while i < page.len {
        if page[i] != '<' { i += 1; continue; }
        if starts_with(page[i..],"<!--") { let end = find(page[i+4..],"-->"); i = if end < 0 { page.len } else { i + 4 + end + 3 }; continue; }
        var attrs: RichAttr[>..] = []; let tag = rich_tag(page,i,attrs); let name = html_lower(tag.name);
        if !tag.closing && (name == "script" || name == "style") {
            let end = find(html_lower(page[tag.end..]),str("</",name)); i = if end < 0 { page.len } else { tag.end + end }; continue;
        }
        if !tag.closing && name == "meta" {
            var property: u8[>..] = []; var has_property = false; var named: u8[>..] = []; var has_name = false;
            var content: u8[>..] = []; var has_content = false;
            for a in attrs {
                let attribute = html_lower(a.name);
                if attribute == "property" && !has_property { property.append(html_decode(a.value)); has_property = true; }
                else if attribute == "name" && !has_name { named.append(html_decode(a.value)); has_name = true; }
                else if attribute == "content" && !has_content { content.append(html_decode(a.value)); has_content = true; }
            }
            if (starts_with(property,"og:") || starts_with(named,"og:")) && has_content && trim(content).len > 0 {
                var key: u8[>..] = []; format_replaced(key,if has_property { property[..] } else { named[..] },"og:","");
                var value: u8[>..] = [];
                // Without a declared encoding, the content is read as binary into UTF-8: every non-ASCII byte goes.
                if encoded { value.append(content); } else { for c in content { if c < 128 { value.push(c); } } }
                if key == "title" { title.clear(); title.append(value); found.has_title = true; }
                else if key == "url" { og_url.clear(); og_url.append(value); found.has_url = true; }
                else if key == "image" { image.clear(); image.append(value); found.has_image = true; }
                else if key == "description" { description.clear(); description.append(value); found.has_description = true; }
            }
        }
        i = tag.end;
    }
}

// --- Opengraph::Metadata ----------------------------------------------------------------------------

// strip_tags, then sanitize (Rails::HTML5's full and safe list sanitizers): the fragment's text,
// script, style and textarea content kept as text, written with &, <, > and no-break spaces escaped.
fn opengraph_clean(text: const u8[:]) -> u8[>..] {
    var plain: u8[>..] = []; var i: i64 = 0; var begin: i64 = 0;
    while i < text.len {
        if text[i] != '<' { i += 1; continue; }
        if starts_with(text[i..],"<!--") {
            plain.append(html_decode(text[begin..i]));
            let end = find(text[i+4..],"-->"); i = if end < 0 { text.len } else { i + 4 + end + 3 }; begin = i; continue;
        }
        if i + 1 >= text.len || !(html_word(text[i+1]) || text[i+1] == '/' || text[i+1] == '!' || text[i+1] == '?') { i += 1; continue; }
        plain.append(html_decode(text[begin..i]));
        var attrs: RichAttr[>..] = []; let tag = rich_tag(text,i,attrs); let name = html_lower(tag.name);
        i = tag.end; begin = i;
        if !tag.closing && (name == "script" || name == "style" || name == "xmp" || name == "iframe" || name == "noembed" || name == "noframes" || name == "textarea" || name == "title") {
            let end = find(html_lower(text[i..]),str("</",name));
            let inner = if end < 0 { text[i..] } else { text[i..i+end] };
            if name == "textarea" || name == "title" { plain.append(html_decode(inner)); } else { plain.append(inner); }
            if end < 0 { i = text.len; } else { let close = find(text[i+end..],">"); i = if close < 0 { text.len } else { i + end + close + 1 }; }
            begin = i;
        }
    }
    plain.append(html_decode(text[begin..]));
    var out: u8[>..] = []; var k: i64 = 0;
    while k < plain.len {
        let c = plain[k];
        if c == '&' { out.append("&amp;"); } else if c == '<' { out.append("&lt;"); } else if c == '>' { out.append("&gt;"); }
        else if c == 0xC2 && k + 1 < plain.len && plain[k+1] == 0xA0 { out.append("&nbsp;"); k += 1; }
        else { out.push(c); }
        k += 1;
    }
    return out;
}

// UnfurlLinksController#create after `params.require(:url)`: Metadata.from_url, then valid?.
// The status (200, 204, or 500 where Rails raises) and, for 200, the JSON (`render json:
// opengraph`, its instance variables in the order they were assigned).
fn unfurl(url: const u8[:], settings: const UnfurlSettings&, out: u8[>..]&) -> i32 {
    let deadline = campfire_clock_ms() + UNFURL_DEADLINE_MS;
    // fetch_document: a tweet's page comes from fxtwitter.com.
    var page: u8[>..] = []; var fetched = false;
    let parsed = parse_uri(url);
    var tweet = false;
    if parsed.ok && (parsed.host == "twitter.com" || parsed.host == "www.twitter.com" || parsed.host == "x.com" || parsed.host == "www.x.com") {
        tweet = parsed.path.len > 0 && parsed.path != "/";
    }
    if tweet {
        let fxtwitter = str(url[..parsed.host_start],"fxtwitter.com",url[parsed.host_end..]);
        fetched = read_html(fxtwitter,settings,deadline,page);
        // `location.read_html.force_encoding` on nil raises NoMethodError.
        if !fetched { return 500; }
    } else { fetched = read_html(url,settings,deadline,page); }
    var found = OgFound { .. };
    var og_title: u8[>..] = []; var og_url: u8[>..] = []; var og_image: u8[>..] = []; var og_description: u8[>..] = [];
    opengraph_attributes(page,found,og_title,og_url,og_image,og_description);
    // The attributes in Hash#slice's order (title, url, image, description), then merge(url:, image:)
    // appends the url and image when the page had none.
    var order: u8[>..] = [];
    if found.has_title { order.push('t'); }
    if found.has_url { order.push('u'); }
    if found.has_image { order.push('i'); }
    if found.has_description { order.push('d'); }
    if !found.has_url { order.push('u'); }
    if !found.has_image { order.push('i'); }
    // valid_canonical_url
    var ip: u8[>..] = []; var canonical: u8[>..] = [];
    if found.has_url && location_valid(og_url,ip) { canonical.append(og_url); } else { canonical.append(url); }
    // valid_image_content_type: kept when a HEAD says it's a JPEG, PNG, GIF or WebP.
    var image_ok = false;
    if found.has_image && trim(og_image).len > 0 && parse_uri(og_image).ok {
        var kind: u8[>..] = [];
        if fetch_content_type(og_image,settings,deadline,kind) {
            let lower = html_lower(kind);
            image_ok = lower == "image/jpeg" || lower == "image/png" || lower == "image/gif" || lower == "image/webp";
        }
    }
    // before_validation sanitize_fields, then the presence of title, url and description, and a
    // valid location for an image.
    if !found.has_title || !found.has_description { return 204; }
    let title = opengraph_clean(og_title); let description = opengraph_clean(og_description);
    if trim(title).len == 0 || trim(description).len == 0 || trim(canonical).len == 0 { return 204; }
    if image_ok && !location_valid(og_image,ip) { return 204; }
    out.push('{');
    for k in order {
        if k == 't' { json_rails(out,"title"); out.push(':'); json_rails(out,title); }
        else if k == 'u' { json_rails(out,"url"); out.push(':'); json_rails(out,canonical); }
        else if k == 'i' { json_rails(out,"image"); out.push(':'); if image_ok { json_rails(out,og_image); } else { out.append("null"); } }
        else { json_rails(out,"description"); out.push(':'); json_rails(out,description); }
        out.push(',');
    }
    out.append("\"context_for_validation\":{\"context\":null},\"errors\":{}}");
    return 200;
}
