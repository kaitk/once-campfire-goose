namespace campfire;

// What Rails and Thruster add to a response for the request it answers, besides Rack::ETag's
// fields (etag.goose): the Content-Security-Policy, and Vary.
//
// - config/initializers/content_security_policy.rb enforces `script-src 'self'; object-src 'none';
//   base-uri 'self'` unless DISABLE_CONTENT_SECURITY_POLICY is "true". ApplicationController's
//   InlineScriptHashes narrows script-src to the asset directory of this host
//   (request.host_with_port, no scheme) and the base64 SHA-256 of the two inline scripts the
//   importmap helper writes (VIEW_SCRIPT_HASHES), and adds worker-src for the service worker. It is
//   a before_action, and the first: InlineScriptHashes is the last module ApplicationController
//   includes, so its callback is set first, and every response an ApplicationController makes
//   carries it, a halted before_action's too. Other controllers (the health check, Active Storage's,
//   Action Mailbox's, Turbo Native's) and Action Cable's mount get the configured policy.
//   ActionDispatch::ContentSecurityPolicy::Middleware sits below ShowExceptions and
//   ActionDispatch::Static and above Rack::ConditionalGet, so an exception page, a public/ file or
//   an asset gets none, and neither does a 304.
// - protect_from_forgery's append_sec_fetch_site_to_vary_header, an after_action: Vary gains
//   Sec-Fetch-Site on every response whose action ran (not one a before_action or rescue_from
//   answered, nor an exception's), in every controller but those that skip forgery protection
//   (PwaController, Active Storage's DiskController, Action Mailbox's ingresses) and a bot key's
//   request (`unless: -> { authenticated_by.bot_key? }`).
// - render sets Vary: Accept, when Vary is blank, for a request with an Accept field (Rails 8.2's
//   strict_accept_header) and no format parameter.
// - Thruster appends Accept-Encoding to the Vary it passes on, joined with a bare comma, or sets
//   it alone where there is none; but a 204 or a 304 with a Vary of its own keeps it as it is.
//
// begin_rails_request records what of the request these need, before it is answered;
// rails_halted marks an answer no action gave. Each worker has its own rails_request.

import std;
import http;
import https;
import public_pages;
import view_assets_generated;

struct CspConfig { enabled: bool = true }

var csp_config = CspConfig { .. };

// DISABLE_CONTENT_SECURITY_POLICY=true: no policy, and no csp-nonce meta tag.
fn configure_csp(disabled: bool) { csp_config.enabled = !disabled; }

fn csp_enabled() -> bool { return csp_config.enabled; }

// The policy and Vary of a response Action Cable's mount makes (outside any controller).
fn rack_app_fields() -> u8[>..] {
    var add: u8[>..] = [];
    if csp_config.enabled { add.append("Content-Security-Policy: script-src 'self'; object-src 'none'; base-uri 'self'\r\n"); }
    add.append("Vary: Accept-Encoding\r\n");
    return add;
}

// csp_meta_tag: the nonce's meta tag, with no nonce; nothing with the policy disabled.
fn csp_meta_html() -> const u8[:] { return if csp_config.enabled { "<meta name=\"csp-nonce\" />" } else { "" }; }

// Who answers a path: ApplicationController, another controller or Rack app (the policy
// configured), or ActionDispatch::Static (none).
const ANSWERED_BY_APPLICATION: i32 = 1;
const ANSWERED_BY_ENGINE: i32 = 2;
const ANSWERED_BY_STATIC: i32 = 3;

struct RailsRequest {
    // request.host_with_port, for ApplicationController's policy; "" when it is too long to keep
    // (the configured policy then stands in).
    host: u8[..256] = [],
    answered_by: i32 = ANSWERED_BY_ENGINE,
    // Whether its controller appends Sec-Fetch-Site to Vary once its action has run.
    protected: bool = true,
    // Whether a render sets Vary: Accept.
    accept: bool = false,
    // Whether a before_action or rescue_from answered: no after_action runs.
    halted: bool = false,
    // Whether it has an If-None-Match, which Thruster's cache answers for a public response.
    none_match: bool = false,
}

var rails_request = RailsRequest { .. };

// Whether a path is answered by an ApplicationController, whose first before_action sets the
// version headers: not assets, the health check, Action Cable, or the engines' (Active Storage,
// Action Mailbox and its conductor, Turbo Native's navigation).
fn controller_path(path: const u8[:]) -> bool {
    return !starts_with(path, "/assets/") && path != "/up" && !starts_with(path, "/rails/") && path != "/cable" &&
           find(path, "_historical_location") < 0;
}

// Messages::ByBotsController's route, POST /rooms/:room_id/:bot_key/messages, which a bot key
// authenticates.
fn bot_key_path(path: const u8[:]) -> bool {
    guard starts_with(path, "/rooms/") && ends_with(path, "/messages") else { return false; }
    let middle = path[7..path.len - 9];
    let slash = find(middle, "/");
    guard slash > 0 else { return false; }
    let key = middle[slash + 1..];
    return key.len > 0 && find(key, "/") < 0 && find(key, "-") > 0;
}

// The controllers that skip forgery protection: PwaController, Active Storage's DiskController,
// and Action Mailbox's ingresses (and its conductor, which refuses every request here before its
// action, as a production server does).
fn unprotected_path(path: const u8[:]) -> bool {
    return path == "/service-worker" || path == "/service-worker.js" || path == "/webmanifest" || path == "/webmanifest.json" ||
           starts_with(path, "/rails/active_storage/disk/") || starts_with(path, "/rails/action_mailbox/") ||
           starts_with(path, "/rails/conductor/") || bot_key_path(path);
}

