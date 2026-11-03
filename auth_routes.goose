namespace campfire;
import std;
import public_pages;
import http;
import sqlite;
import hash;
import json;
import base64;
import database;
import auth;
import sessions;
import html;
import https;
import browser_check;
import view_types;
import view_helpers;
import view_data;
import views_generated;
import view_assets_generated;
import route_support;
import admin_routes;
import signed_id;
import storage;
import media;
import avatars;
import cable;

// Sign-in, first run, joining and signing out as Rails has them: SessionsController,
// Sessions::TransfersController, FirstRunsController, UsersController#new/create, and the
// Authentication, AllowBrowser and VersionHeaders concerns.

extern fn campfire_password_hash(password: const u8[:], entropy: const u8[:], out: u8[>..]&) -> bool;
extern fn campfire_gcm_encrypt(key: const u8[:], plaintext: const u8[:], out: u8[>..]&) -> bool;
extern fn campfire_gcm_decrypt(key: const u8[:], iv: const u8[:], tag: const u8[:], ciphertext: const u8[:], out: u8[>..]&) -> bool;
extern fn campfire_rate_count(key: const u8[:], now_ms: i64, window_ms: i64) -> i64;

struct AuthConfig {
    // config/initializers/version.rb: APP_VERSION, else GIT_REVISION, else "0"; and GIT_REVISION.
    app_version: u8[..256] = "0",
    git_revision: u8[..256] = [],
    has_revision: bool = false,
    // The keys of the session_token cookie, the Rails session cookie and signed ids.
    cookie_key: u8[64] = [0; 64],
    session_key: u8[32] = [0; 32],
    signed_id_key: u8[64] = [0; 64],
    vapid: u8[..256] = [],
    storage: u8[..1024] = "storage",
}

var auth_config = AuthConfig { .. };

let REJECTION = "Too many requests or unauthorized.";
// rate_limit to: 10, within: 3.minutes, only: :create
let RATE_LIMIT_TO: i64 = 10;
let RATE_LIMIT_WITHIN_MS: i64 = 180000;
let SESSION_COOKIE = "_campfire_session";

// --- VersionHeaders, and what ActionDispatch::SSL adds -------------------------------------------

fn version_fields(out: u8[>..]&) {
    out.append("X-Version: "); out.append(auth_config.app_version); out.append("\r\n");
    if auth_config.has_revision && auth_config.git_revision.len > 0 { out.append("X-Rev: "); out.append(auth_config.git_revision); out.append("\r\n"); }
}

// Whether a path is answered by an ApplicationController, whose first before_action sets the
// version headers: not assets, the health check, Active Storage or Action Cable.
fn controller_path(path: const u8[:]) -> bool {
    return !starts_with(path, "/assets/") && path != "/up" && !starts_with(path, "/rails/active_storage/") && path != "/cable";
}

// The fields every response to req begins with: the reply's (the loop's, and ActionDispatch::SSL's
// HSTS, secure_common), and set_version_headers' for an ApplicationController's (before its first
// before_action can halt). Rails' exception pages (a routing or record 404, a 500) have no version
// headers: public_exception drops them.
fn response_common(req: const http::Request&, common: const u8[:]) -> u8[>..] {
    var out: u8[>..] = []; out.append(common);
    if controller_path(http::path_of(req.target)) { version_fields(out); }
    return out;
}

// --- The Rails session cookie ----------------------------------------------------------------

// Rack::Utils.escape, which Rack applies to the cookie values it writes.
fn rack_escape(out: u8[>..]&, text: const u8[:]) {
    let hex = "0123456789ABCDEF";
    for c in text {
        if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '*' || c == '-' || c == '.' || c == '_' { out.push(c); }
        else if c == ' ' { out.push('+'); }
        else { out.push('%'); out.push(hex[c >> 4]); out.push(hex[c & 15]); }
    }
}

fn hex_token(bytes: i64) -> u8[>..] {
    var raw: u8[64] = [0; 64]; hash::random_bytes(raw[..bytes]);
    var out: u8[>..] = []; let digits = "0123456789abcdef";
    for c in raw[..bytes] { out.push(digits[c >> 4]); out.push(digits[c & 15]); }
    return out;
}

// cookies.encrypted[:_campfire_session], as the cookie store writes the session: the session hash
// as JSON, in the legacy metadata envelope with the cookie's purpose and 20-year expiry, sealed
// with aes-256-gcm under generate_key("authenticated encrypted cookie", 32).
fn session_cookie_value(data: const u8[:]) -> u8[>..] {
    var expiry: u8[>..] = []; campfire_expiry(expiry);
    var message: u8[>..] = []; base64::encode(message, data);
    var envelope: u8[>..] = [];
    envelope.append("{\"_rails\":{\"message\":"); json::format_string(envelope, message);
    envelope.append(",\"exp\":"); json::format_string(envelope, expiry);
    envelope.append(",\"pur\":\"cookie._campfire_session\"}}");
    var sealed: u8[>..] = [];
    guard campfire_gcm_encrypt(auth_config.session_key, envelope, sealed) && sealed.len >= 28 else { return []; }
    var raw: u8[>..] = [];
    base64::encode(raw, sealed[28..]); raw.append("--"); base64::encode(raw, sealed[..12]); raw.append("--"); base64::encode(raw, sealed[12..28]);
    var out: u8[>..] = []; rack_escape(out, raw); return out;
}

// The session hash of the request's _campfire_session cookie, as JSON, or "" when it has none
// that opens.
fn session_cookie_data(req: const http::Request&) -> u8[>..] {
    let raw, present = http::cookie_of(req, SESSION_COOKIE);
    guard present && raw.len < 8192 else { return []; }
    var value: u8[>..] = [];
    guard http::decode(raw, value, true) else { return []; }
    // ciphertext--iv--tag: the IV's 12 bytes and the tag's 16 are 16 and 24 characters of Base64.
    guard value.len > 44 else { return []; }
    let second = value.len - 24;
    guard value[second-2..second] == "--" else { return []; }
    let first = second - 2 - 16;
    guard first >= 2 && value[first-2..first] == "--" else { return []; }
    var ciphertext: u8[>..] = []; var iv: u8[>..] = []; var tag: u8[>..] = [];
    guard base64::decode(ciphertext, value[..first-2]) && base64::decode(iv, value[first..second-2]) && base64::decode(tag, value[second..]) else { return []; }
    var plain: u8[>..] = [];
    guard campfire_gcm_decrypt(auth_config.session_key, iv, tag, ciphertext, plain) else { return []; }
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let root, error = json::parse(plain, nodes, strings);
    guard root else { return []; }
    let rails = json::member(root, "_rails");
    guard rails else { return str(plain); }
    let purpose, has_purpose = json::as_string(json::member(rails, "pur"));
    guard !has_purpose || purpose == "cookie._campfire_session" else { return []; }
    let expiry, has_expiry = json::as_string(json::member(rails, "exp"));
    if has_expiry {
        var now: u8[>..] = []; campfire_now(now);
        guard compare(expiry, now) > 0 else { return []; }
    }
    let message, has_message = json::as_string(json::member(rails, "message"));
    if has_message { var data: u8[>..] = []; guard base64::decode(data, message) else { return []; } return data; }
    return [];
}

