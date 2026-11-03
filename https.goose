namespace campfire;
import std;
import http;

// The request's scheme and authority as Rails sees them, the absolute URLs built from them, and
// the origin checks that compare against them.
//
// config/environments/production.rb sets config.assume_ssl and config.force_ssl unless DISABLE_SSL
// is present. assume_ssl (ActionDispatch::AssumeSSL) makes every request HTTPS: TLS ends at a
// proxy in front. force_ssl (ActionDispatch::SSL) redirects plain HTTP to HTTPS, sends
// Strict-Transport-Security and flags every cookie secure. Without them, a request is HTTPS when
// a proxy says so (Rack::Request#ssl?: X-Forwarded-Ssl, Forwarded proto=, X-Forwarded-Proto or
// X-Forwarded-Scheme). Built-in TLS termination would make request_ssl answer true for a request
// that arrived over TLS; everything else reads the scheme through request_ssl.
struct SchemeConfig { assume_ssl: bool = true, force_ssl: bool = true }

var scheme_config = SchemeConfig { .. };

// Strict-Transport-Security with force_ssl (Rails' default hsts: two years, with subdomains).
let HSTS = "max-age=63072000; includeSubDomains";

fn scheme_word(value: const u8[:]) -> bool { return value == "https" || value == "http" || value == "wss" || value == "ws"; }

// The last of a header's values, split on commas and whitespace, that is a scheme Rack allows.
fn last_scheme(value: const u8[:]) -> u8[>..] {
    var found: u8[>..] = []; var word: u8[>..] = [];
    for i in value.len + 1 {
        let c = if i < value.len { value[i] } else { ',' as u8 };
        if c == ',' || c == ' ' || c == '\t' {
            if scheme_word(word) { found.clear(); found.append(word); }
            word.clear();
        } else { word.push(c); }
    }
    return found;
}

// The last proto= of a Forwarded field (RFC 7239), quoted or not.
fn forwarded_proto(value: const u8[:]) -> u8[>..] {
    var found: u8[>..] = [];
    for element in split(value, ",") {
        for pair in split(element, ";") {
            let eq = find(pair, "="); if eq < 0 { continue; }
            if html_lower_ascii(trim(pair[..eq])) != "proto" { continue; }
            var v = trim(pair[eq+1..]);
            if v.len >= 2 && v[0] == '"' && v[v.len-1] == '"' { v = v[1..v.len-1]; }
            found.clear(); found.append(v);
        }
    }
    return found;
}

fn html_lower_ascii(text: const u8[:]) -> u8[>..] {
    var out: u8[>..] = []; for c in text { out.push(if c >= 'A' && c <= 'Z' { c + 32 } else { c }); } return out;
}

// Rack::Request#scheme == "https" for a request that didn't arrive over TLS itself.
fn forwarded_https(req: const http::Request&) -> bool {
    let ssl, has_ssl = http::field_of(req, "X-Forwarded-Ssl");
    if has_ssl && trim(ssl) == "on" { return true; }
    let forwarded, has_forwarded = http::field_of(req, "Forwarded");
    if has_forwarded {
        let proto = forwarded_proto(forwarded);
        if scheme_word(proto) { return proto == "https" || proto == "wss"; }
    }
    let proto, has_proto = http::field_of(req, "X-Forwarded-Proto");
    if has_proto {
        let scheme = last_scheme(proto);
        if scheme.len > 0 { return scheme == "https" || scheme == "wss"; }
    }
    let named, has_named = http::field_of(req, "X-Forwarded-Scheme");
    if has_named {
        let scheme = last_scheme(named);
        if scheme.len > 0 { return scheme == "https" || scheme == "wss"; }
    }
    return false;
}

// request.ssl?
fn request_ssl(req: const http::Request&) -> bool {
    return scheme_config.assume_ssl || forwarded_https(req);
}

// request.raw_host_with_port: the last X-Forwarded-Host, else Host.
fn raw_host_with_port(req: const http::Request&) -> u8[>..] {
    let forwarded, has_forwarded = http::field_of(req, "X-Forwarded-Host");
    if has_forwarded && trim(forwarded).len > 0 {
        let parts = split(forwarded, ",");
        return str(trim(parts[parts.len - 1]));
    }
    let host, has_host = http::field_of(req, "Host");
    return if has_host { str(host) } else { str("localhost") };
}

