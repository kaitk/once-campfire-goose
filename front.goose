namespace campfire;
import std;
import http;
import tls;
import acme;
import acme.serve;

// What Thruster 0.1.23 (`bundle exec thrust bin/start-app`, the Rails image's Procfile) does in
// front of Puma, in the port's own process: plain HTTP on HTTP_PORT, or, with TLS_DOMAIN, HTTPS
// with h2 by ALPN on HTTPS_PORT, with certificates from ACME_DIRECTORY (Let's Encrypt) that
// goose-acme's acme.serve gets and renews through TLS-ALPN-01 and keeps where Thruster kept them,
// in autocert's layout, while HTTP_PORT only redirects to HTTPS. Each setting is read from
// THRUSTER_<NAME> first, as Thruster reads them.
struct Front {
    http_port: i64 = 80,
    https_port: i64 = 443,
    // TLS_DOMAIN's names, lowercased, one a line.
    domains: u8[..4096],
    forward_headers: bool = true,
}

fn front_env(name: const u8[:], out: u8[>..]&) -> bool {
    out.clear();
    if env(str("THRUSTER_", name), out) { return true; }
    return env(name, out);
}

// Go's strconv.ParseBool, as Thruster reads a flag; default when it doesn't parse.
fn front_bool(name: const u8[:], default: bool) -> bool {
    var v: u8[>..] = [];
    guard front_env(name, v) else { return default; }
    if v == "1" || v == "t" || v == "T" || v == "TRUE" || v == "true" || v == "True" { return true; }
    if v == "0" || v == "f" || v == "F" || v == "FALSE" || v == "false" || v == "False" { return false; }
    return default;
}

fn front_port(name: const u8[:], default: i64) -> i64 {
    var v: u8[>..] = [];
    guard front_env(name, v) else { return default; }
    let port, ok = parse_int(v);
    guard ok && port > 0 && port < 65536 else { abort(str("invalid ", name)); }
    return port;
}

fn front_config() -> Front {
    var f = Front { .. };
    // HTTP_PORT, as Thruster reads it; PORT, Puma's, is the port's earlier name for it.
    var port: u8[>..] = [];
    f.http_port = if front_env("HTTP_PORT", port) { front_port("HTTP_PORT", 80) } else { front_port("PORT", 80) };
    f.https_port = front_port("HTTPS_PORT", 443);
    var names: u8[>..] = [];
    if front_env("TLS_DOMAIN", names) {
        each_split(names, ',') {
            let name = trim(it);
            if name.len > 0 {
                guard name.len <= 253 && f.domains.len + name.len + 1 <= 4096 else { abort("TLS_DOMAIN is too long"); }
                for c in name { f.domains.push(if c >= 'A' && c <= 'Z' { c + 32 } else { c }); }
                f.domains.push('\n');
            }
        };
    }
    f.forward_headers = front_bool("FORWARD_HEADERS", f.domains.len == 0);
    return f;
}

// The lane that gets TLS_DOMAIN's certificates, one a name as autocert gets them, and the
// context the HTTPS port's connections start from.
fn front_service(f: const Front&, workers: i64) -> acme::Service {
    var plan = acme::Plan { autocert: true, workers: workers, .. };
    var v: u8[>..] = [];
    if front_env("ACME_DIRECTORY", v) && v.len > 0 { plan.directory.append(v); } else { plan.directory.append(acme::LETS_ENCRYPT); }
    // STORAGE_PATH is the port's blob directory, so Thruster's state is only THRUSTER_STORAGE_PATH;
    // by default ./storage/thruster, /rails/storage/thruster in the image, as Thruster's.
    var path: u8[>..] = [];
    if env("THRUSTER_STORAGE_PATH", path) && path.len > 0 { plan.cache.append(path); } else { plan.cache.append("storage/thruster"); }
    if front_env("EAB_KID", v) { plan.eab_kid.append(v); }
    if front_env("EAB_HMAC_KEY", v) { plan.eab_key.append(v); }
    plan.protocols.append("h2,http/1.1");
    each_split(f.domains, '\n') { if it.len > 0 { acme::plan_certificate(plan, [it]); } };
    let service, err = acme::serve(plan);
    guard err.len == 0 else { abort(str("TLS: ", err)); }
    return service;
}

// http.Error's text/plain answer.
fn front_error(out: http::Reply, status: i32, message: const u8[:]) {
    http::start(out, status);
    http::field(out, "X-Content-Type-Options", "nosniff");
    http::finish(out, "Content-Type: text/plain; charset=utf-8\r\nContent-Length: ", message);
}

// The HTTP port's answer with TLS on: autocert's HTTPHandler around Thruster's
// httpRedirectHandler. ACME's HTTP-01 paths answer for TLS_DOMAIN's names (acme.serve answers
// TLS-ALPN-01 only, so none has a token); every other request to one of those names is
// redirected, permanently, to the same path over HTTPS on its default port, and any other host
// is misdirected.
fn front_redirect(req: const http::Request&, out: http::Reply, domains: const u8[:]) {
    let host, has_host = http::field_of(req, "Host");
    let raw = if has_host { trim(host) } else { host[..0] };
    if starts_with(http::path_of(req.target), "/.well-known/acme-challenge/") {
        if !front_allowed(domains, raw) {
            front_error(out, 403, str("acme/autocert: host \"", raw, "\" not configured in HostWhitelist\n"));
        } else {
            front_error(out, 404, "acme/autocert: certificate cache miss\n");
        }
        return;
    }
    var name = raw;
    if name.len > 0 && name[0] == '[' {
        let close = find(name, "]");
        if close > 0 { name = name[1..close]; }
    } else {
        let colon = find(name, ":");
        if colon >= 0 && find(name[colon + 1..], ":") < 0 { name = name[..colon]; }
    }
    var lower: u8[>..] = [];
    for c in name { lower.push(if c >= 'A' && c <= 'Z' { c + 32 } else { c }); }
    out.keep_alive = false;
    guard front_allowed(domains, lower) else {
        front_error(out, 421, "Misdirected Request\n");
        return;
    }
    let url = str("https://", lower, req.target);
    http::start(out, 301);
    http::field(out, "Location", url);
    if req.method == "GET" {
        http::finish(out, "Content-Type: text/html; charset=utf-8\r\nContent-Length: ",
                     str("<a href=\"", html_escape_url(url), "\">Moved Permanently</a>.\n\n"));
    } else if req.method == "HEAD" {
        http::finish(out, "Content-Type: text/html; charset=utf-8\r\nContent-Length: ", "");
    } else {
        http::finish(out, "Content-Length: ", "");
    }
}

fn front_allowed(domains: const u8[:], name: const u8[:]) -> bool {
    var found = false;
    each_split(domains, '\n') { if it.len > 0 && it == name { found = true; } };
    return found;
}

// html.EscapeString, as http.Redirect writes the link.
fn html_escape_url(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for c in s {
        if c == '&' { out.append("&amp;"); }
        else if c == '<' { out.append("&lt;"); }
        else if c == '>' { out.append("&gt;"); }
        else if c == '"' { out.append("&#34;"); }
        else if c == '\'' { out.append("&#39;"); }
        else { out.push(c); }
    }
    return out;
}

// The HTTP port with TLS on: a worker of its own, which only redirects.
thread_fn front_http(cfg: http::Config, domains: u8[..4096]) {
    http::run(cfg, domains, front_http_worker);
}

thread_fn front_http_worker(cfg: http::Config, domains: u8[..4096]) {
    let e = http::serve_epoll(cfg) { req, body, out => front_redirect(req, out, domains); };
    http::report(e);
}