// session[:return_to_after_authenticating]
fn session_return_to(req: const http::Request&) -> u8[>..] {
    let data = session_cookie_data(req);
    guard data.len > 0 else { return []; }
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let root, error = json::parse(data, nodes, strings);
    guard root else { return []; }
    let url, ok = json::as_string(json::member(root, "return_to_after_authenticating"));
    return if ok { str(url) } else { [] };
}

// The Set-Cookie value of a session holding only the flash `redirect_to ..., alert:` (kind "alert")
// or `notice:` sets: {"discard":[],"flashes":{kind:message}}, as ActionDispatch::Flash stores it.
fn session_flash_cookie(kind: const u8[:], message: const u8[:]) -> u8[>..] {
    var data: u8[>..] = [];
    data.append("{\"session_id\":\""); data.append(hex_token(16)); data.append("\",\"flash\":{\"discard\":[],\"flashes\":{");
    json::format_string(data, kind); data.push(':'); json::format_string(data, message); data.append("}}}");
    return str(SESSION_COOKIE, "=", session_cookie_value(data), "; path=/; expires=", permanent_cookie_expiry(), "; httponly; samesite=lax");
}

// RoomsController#set_room's miss: redirect_to root_url, alert: "Room not found or inaccessible".
fn redirect_room_not_found(out: http::Reply, req: const http::Request&) {
    http::start(out,302); http::field(out,"Location",str(request_base(req),"/"));
    http::field(out,"Set-Cookie",session_flash_cookie("alert","Room not found or inaccessible"));
    http::finish(out,http::TEXT,"Redirecting");
}

// The session's flash: its alert or notice, and whether it is an alert; false for none.
fn session_flash(req: const http::Request&) -> u8[>..], bool, bool {
    let data = session_cookie_data(req);
    guard data.len > 0 else { return [], false, false; }
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let root, error = json::parse(data, nodes, strings);
    guard root else { return [], false, false; }
    let flashes = json::member(json::member(root, "flash"), "flashes");
    let alert, is_alert = json::as_string(json::member(flashes, "alert"));
    if is_alert { return str(alert), true, true; }
    let notice, is_notice = json::as_string(json::member(flashes, "notice"));
    if is_notice { return str(notice), false, true; }
    return [], false, false;
}

fn delete_session_cookie(out: http::Reply) {
    http::field(out, "Set-Cookie", "_campfire_session=; path=/; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT");
}

// request_authentication: session[:return_to_after_authenticating] = request.url, and off to sign in.
fn request_authentication(req: const http::Request&, out: http::Reply) {
    var data: u8[>..] = [];
    data.append("{\"session_id\":\""); data.append(hex_token(16)); data.append("\",\"return_to_after_authenticating\":");
    json::format_string(data, request_url(req)); data.append("}");
    let value = session_cookie_value(data);
    http::start(out, 302);
    http::field(out, "Location", str(base_url(req), "/session/new"));
    if value.len > 0 { http::field(out, "Set-Cookie", str(SESSION_COOKIE, "=", value, "; path=/; expires=", permanent_cookie_expiry(), "; httponly; samesite=lax")); }
    http::finish(out, "Content-Type: text/html; charset=utf-8\r\nContent-Length: ", "");
}

// --- Responses ---------------------------------------------------------------------------------

// redirect_to url: 302, with Rails' empty text/html body.
fn redirect_302(out: http::Reply, location: const u8[:]) {
    http::start(out, 302); http::field(out, "Location", location);
    http::finish(out, "Content-Type: text/html; charset=utf-8\r\nContent-Length: ", "");
}

// head status
fn head_only(out: http::Reply, status: i32) {
    http::start(out, status); http::finish(out, "Content-Type: text/html\r\nContent-Length: ", "");
}

// start_new_session_for(user), then redirect_to url: the session row, the session_token cookie
// (signed, permanent, httponly, lax), and with consumed the Rails session's return-to dropped.
fn signed_in_redirect(out: http::Reply, token: const u8[:], location: const u8[:], consumed: bool) {
    var expiry: u8[>..] = []; campfire_expiry(expiry);
    http::start(out, 302);
    http::field(out, "Location", location);
    http::field(out, "Set-Cookie", str("session_token=", sign_cookie(token, auth_config.cookie_key, expiry), "; path=/; expires=", permanent_cookie_expiry(), "; httponly; samesite=lax"));
    if consumed { delete_session_cookie(out); }
    http::finish(out, "Content-Type: text/html; charset=utf-8\r\nContent-Length: ", "");
}

// post_authenticating_url: session.delete(:return_to_after_authenticating) || root_url.
fn post_authenticating_url(req: const http::Request&) -> u8[>..], bool {
    let stored = session_return_to(req);
    if stored.len > 0 { return stored, true; }
    return str(base_url(req), "/"), false;
}

// --- Pages -------------------------------------------------------------------------------------