// should_apply_vary_header?: no params[:format] (a route's (.:format), or the query's), and an
// Accept, or for an XHR a Content-Type.
fn vary_accept(req: const http::Request&) -> bool {
    let path = http::path_of(req.target);
    var last = path;
    let slash = find_last(path, "/");
    if slash >= 0 { last = path[slash + 1..]; }
    guard find(last, ".") < 0 else { return false; }
    let format, has_format = http::query_of(req.target, "format");
    guard !has_format else { return false; }
    let accept, has_accept = http::field_of(req, "Accept");
    if has_accept && trim(accept).len > 0 { return true; }
    let requested, has_requested = http::field_of(req, "X-Requested-With");
    let kind, has_kind = http::field_of(req, "Content-Type");
    return has_requested && requested == "XMLHttpRequest" && has_kind && kind.len > 0;
}

fn find_last(text: const u8[:], needle: const u8[:]) -> i64 {
    var at: i64 = -1;
    var from: i64 = 0;
    while from <= text.len {
        let found = find(text[from..], needle);
        guard found >= 0 else { break; }
        at = from + found;
        from = at + 1;
    }
    return at;
}

fn rails_request_of(req: const http::Request&) -> RailsRequest {
    let path = http::path_of(req.target);
    var r = RailsRequest { .. };
    let host = host_with_port(req);
    if host.len <= 256 { r.host = host; }
    r.answered_by = if static_path(path) { ANSWERED_BY_STATIC } else if controller_path(path) { ANSWERED_BY_APPLICATION } else { ANSWERED_BY_ENGINE };
    r.protected = !unprotected_path(path);
    r.accept = vary_accept(req);
    let tags, has_tags = http::field_of(req, "If-None-Match");
    r.none_match = has_tags;
    return r;
}

// Before answering req.
fn begin_rails_request(req: const http::Request&) { rails_request = rails_request_of(req); }

// The request a reply written later answers: kept with its exchange, and brought back.
fn current_rails_request() -> RailsRequest { return rails_request; }
fn restore_rails_request(r: const RailsRequest&) { rails_request = r; }

// A before_action (or rescue_from) answered the request, so no after_action runs.
fn rails_halted() { rails_request.halted = true; }

// The Content-Security-Policy field line for a response that isn't an exception's, a static
// file's or a 304; "" with the policy disabled.
fn csp_field() -> u8[>..] {
    var line: u8[>..] = [];
    guard csp_config.enabled && rails_request.answered_by != ANSWERED_BY_STATIC else { return line; }
    line.append("Content-Security-Policy: script-src ");
    let host = rails_request.host[..];
    if rails_request.answered_by == ANSWERED_BY_APPLICATION && host.len > 0 {
        line.append(host); line.append("/assets/ "); line.append(VIEW_SCRIPT_HASHES);
        line.append("; object-src 'none'; base-uri 'self'; worker-src "); line.append(host); line.append("/service-worker.js\r\n");
    } else {
        line.append("'self'; object-src 'none'; base-uri 'self'\r\n");
    }
    return line;
}

// The Vary a response of status ends with: Rails' (inside: a controller made it; rendered: by
// render), then Thruster's Accept-Encoding.
fn vary_value(status: i64, inside: bool, rendered: bool) -> u8[>..] {
    var value: u8[>..] = [];
    if inside && rendered && rails_request.accept { value.append("Accept"); }
    if inside && rails_request.protected && !rails_request.halted {
        if value.len > 0 { value.append(", "); }
        value.append("Sec-Fetch-Site");
    }
    if value.len == 0 { value.append("Accept-Encoding"); return value; }
    guard status != 204 && status != 304 else { return value; }
    // Thruster rejoins the values with bare commas.
    var joined: u8[>..] = [];
    for part in split(value, ",") {
        if joined.len > 0 { joined.push(','); }
        joined.append(trim(part));
    }
    joined.append(",Accept-Encoding");
    return joined;
}

// Whether two Vary values name the same fields.
fn same_vary(a: const u8[:], b: const u8[:]) -> bool {
    let left = split(a, ",");
    let right = split(b, ",");
    guard left.len == right.len else { return false; }
    for x in left {
        var found = false;
        for y in right { if http::same_name(trim(x), trim(y)) { found = true; } }
        guard found else { return false; }
    }
    return true;
}

// The fields Rails and Thruster add to a response of status that has the Vary vary (has_vary)
// already: inside, one a controller made (not an exception page, a static file or a server error
// of Goose's own); rendered, one whose body render wrote. A Vary already there that differs is
// followed by the whole one, as Thruster sends a second Vary. A public response's 304 for an
// If-None-Match (an avatar's, the logo's, a QR code's, Active Storage's proxies') is Thruster's
// cache's answer, with the fields of the 200 it keeps.
fn rails_fields(status: i64, inside: bool, rendered: bool, vary: const u8[:], has_vary: bool, public: bool = false) -> u8[>..] {
    var add: u8[>..] = [];
    let kept = status == 304 && public && rails_request.none_match;
    if inside && (status != 304 || kept) { add.append(csp_field()); }
    let value = vary_value(if kept { 200 } else { status }, inside, rendered);
    if !has_vary || !same_vary(vary, value) { add.append("Vary: "); add.append(value); add.append("\r\n"); }
    return add;
}