// The port at the end of an authority, or -1 for none.
fn authority_port(authority: const u8[:]) -> i64 {
    var at = authority.len;
    while at > 0 && authority[at-1] >= '0' && authority[at-1] <= '9' { at -= 1; }
    if at == authority.len || at == 0 || authority[at-1] != ':' { return -1; }
    let port, ok = parse_int(authority[at..]);
    return if ok { port } else { -1 };
}

// request.host_with_port: the port only when it isn't the scheme's.
fn host_with_port(req: const http::Request&) -> u8[>..] {
    let raw = raw_host_with_port(req);
    let port = authority_port(raw);
    let standard: i64 = if request_ssl(req) { 443 } else { 80 };
    if port == standard { return str(raw[..raw.len - str(":", port).len]); }
    return raw;
}

// request.protocol
fn request_protocol(req: const http::Request&) -> const u8[:] { return if request_ssl(req) { "https://" } else { "http://" }; }

// request.base_url, as every absolute URL the app writes begins.
fn base_url(req: const http::Request&) -> u8[>..] { return str(request_protocol(req), host_with_port(req)); }

// request.url
fn request_url(req: const http::Request&) -> u8[>..] { return str(base_url(req), req.target); }

// verify_authenticity_token for a write, by Sec-Fetch-Site and Origin rather than tokens, as the
// Rust and Jai ports do: an Origin must be the request's base URL, and Sec-Fetch-Site same-origin or
// same-site. Browsers send it only to secure origins, so it may be missing only over plain HTTP.
fn request_same_origin(req: const http::Request&) -> bool {
    let origin, has_origin = http::field_of(req, "Origin");
    if has_origin && (origin == "null" || origin != base_url(req)) { return false; }
    let site, has_site = http::field_of(req, "Sec-Fetch-Site");
    if has_site { return site == "same-origin" || site == "same-site"; }
    return !request_ssl(req) && !scheme_config.force_ssl;
}

// ActionCable::Connection's allow_request_origin?: the Origin is the scheme and Host header. One
// without an Origin is let through, as it always was here (Action Cable refuses it).
fn cable_origin_allowed(req: const http::Request&) -> bool {
    let origin, has_origin = http::field_of(req, "Origin");
    guard has_origin else { return true; }
    let host, has_host = http::field_of(req, "Host");
    return has_host && origin == str(if request_ssl(req) { "https://" } else { "http://" }, host);
}

// ActionDispatch::SSL#redirect_to_https: 301 for GET and HEAD, 308 otherwise, to the same path on
// https and the host without its port. True when it answered.
fn force_ssl_redirect(req: const http::Request&, out: http::Reply) -> bool {
    guard scheme_config.force_ssl && !request_ssl(req) else { return false; }
    let raw = raw_host_with_port(req);
    let port = authority_port(raw);
    let host = if port >= 0 { raw[..raw.len - str(":", port).len] } else { raw[..] };
    http::start(out, if req.method == "GET" || req.method == "HEAD" { 301 } else { 308 });
    http::field(out, "Location", str("https://", host, req.target));
    http::finish(out, "Content-Type: text/html\r\nContent-Length: ", "");
    return true;
}

// ActionDispatch::SSL on a response begun at mark: every cookie secure (HSTS is one of its common
// fields, response_common).
fn secure_cookies(req: const http::Request&, out: http::Reply, mark: i64) {
    guard scheme_config.force_ssl && request_ssl(req) && mark >= 0 && out.buf.len > mark else { return; }
    let head_end = find(out.buf[mark..], "\r\n\r\n");
    guard head_end >= 0 else { return; }
    // Flag each Set-Cookie line that isn't secure yet.
    var at = mark;
    var end = mark + head_end + 2;
    while at < end {
        let line_end = at + find(out.buf[at..end], "\r\n");
        if line_end < at { break; }
        var next = line_end + 2;
        let line = html_lower_ascii(out.buf[at..line_end]);
        if starts_with(line, "set-cookie:") && find(line, "; secure") < 0 {
            let old = out.buf.len;
            out.buf.append("; secure");
            reverse(out.buf[line_end..old]); reverse(out.buf[old..]); reverse(out.buf[line_end..]);
            next += 8; end += 8;
        }
        at = next;
    }
}

// DISABLE_SSL present (any value but blank): neither assume_ssl nor force_ssl.
fn configure_scheme(disable_ssl: bool) {
    scheme_config.assume_ssl = !disable_ssl;
    scheme_config.force_ssl = !disable_ssl;
}