fn auth_translation(key: const u8[:]) -> u8[>..] {
    let flags: const u8[:][7] = ["🇺🇸", "🇪🇸", "🇫🇷", "🇮🇳", "🇩🇪", "🇧🇷", "🇯🇵"];
    var texts: u8[][>..] = [];
    if key == "email_address" {
        texts.push(str("Enter your email address")); texts.push(str("Introduce tu correo electrónico")); texts.push(str("Entrez votre adresse courriel"));
        texts.push(str("अपना ईमेल पता दर्ज करें")); texts.push(str("Geben Sie Ihre E-Mail-Adresse ein")); texts.push(str("Insira seu endereço de email")); texts.push(str("メールアドレスを入力してください"));
    } else if key == "password" {
        texts.push(str("Enter your password")); texts.push(str("Introduce tu contraseña")); texts.push(str("Saisissez votre mot de passe"));
        texts.push(str("अपना पासवर्ड दर्ज करें")); texts.push(str("Geben Sie Ihr Passwort ein")); texts.push(str("Insira sua senha")); texts.push(str("パスワードを入力してください"));
    } else if key == "user_name" {
        texts.push(str("Enter your name")); texts.push(str("Introduce tu nombre")); texts.push(str("Entrez votre nom"));
        texts.push(str("अपना नाम दर्ज करें")); texts.push(str("Geben Sie Ihren Namen ein")); texts.push(str("Insira seu nome")); texts.push(str("お名前を入力してください"));
    } else {
        texts.push(str("Upgrade to a supported web browser. Campfire requires a modern web browser. Please use one of the browsers listed below and make sure auto-updates are enabled."));
        texts.push(str("Actualiza a un navegador web compatible. Campfire requiere un navegador web moderno. Utiliza uno de los navegadores listados a continuación y asegúrate de que las actualizaciones automáticas estén habilitadas."));
        texts.push(str("Mettez à jour vers un navigateur web pris en charge. Campfire nécessite un navigateur web moderne. Veuillez utiliser l'un des navigateurs répertoriés ci-dessous et assurez-vous que les mises à jour automatiques sont activées."));
        texts.push(str("समर्थित वेब ब्राउज़र में अपग्रेड करें। Campfire को एक आधुनिक वेब ब्राउज़र की आवश्यकता है। कृपया नीचे सूचीबद्ध ब्राउज़रों में से कोई एक का उपयोग करें और सुनिश्चित करें कि स्वचालित अपडेट्स सक्षम हैं।"));
        texts.push(str("Aktualisieren Sie auf einen unterstützten Webbrowser. Campfire erfordert einen modernen Webbrowser. Verwenden Sie bitte einen der unten aufgeführten Browser und stellen Sie sicher, dass automatische Updates aktiviert sind."));
        texts.push(str("Atualize para um navegador compatível. O Campfire requer um navegador moderno. Por favor, use um dos navegadores listados abaixo e certifique-se de que as atualizações automáticas estão ativadas."));
        texts.push(str("サポートされたウェブブラウザーにアップグレードしてください。Campfireはモダンなウェブブラウザーが必要です。下記のブラウザーのいずれかを使用し、自動更新が有効になっていることを確認してください。"));
    }
    var rows: u8[>..] = [];
    for text, i in texts { rows.append(element_html("dt", [], flags[i])); var escaped: u8[>..] = []; escape(escaped, text); rows.append(element_html("dd", [html_attr("class", "margin-none")], escaped)); }
    let summary = element_html("summary", [html_attr("class", "btn"), html_attr("tabindex", -1)],
        str(image_html("globe.svg", [html_attr("size", 20), html_attr("aria-hidden", true), html_attr("class", "color-icon")]), element_html("span", [html_attr("class", "for-screen-reader")], "Translate")));
    let menu = element_html("div", [html_attr("class", "language-list-menu shadow"), html_attr("data-popup-target", "menu")], element_html("dl", [html_attr("class", "language-list")], rows));
    return element_html("details", [html_attr("class", "position-relative"), html_attr("data-controller", "popup"),
        html_attr("data-action", "keydown.esc->popup#close toggle->popup#toggle click@document->popup#closeOnClickOutside"),
        html_attr("data-popup-orientation-top-class", "popup-orientation-top")], str(summary, menu));
}

// accounts/_help_contact: the first administrator's address and the version badge.
fn help_contact(db) -> u8[>..] {
    var out: u8[>..] = [];
    let owners = sql_rows(db, "SELECT name,coalesce(email_address,'') FROM users WHERE role=1 ORDER BY id LIMIT 1", []);
    for owner in owners {
    let name = cell(owner, 0); let email = cell(owner, 1);
    out.append("<div class=\"txt-align-center margin-block-double full-width\"><a class=\"btn center\" title=\"");
    escape(out, str("Email ", name)); out.append("\" href=\""); escape(out, str("mailto:\"", name, "\" <", email, ">")); out.append("\">");
    out.append(image_html("lifebuoy.svg", [html_attr("aria-hidden", "true")]));
    out.append("<span>"); escape(out, email); out.append("</span></a><div class=\"txt-align-center center margin-block txt-subtle\">Campfire&trade; version <span class=\"version-badge\">");
    escape(out, auth_config.app_version); out.append("</span></div></div>");
    }
    return out;
}

// The layout's context for a page without a signed-in user: the account's name, logo and styles.
fn public_context(db, bytes: u8[>..]&, title: const u8[:], body_class: const u8[:]) -> ViewContext {
    var ctx = ViewContext { .. };
    ctx.title = view_keep(bytes, title); ctx.body_class = view_keep(bytes, body_class);
    ctx.stylesheet_tags = VIEW_STYLESHEET_TAGS; ctx.importmap_tags = VIEW_IMPORTMAP_TAGS;
    ctx.vapid_public_key = view_keep(bytes, auth_config.vapid);
    ctx.account.logo_url = "/account/logo";
    let rows = sql_rows(db, "SELECT a.name,a.updated_at,coalesce(a.custom_styles,''),a.custom_styles IS NOT NULL,EXISTS(SELECT 1 FROM active_storage_attachments b WHERE b.record_type='Account' AND b.record_id=a.id AND b.name='logo') FROM accounts a ORDER BY a.id LIMIT 1", []);
    for row in rows {
        ctx.account.name = view_keep(bytes, cell(row, 0));
        ctx.account.logo_url = view_keep(bytes, str("/account/logo?v=", version_number(cell(row, 1))));
        ctx.custom_styles = view_keep(bytes, cell(row, 2)); ctx.has_custom_styles = cell(row, 3) == "1";
        ctx.account.has_logo = cell(row, 4) == "1";
    }
    return ctx;
}

fn input_tag(out: u8[>..]&, attrs: HtmlAttr[]) { out.append("<input"); append_attrs(out, attrs); out.append(" />"); }

// A text-like field of a user form: its translation button, the input and the icon.
fn nametag_field(out: u8[>..]&, key: const u8[:], input: HtmlAttr[], icon: const u8[:]) {
    out.append("<div class=\"flex align-center gap\">"); out.append(auth_translation(key));
    out.append("<label class=\"flex align-center gap flex-item-grow txt-large input input--actor\">"); input_tag(out, copy(input));
    out.append(image_html(icon, [html_attr("aria-hidden", "true"), html_attr("size", 24), html_attr("class", "colorize--black")]));
    out.append("</label></div>");
}

// first_runs/show and users/new: the nametag form.
fn nametag_form(ctx: const ViewContext&, action: const u8[:], first: bool) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("<form class=\""); out.append(if first { "center max-width" } else { "center" });
    out.append("\" enctype=\"multipart/form-data\" action=\""); escape(out, action); out.append("\" accept-charset=\"UTF-8\" method=\"post\">");
    out.append("<section class=\"nametag u-relative\"><div class=\"flex justify-center align-center pad-block\">");
    out.append(image_html("lanyard.svg", [html_attr("class", "nametag__lanyard"), html_attr("aria-hidden", "true")]));
    out.append("</div><div class=\"nametag__inner flex flex-column gap\"><fieldset class=\"flex flex-column center-block\">");
    if first { out.append("<legend class=\"txt-large txt-align-center\"><strong>Set up Campfire</strong></legend>"); }
    else {
        out.append("<legend class=\"txt-align-center flex gap\">"); out.append(account_logo_html(ctx, ""));
        out.append("<strong class=\"txt-large\">"); escape(out, ctx.account.name); out.append("</strong></legend>");
    }
    out.append("<label class=\"align-center center avatar__form gap\" data-controller=\"upload-preview\"><div class=\"btn input--file\">");
    out.append(image_html("camera.svg", [html_attr("aria-hidden", "true")]));
    input_tag(out, [html_attr("class", "input"), html_attr("accept", "image/*"), html_attr("data-upload-preview-target", "input"), html_attr("data-action", "upload-preview#previewImage"),
        html_attr("type", "file"), html_attr("name", "user[avatar]"), html_attr("id", "user_avatar")]);
    out.append("<span class=\"for-screen-reader\">"); out.append(if first { "Add your avatar" } else { "Upload avatar" });
    out.append("</span></div><div class=\"btn avatar input--file txt-xx-large\">");
    if first { out.append(image_html("default-avatar.svg", [html_attr("aria-hidden", "true"), html_attr("data-upload-preview-target", "image"), html_attr("alt", "Add your avatar")])); }
    else { out.append(image_html("default-avatar.svg", [html_attr("aria-hidden", "true"), html_attr("data-upload-preview-target", "image")])); }
    out.append("<span class=\"for-screen-reader\">Avatar</span></div></label></fieldset>");
    nametag_field(out, "user_name", [html_attr("class", "input"), html_attr("autocomplete", "name"), html_attr("placeholder", "Name"), html_attr("autofocus", "autofocus"),
        html_attr("required", "required"), html_attr("data-1p-ignore", "true"), html_attr("type", "text"), html_attr("name", "user[name]"), html_attr("id", "user_name")], "person.svg");
    nametag_field(out, "email_address", [html_attr("class", "input"), html_attr("autocomplete", "username"), html_attr("placeholder", "Email address"),
        html_attr("required", "required"), html_attr("type", "email"), html_attr("name", "user[email_address]"), html_attr("id", "user_email_address")], "email.svg");
    nametag_field(out, "password", [html_attr("class", "input"), html_attr("autocomplete", "new-password"), html_attr("placeholder", "Password"), html_attr("required", "required"),
        html_attr("maxlength", "72"), html_attr("size", "72"), html_attr("type", "password"), html_attr("name", "user[password]"), html_attr("id", "user_password")], "password.svg");
    out.append("<button name=\"button\" type=\"submit\" class=\"btn btn--reversed center txt-large\">");
    out.append(image_html(if first { "arrow-right.svg" } else { "check.svg" }, [html_attr("aria-hidden", "true")]));
    out.append("<span class=\"for-screen-reader\">Save</span></button></div></section></form>");
    return out;
}

// sessions/new, with an alert for a rejected sign-in.
fn render_sign_in(db, req: const http::Request&, out: http::Reply, status: i32, alert: bool, email: const u8[:], has_email: bool) {
    var bytes: u8[>..] = [];
    var ctx = public_context(db, bytes, "Sign in", "");
    if alert { ctx.notice = REJECTION; ctx.has_alert = true; }
    ctx.page_head = "<meta name=\"turbo-visit-control\" content=\"reload\">\n";
    var c: u8[>..] = [];
    c.append("<section class=\"txt-align-center\"><div class=\"panel "); if alert { c.append("shake"); } c.append("\">");
    c.append(account_logo_html(ctx, "center margin-block-end txt-xx-large"));
    c.append("<form class=\"flex flex-column gap\" action=\""); escape(c, str(base_url(req), "/session")); c.append("\" accept-charset=\"UTF-8\" method=\"post\">");
    c.append("<fieldset class=\"flex flex-column gap center-block upad\"><legend class=\"txt-large txt-align-center\"><strong>"); escape(c, ctx.account.name); c.append("</strong></legend>");
    c.append("<div class=\"flex align-center gap\">"); c.append(auth_translation("email_address"));
    c.append("<label class=\"flex align-center gap input input--actor txt-large\">");
    var email_attrs: HtmlAttr[>..] = [];
    email_attrs.push(html_attr("required", "required")); email_attrs.push(html_attr("class", "input")); email_attrs.push(html_attr("autofocus", "autofocus"));
    email_attrs.push(html_attr("autocomplete", "username")); email_attrs.push(html_attr("placeholder", "Enter your email address"));
    if has_email { email_attrs.push(html_attr("value", email)); }
    email_attrs.push(html_attr("type", "email")); email_attrs.push(html_attr("name", "email_address")); email_attrs.push(html_attr("id", "email_address"));
    input_tag(c, copy(email_attrs));
    c.append(image_html("email.svg", [html_attr("aria-hidden", "true"), html_attr("size", 24), html_attr("class", "colorize--black")]));
    c.append("</label></div><div class=\"flex align-center gap\">"); c.append(auth_translation("password"));
    c.append("<label class=\"flex align-center gap input input--actor txt-large\">");
    input_tag(c, [html_attr("required", "required"), html_attr("class", "input"), html_attr("autocomplete", "current-password"), html_attr("placeholder", "Enter your password"),
        html_attr("maxlength", "72"), html_attr("size", "72"), html_attr("type", "password"), html_attr("name", "password"), html_attr("id", "password")]);
    c.append(image_html("password.svg", [html_attr("aria-hidden", "true"), html_attr("size", 24), html_attr("class", "colorize--black")]));
    c.append("</label></div><button name=\"log_in\" type=\"submit\" class=\"btn btn--reversed center txt-large\">");
    c.append(image_html("arrow-right.svg", [html_attr("aria-hidden", "true")]));
    c.append("<span class=\"for-screen-reader\">Go</span></button></fieldset></form></div>");
    c.append(help_contact(db)); c.append("</section>");
    ctx.page_content = c;
    respond_page(out, req, ctx, status);
}

fn render_first_run(db, req: const http::Request&, out: http::Reply) {
    var bytes: u8[>..] = [];
    var ctx = public_context(db, bytes, "Set up Campfire", "signup");
    let content = nametag_form(ctx, "/first_run", true);
    ctx.page_content = content;
    respond_page(out, req, ctx, 200);
}

fn render_join(db, req: const http::Request&, out: http::Reply, code: const u8[:]) {
    var bytes: u8[>..] = [];
    var ctx = public_context(db, bytes, "Sign up", "signup");
    var nav: u8[>..] = [];
    nav.append("<div class=\"flex-item-justify-end\"><a class=\"btn flex-item-justify-end\" href=\"/session/new\">");
    nav.append(image_html("login-keys.svg", [html_attr("aria-hidden", "true")]));
    nav.append("<span class=\"for-screen-reader\">Sign in</span></a></div>");
    var content: u8[>..] = [];
    var action: u8[>..] = []; action.append("/join/"); path_escape(action, code);
    content.append(nametag_form(ctx, action, false)); content.append(help_contact(db));
    ctx.page_nav = nav; ctx.page_content = content;
    respond_page(out, req, ctx, 200);
}

fn path_safe(c: u8) -> bool {
    return c == '-' || c == '.' || c == '_' || c == '~' || c == '!' || c == '$' || c == '&' || c == '\'' || c == '(' || c == ')' ||
           c == '*' || c == '+' || c == ',' || c == ';' || c == '=' || c == ':' || c == '@';
}

// A path segment as Rails' url helpers escape it.
fn path_escape(out: u8[>..]&, text: const u8[:]) {
    let hex = "0123456789ABCDEF";
    for c in text {
        if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || path_safe(c) { out.push(c); }
        else { out.push('%'); out.push(hex[c >> 4]); out.push(hex[c & 15]); }
    }
}

fn render_transfer(db, req: const http::Request&, out: http::Reply, path: const u8[:]) {
    var bytes: u8[>..] = [];
    var ctx = public_context(db, bytes, "Campfire", "");
    var content: u8[>..] = [];
    // auto_submit_form_with method: :put. Rails' block-less form_with leaves the form open for the
    // browser to close at the end of the body; closing it here gives the same document, and the
    // shared harness's browser smoke requires complete forms.
    content.append("<form data-controller=\"auto-submit\" action=\""); escape(content, path);
    content.append("\" accept-charset=\"UTF-8\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"put\" /></form>");
    ctx.page_content = content;
    respond_page(out, req, ctx, 200);
}

// sessions/incompatible_browser, for the signed-in user if there is one.
fn render_incompatible_browser(db, req: const http::Request&, out: http::Reply, user: i64) {
    var bytes: u8[>..] = [];
    let agent, has_agent = http::field_of(req, "User-Agent");
    var ctx = public_context(db, bytes, if apple_messages(agent) { "Campfire" } else { "Unsupported browser" }, "");
    if user > 0 { ctx.user = load_user(db, user, auth_config.signed_id_key, bytes); }
    var c: u8[>..] = [];
    c.append("<div class=\"panel center\"><header><h1 class=\"txt-x-large txt-tight-lines txt-align-center margin-none-block-start margin-block-end\">Upgrade to a supported web browser</h1>");
    c.append("<div class=\"flex align-start gap\">"); c.append(auth_translation("incompatible_browser_messsage"));
    c.append("<p class=\"margin-none-block-start\">Campfire requires a modern web browser. Please use one of the browsers listed below and make sure auto-updates are enabled.</p></div></header>");
    c.append("<div class=\"browser-list flex align-center flex-wrap gap justify-center margin-block\">");
    let browsers: const u8[:][4] = ["safari", "chrome", "firefox", "opera"];
    let versions: const u8[:][4] = ["17.2", "120", "121", "104"];
    for browser, i in browsers {
        c.append("<div class=\"browser flex flex-column\">");
        c.append(image_html(str("browsers/", browser, ".svg"), [html_attr("aria-hidden", "true"), html_attr("class", "center")]));
        c.append("<div class=\"flex flex-column align-center margin-block-start-half\"><strong>"); c.append(capitalized(browser));
        c.append("</strong><span> "); c.append(versions[i]); c.append("+</span></div></div>");
    }
    c.append("</div></div>");
    ctx.page_content = c;
    respond_page(out, req, ctx, 200);
}

// --- AllowBrowser ------------------------------------------------------------------------------

// The worker's last User-Agent and its verdict: a browser sends the same one with every request.
struct BrowserMemo { agent: u8[..512] = [], blocked: bool = false }
var browser_memo = BrowserMemo { .. };

fn request_browser_blocked(req: const http::Request&) -> bool {
    let agent, has_agent = http::field_of(req, "User-Agent");
    guard has_agent && agent.len > 0 else { return false; }
    guard agent.len <= 512 else { return browser_blocked(agent); }
    if agent != browser_memo.agent[..] { browser_memo = BrowserMemo { agent: agent, blocked: browser_blocked(agent) }; }
    return browser_memo.blocked;
}

// allow_browser's before_action: the unsupported-browser page, and true, for a blocked browser.
fn allow_browser(db: sqlite::Db, req: const http::Request&, out: http::Reply, user: i64 = 0) -> bool {
    guard request_browser_blocked(req) else { return false; }
    let failed = sqlite::run() { render_incompatible_browser(db, req, out, user); };
    if failed.len > 0 { public_exception(out, req, 500); }
    return true;
}

// The paths of the controllers that allow unauthenticated access and answer before
// authentication here (PwaController, Accounts::LogosController#show, QrCodeController).
fn public_controller_path(req: const http::Request&) -> bool {
    let path = http::path_of(req.target);
    return path == "/webmanifest" || path == "/webmanifest.json" || path == "/service-worker" || path == "/service-worker.js" ||
           path == "/account/logo" || path == "/account/logo.png" || starts_with(path, "/qr_code/");
}

// --- Sign in -----------------------------------------------------------------------------------

// A request parameter of a form, urlencoded or multipart.
fn param(req: const http::Request&, body: const u8[:], name: const u8[:], out: u8[>..]&) -> bool {
    let kind, typed = http::field_of(req, "Content-Type");
    if typed && starts_with(html_lower_ascii(kind), "multipart/form-data") {
        let data, fields, found = http::find_part(req, body, name);
        if found == http::PART_FOUND { out.append(data); return true; }
        return false;
    }
    if http::form_value(body, name, out) { return true; }
    // A GET's parameters are in its query.
    let raw, has = http::query_of(req.target, name);
    return has && http::decode(raw, out, true);
}

// SessionsController#create: rate_limit, then User.active.authenticate_by.
fn sessions_create(db: sqlite::Db, req: const http::Request&, body: const u8[:], out: http::Reply) {
    let ip = remote_ip(req, out);
    var email: u8[>..] = []; var password: u8[>..] = [];
    let has_email = param(req, body, "email_address", email);
    let has_password = param(req, body, "password", password);
    if campfire_rate_count(str("rate-limit:sessions:", ip), campfire_clock_ms(), RATE_LIMIT_WITHIN_MS) > RATE_LIMIT_TO {
        let failed = sqlite::run() { render_sign_in(db, req, out, 429, true, email, has_email); };
        if failed.len > 0 { public_exception(out, req, 500); }
        return;
    }
    var user: i64 = 0; var digest: u8[>..] = [];
    let found = sqlite::run() {
        if has_password && password.len > 0 {
            // find_by(email_address: params[:email_address]): nil finds an address that is NULL.
            let rows = if has_email { sql_rows(db, "SELECT id,coalesce(password_digest,'') FROM users WHERE email_address=? AND status=0 LIMIT 1", [sql_text(email)]) }
                       else { sql_rows(db, "SELECT id,coalesce(password_digest,'') FROM users WHERE email_address IS NULL AND status=0 LIMIT 1", []) };
            for row in rows { let id, ok = parse_int(cell(row, 0)); user = id; digest.append(cell(row, 1)); }
        }
    };
    if found.len > 0 { public_exception(out, req, 500); return; }
    let verified = user > 0 && digest.len > 0 && campfire_password_verify(password, digest) == 1;
    if !verified {
        let failed = sqlite::run() { render_sign_in(db, req, out, 401, true, email, has_email); };
        if failed.len > 0 { public_exception(out, req, 500); }
        return;
    }
    let token = hex_token(12);
    var now: u8[>..] = []; campfire_sql_now(now);
    var started = false;
    let failed = write_transaction(db) {
        if sql_number(db, "SELECT count(*) FROM users WHERE id=? AND status=0 AND password_digest=?", [sql_text(user), sql_text(digest)]) == 1 {
            start_session(db, req, out, user, token, now); started = true;
        }
    };
    if failed.len > 0 { public_exception(out, req, 500); return; }
    if !started {
        let again = sqlite::run() { render_sign_in(db, req, out, 401, true, email, has_email); };
        return;
    }
    let location, consumed = post_authenticating_url(req);
    signed_in_redirect(out, token, location, consumed);
}

// --- First run and joining ---------------------------------------------------------------------

// Rails' join codes: SecureRandom.alphanumeric(12) in groups of four.
fn join_code() -> u8[>..] {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var out: u8[>..] = [];
    while out.len < 14 {
        var raw: u8[1] = [0]; hash::random_bytes(raw);
        if raw[0] >= 248 { continue; }
        if out.len == 4 || out.len == 9 { out.push('-'); }
        out.push(alphabet[raw[0] % 62]);
    }
    return out;
}

// The user[...] parameters, and whether there were any (params.require(:user)).
struct UserParams { name: u8[] = [], has_name: bool = false, email: u8[] = [], has_email: bool = false, password: u8[] = [], has_password: bool = false }

fn user_params(req: const http::Request&, body: const u8[:]) -> UserParams, bool {
    var name: u8[>..] = []; var email: u8[>..] = []; var password: u8[>..] = [];
    let has_name = param(req, body, "user[name]", name); let has_email = param(req, body, "user[email_address]", email);
    let has_password = param(req, body, "user[password]", password);
    let p = UserParams { name: str(name), has_name: has_name, email: str(email), has_email: has_email, password: str(password), has_password: has_password };
    let avatar, fields, found = http::find_part(req, body, "user[avatar]");
    return p, p.has_name || p.has_email || p.has_password || found == http::PART_FOUND;
}

// The user's avatar written to the service, before the transaction; false for a bad upload.
fn stage_avatar(req: const http::Request&, body: const u8[:], upload: Upload&, staged: bool&) -> bool {
    staged = false;
    let kind, typed = http::field_of(req, "Content-Type");
    guard typed && starts_with(html_lower_ascii(kind), "multipart/form-data") else { return true; }
    let data, fields, found = http::find_part(req, body, "user[avatar]");
    if found == http::PART_TYPE || found == http::PART_BAD { return false; }
    let part, raw_filename, disposed = http::disposition(fields);
    guard found == http::PART_FOUND && data.len > 0 && raw_filename.len > 0 else { return true; }
    let declared, has_declared = http::field_in(fields, "content-type");
    guard stage_upload(auth_config.storage, data, unquote_filename(raw_filename), declared, upload) else { return false; }
    staged = true;
    return true;
}

// User.create!(user_params) inside a transaction: the user, its avatar, and memberships of the open
// rooms (after_create_commit). The user's id.
fn create_user(db, p: const UserParams&, administrator: bool, upload: const Upload&, staged: bool, now: const u8[:], avatar: i64&) -> i64 {
    var digest: u8[>..] = [];
    if p.has_password && p.password.len > 0 {
        var entropy: u8[16] = [0; 16]; hash::random_bytes(entropy);
        if !campfire_password_hash(p.password[..min(72, p.password.len)], entropy, digest) { sqlite::fail("Password hashing failed"); }
    }
    if !p.has_name { sqlite::fail(19, "NOT NULL constraint failed: users.name"); }
    sql_rows(db, "INSERT INTO users(name,email_address,password_digest,role,status,created_at,updated_at) VALUES(?,iif(?,?,NULL),NULLIF(?,''),?,0,?,?)",
        [sql_text(p.name), sql_text(if p.has_email { 1 } else { 0 }), sql_text(p.email), sql_text(digest), sql_text(if administrator { 1 } else { 0 }), sql_text(now), sql_text(now)]);
    let user = sqlite::last_insert_rowid(db);
    if staged {
        let blob = save_upload(db, upload, "avatar", "User", user, now);
        if variable_content_type(upload.content_type) { avatar = blob; }
    }
    return user;
}

// FirstRunsController and UsersController#new/create.
fn first_run_create(db: sqlite::Db, req: const http::Request&, body: const u8[:], out: http::Reply) {
    let p, present = user_params(req, body);
    guard present else { public_exception(out, req, 400); return; }
    var upload = Upload { .. }; var staged = false;
    guard stage_avatar(req, body, upload, staged) else { public_exception(out, req, 400); return; }
    let token = hex_token(12);
    var now: u8[>..] = []; campfire_sql_now(now);
    var created = false; var repeated = false; var avatar: i64 = 0; var user: i64 = 0;
    let failed = write_transaction(db) {
        if sql_number(db, "SELECT count(*) FROM accounts", []) > 0 { repeated = true; }
        else {
            sql_rows(db, "INSERT INTO accounts(name,join_code,settings,created_at,updated_at) VALUES('Campfire',?,'{}',?,?)", [sql_text(join_code()), sql_text(now), sql_text(now)]);
            user = create_user(db, p, true, upload, staged, now, avatar);
            sql_rows(db, "INSERT INTO rooms(name,type,creator_id,created_at,updated_at) VALUES('All Talk','Rooms::Open',?,?,?)", [sql_text(user), sql_text(now), sql_text(now)]);
            sql_rows(db, "INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT id,?,'mentions',?,? FROM rooms WHERE type='Rooms::Open'", [sql_text(user), sql_text(now), sql_text(now)]);
            start_session(db, req, out, user, token, now);
            created = true;
        }
    };
    var unique = false;
    for error in failed { if sqlite::primary(error.code) == sqlite::CONSTRAINT && find(error.message, "UNIQUE") >= 0 { unique = true; } }
    if !created && staged { delete_blob_file(auth_config.storage, upload.key); }
    if failed.len > 0 && !unique { for e in failed { write_stderr(str(e.message, "\n")); } public_exception(out, req, 500); return; }
    if !created { redirect_302(out, str(base_url(req), "/")); return; }
    if avatar > 0 { process_later(MEDIA_AVATAR, avatar, user, avatar_variation()); }
    signed_in_redirect(out, token, str(base_url(req), "/"), false);
}

fn users_create(db: sqlite::Db, req: const http::Request&, body: const u8[:], out: http::Reply, code: const u8[:]) {
    let p, present = user_params(req, body);
    guard present else { public_exception(out, req, 400); return; }
    var upload = Upload { .. }; var staged = false;
    guard stage_avatar(req, body, upload, staged) else { public_exception(out, req, 400); return; }
    let token = hex_token(12);
    var now: u8[>..] = []; campfire_sql_now(now);
    var created = false; var refused = false; var avatar: i64 = 0; var user: i64 = 0;
    let failed = write_transaction(db) {
        if sql_number(db, "SELECT count(*) FROM accounts WHERE join_code=?", [sql_text(code)]) == 0 { refused = true; }
        else {
            user = create_user(db, p, false, upload, staged, now, avatar);
            sql_rows(db, "INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT id,?,'mentions',?,? FROM rooms WHERE type='Rooms::Open'", [sql_text(user), sql_text(now), sql_text(now)]);
            start_session(db, req, out, user, token, now);
            created = true;
        }
    };
    var unique = false;
    for error in failed { if sqlite::primary(error.code) == sqlite::CONSTRAINT && find(error.message, "UNIQUE") >= 0 { unique = true; } }
    if !created && staged { delete_blob_file(auth_config.storage, upload.key); }
    if refused { head_only(out, 404); return; }
    if unique {
        // rescue ActiveRecord::RecordNotUnique: to sign in, with the address filled in.
        var location: u8[>..] = []; location.append(base_url(req)); location.append("/session/new");
        if p.has_email { location.append("?email_address="); rack_escape(location, p.email); }
        redirect_302(out, location); return;
    }
    if failed.len > 0 { for e in failed { write_stderr(str(e.message, "\n")); } public_exception(out, req, 500); return; }
    if avatar > 0 { process_later(MEDIA_AVATAR, avatar, user, avatar_variation()); }
    signed_in_redirect(out, token, str(base_url(req), "/"), false);
}

// --- Session transfers -------------------------------------------------------------------------

// Sessions::TransfersController#update: User.active.find_by_transfer_id, signed in, or 400.
fn transfer_update(db: sqlite::Db, req: const http::Request&, out: http::Reply, id: const u8[:]) {
    var now: u8[>..] = []; campfire_now(now);
    var user = verify_id(id, "user/transfer", auth_config.signed_id_key, now);
    // Links this server made before it used Rails' purpose.
    if user <= 0 { user = verify_id(id, "campfire/session_transfer", auth_config.signed_id_key, now); }
    let token = hex_token(12);
    var stamp: u8[>..] = []; campfire_sql_now(stamp);
    var started = false;
    let failed = write_transaction(db) {
        if user > 0 && sql_number(db, "SELECT count(*) FROM users WHERE id=? AND status=0", [sql_text(user)]) == 1 {
            start_session(db, req, out, user, token, stamp); started = true;
        }
    };
    if failed.len > 0 { public_exception(out, req, 500); return; }
    guard started else { head_only(out, 400); return; }
    let location, consumed = post_authenticating_url(req);
    signed_in_redirect(out, token, location, consumed);
}

// --- Sign out ----------------------------------------------------------------------------------

// SessionsController#destroy for user: remove_push_subscription, terminate_current_session (the
// session row, the Rails session, the cookie, and the user's cable connections), then root.
fn sessions_destroy(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], out: http::Reply) {
    let raw, has_cookie = http::cookie_of(req, "session_token");
    var token: u8[>..] = []; var valid_until: u8[>..] = []; var now: u8[>..] = []; campfire_now(now);
    if has_cookie && now.len == 24 { verify_cookie(raw, auth_config.cookie_key, now, token, valid_until); }
    var endpoint: u8[>..] = [];
    let has_endpoint = param(req, body, "push_subscription_endpoint", endpoint);
    let failed = write_transaction(db) {
        if has_endpoint { sql_rows(db, "DELETE FROM push_subscriptions WHERE endpoint=? AND user_id=?", [sql_text(endpoint), sql_text(user)]); }
        if token.len > 0 { sql_rows(db, "DELETE FROM sessions WHERE token=?", [sql_text(token)]); }
    };
    if failed.len > 0 { for e in failed { write_stderr(str(e.message, "\n")); } public_exception(out, req, 500); return; }
    cable_revoke(user, true);
    http::start(out, 302);
    http::field(out, "Location", str(base_url(req), "/"));
    let rails_session, has_rails_session = http::cookie_of(req, SESSION_COOKIE);
    if has_rails_session { delete_session_cookie(out); }
    http::field(out, "Set-Cookie", "session_token=; path=/; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT; samesite=lax");
    http::finish(out, "Content-Type: text/html; charset=utf-8\r\nContent-Length: ", "");
}

// --- Routes ------------------------------------------------------------------------------------

// ActionController::InvalidAuthenticityToken's 422 page (the origin check stands for the token's).
fn csrf_refused(out: http::Reply, req: const http::Request&) { public_exception(out, req, 422); }

// The routes that allow unauthenticated access: sign in, first run, joining and session transfers
// (not their QR codes). False for any other request.
fn auth_route(db: sqlite::Db, req: const http::Request&, body: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    let sessions = path == "/session/new" || path == "/session";
    let first_run = path == "/first_run";
    let join = starts_with(path, "/join/") && path.len > 6 && find(path[6..], "/") < 0;
    let transfer = starts_with(path, "/session/transfers/") && path.len > 19 && find(path[19..], "/") < 0;
    guard sessions || first_run || join || transfer else { return false; }
    let method = effective_method(req, body);
    let reading = method == "GET" || method == "HEAD";
    // Routes Rails doesn't draw here are its 404; DELETE /session needs a signed-in user.
    if path == "/session" && method == "DELETE" { return false; }
    let routed = path == "/session/new" && reading || path == "/session" && method == "POST" || first_run && (reading || method == "POST") ||
                 join && (reading || method == "POST") || transfer && (reading || method == "PUT" || method == "PATCH");
    if !routed { routing_error(out, req); return true; }
    if !reading && !request_same_origin(req) { csrf_refused(out, req); return true; }
    if allow_browser(db, req, out) { return true; }
    if path == "/session" { sessions_create(db, req, body, out); return true; }
    if transfer && !reading { transfer_update(db, req, out, path[19..]); return true; }
    var signed_in: i64 = 0;
    if join {
        // require_unauthenticated_access: a signed-in user goes to root.
        let raw, has_cookie = http::cookie_of(req, "session_token");
        if has_cookie {
            var token: u8[>..] = []; var valid_until: u8[>..] = []; var now: u8[>..] = []; campfire_now(now);
            if now.len == 24 && verify_cookie(raw, auth_config.cookie_key, now, token, valid_until) { signed_in = max(cable_session_user(db, token), 0); }
        }
        if signed_in > 0 { redirect_302(out, str(base_url(req), "/")); return true; }
    }
    var code: u8[>..] = [];
    if join && !http::decode(path[6..], code, false) { head_only(out, 404); return true; }
    if join && !reading {
        let exists = sqlite::run() { if sql_number(db, "SELECT count(*) FROM accounts WHERE join_code=?", [sql_text(code)]) == 0 { code.clear(); } };
        if code.len == 0 { head_only(out, 404); return true; }
        users_create(db, req, body, out, code); return true;
    }
    if first_run && !reading {
        var any = false;
        let checked = sqlite::run() { any = sql_number(db, "SELECT count(*) FROM accounts", []) > 0; };
        if any { redirect_302(out, str(base_url(req), "/")); return true; }
        first_run_create(db, req, body, out); return true;
    }
    var status: i32 = 200;
    let failed = sqlite::run() {
        if path == "/session/new" {
            if sql_number(db, "SELECT count(*) FROM users", []) == 0 { status = 302; redirect_302(out, str(base_url(req), "/first_run")); }
            else { var email: u8[>..] = []; let has_email = param(req, "", "email_address", email); render_sign_in(db, req, out, 200, false, email, has_email); }
        } else if first_run {
            if sql_number(db, "SELECT count(*) FROM accounts", []) > 0 { status = 302; redirect_302(out, str(base_url(req), "/")); }
            else { render_first_run(db, req, out); }
        } else if join {
            if sql_number(db, "SELECT count(*) FROM accounts WHERE join_code=?", [sql_text(code)]) == 0 { status = 404; head_only(out, 404); }
            else { render_join(db, req, out, code); }
        } else {
            render_transfer(db, req, out, path);
        }
    };
    if failed.len > 0 { for e in failed { write_stderr(str(e.message, "\n")); } public_exception(out, req, 500); }
    return true;
}

// The before_actions that follow authentication here: allow_browser, and SessionsController#destroy.
fn authenticated_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    if path == "/session" && effective_method(req, body) == "DELETE" {
        if !request_same_origin(req) { csrf_refused(out, req); return true; }
        if allow_browser(db, req, out, user) { return true; }
        sessions_destroy(db, user, req, body, out);
        return true;
    }
    return allow_browser(db, req, out, user);
}

// Settings from the environment, before the workers start: config/initializers/version.rb's
// APP_VERSION and GIT_REVISION, and the keys derived from SECRET_KEY_BASE.
fn configure_auth(secret: const u8[:], cookie_key: const u8[:], signed_id_key: const u8[:], vapid: const u8[:], storage: const u8[:]) {
    var version: u8[>..] = []; var revision: u8[>..] = [];
    let has_version = env("APP_VERSION", version) && trim(version).len > 0;
    let has_revision = env("GIT_REVISION", revision);
    if has_version && version.len <= 256 { auth_config.app_version = version; }
    else if has_revision && trim(revision).len > 0 && revision.len <= 256 { auth_config.app_version = revision; }
    if has_revision && revision.len <= 256 { auth_config.git_revision = revision; auth_config.has_revision = true; }
    for i in 64 { auth_config.cookie_key[i] = cookie_key[i]; auth_config.signed_id_key[i] = signed_id_key[i]; }
    var key: u8[32] = [0; 32];
    hash::pbkdf2_sha256(key, secret, "authenticated encrypted cookie", 1000);
    auth_config.session_key = key;
    if vapid.len <= 256 { auth_config.vapid = vapid; }
    auth_config.storage = storage;
}
