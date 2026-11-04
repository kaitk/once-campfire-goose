namespace campfire;
import std;
import os;
import http;
import json;
import hash;
import base64;
import sqlite;
import database;
import setup;
import sessions;
import messages;
import html;
import auth;
import cable;
import avatars;
import storage;
import media;
import view_data;
import view_assets_generated;
import https;
import public_pages;
import cleanup;

// Account administration (Accounts::UsersController, Users::BansController, Accounts::JoinCodesController,
// Accounts::LogosController and store_logo for AccountsController#update), the PWA manifest and service
// worker (PwaController) and push subscription storage (Users::PushSubscriptionsController), after the
// Rails reference at 90b330024dec3e757c79b6a7e6568f93da8e3148.

// Active Storage's variation digests for the account logo's :large and :small PNG variants:
// SHA1 of Marshal.dump({format: :png, resize_to_limit: [n, n]}), Base64.
let LOGO_LARGE_DIGEST = "ksXvpLsa7BuCVyHOwmQOKedbIbM=";
let LOGO_SMALL_DIGEST = "EXATZfM7OVVC86CDh85TOsa8ZSw=";

let ADMIN_USERS: i32 = 1;
let ADMIN_USER: i32 = 2;
let ADMIN_JOIN_CODE: i32 = 3;
let ADMIN_LOGO: i32 = 4;
let ADMIN_BAN: i32 = 6;
let ADMIN_PUSH_INDEX: i32 = 7;
let ADMIN_PUSH: i32 = 8;
let ADMIN_PUSH_TEST: i32 = 9;

fn site_base(req: const http::Request&) -> u8[>..] {
    return base_url(req);
}

fn redirect_found(out: http::Reply, location: const u8[:]) {
    http::start(out,302); http::field(out,"Location",location); http::finish(out,http::TEXT,"Redirecting");
}

// Rails renders a template of the one format a route has when the path names it or Accept allows it.
fn accepts_format(req: const http::Request&, mime: const u8[:]) -> bool {
    let accept, has_accept = http::field_of(req,"Accept");
    return has_accept && (find(accept,mime) >= 0 || find(accept,"*/*") >= 0);
}

fn content_type_is(req: const http::Request&, mime: const u8[:]) -> bool {
    let kind, has_kind = http::field_of(req,"Content-Type");
    return has_kind && starts_with(html_lower(kind),mime);
}

// The last value of a repeated form field, as Rails keeps it (a check box after its hidden default).
fn form_last(body: const u8[:], key: const u8[:], out: u8[>..]&) -> bool {
    var found = false;
    for field in split(body,"&") {
        let eq = find(field,"=");
        var name: u8[>..] = [];
        if !http::decode(if eq < 0 { field } else { field[..eq] },name,true) || name != key { continue; }
        out.clear(); found = true;
        if eq >= 0 && !http::decode(field[eq+1..],out,true) { out.clear(); }
    }
    return found;
}

fn form_has_prefix(body: const u8[:], prefix: const u8[:]) -> bool {
    for field in split(body,"&") {
        let eq = find(field,"=");
        var name: u8[>..] = [];
        if http::decode(if eq < 0 { field } else { field[..eq] },name,true) && starts_with(name,prefix) { return true; }
    }
    return false;
}

fn random_text(count: i64, alphabet: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    var bytes: u8[64] = [0;64];
    let limit = 256 - 256 % alphabet.len;
    while out.len < count {
        hash::random_bytes(bytes);
        for b in bytes { if b < limit && out.len < count { out.push(alphabet[b % alphabet.len]); } }
    }
    return out;
}

fn random_uuid() -> u8[>..] {
    var bytes: u8[16] = [0;16]; hash::random_bytes(bytes);
    bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    var out: u8[>..] = []; let digits = "0123456789abcdef";
    for c, i in bytes {
        if i == 4 || i == 6 || i == 8 || i == 10 { out.push('-'); }
        out.push(digits[c >> 4]); out.push(digits[c & 15]);
    }
    return out;
}

// SecureRandom.alphanumeric(12).scan(/.{4}/).join("-")
fn new_join_code() -> u8[>..] {
    let code = random_text(12,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789");
    return str(code[..4],"-",code[4..8],"-",code[8..]);
}

fn blob_path(storage: const u8[:], key: const u8[:]) -> u8[>..] {
    return str(storage,"/",key[..2],"/",key[2..4],"/",key);
}

fn read_blob(storage: const u8[:], key: const u8[:], size: i64, out: u8[>..]&) -> bool {
    return storage_key_valid(key) && size > 0 && size <= 16*1024*1024 && read_file(blob_path(storage,key),out) && out.len == size;
}

// --- PWA -----------------------------------------------------------------------------------------

let SERVICE_WORKER = "self.addEventListener(\"push\", async (event) => {\n  const data = await event.data.json()\n  event.waitUntil(Promise.all([ showNotification(data), updateBadgeCount(data.options) ]))\n})\n\nasync function showNotification({ title, options }) {\n  return self.registration.showNotification(title, options)\n}\n\nasync function updateBadgeCount({ data: { badge } }) {\n  return self.navigator.setAppBadge?.(badge || 0)\n}\n\nself.addEventListener(\"notificationclick\", (event) => {\n  event.notification.close()\n\n  const url = new URL(event.notification.data.path, self.location.origin).href\n  event.waitUntil(openURL(url))\n})\n\nasync function openURL(url) {\n  const clients = await self.clients.matchAll({ type: \"window\" })\n  const focused = clients.find((client) => client.focused)\n\n  if (focused) {\n    await focused.navigate(url)\n  } else {\n    await self.clients.openWindow(url)\n  }\n}\n";

// pwa/manifest.json.erb: ERB escapes the account name as HTML, as Rails does.
fn webmanifest(db: sqlite::Db, req: const http::Request&, out: http::Reply) {
    if http::path_of(req.target) != "/webmanifest.json" && !accepts_format(req,"application/json") {
        public_exception(out,req,406); return;
    }
    var name: u8[>..] = []; var version: u8[>..] = []; var exists = false;
    let failed = sqlite::run() {
        for row in sql_rows(db,"SELECT name,updated_at FROM accounts ORDER BY id LIMIT 1",[]) { exists = true; name = str(cell(row,0)); version = version_number(cell(row,1)); }
    };
    if failed.len > 0 { public_exception(out,req,500); return; }
    let base = site_base(req);
    let small: u8[>..] = if exists { str("/account/logo?size=small&v=",version) } else { str("/account/logo?size=small") };
    let large: u8[>..] = if exists { str("/account/logo?v=",version) } else { str("/account/logo") };
    var text: u8[>..] = [];
    text.append("{\n  \"name\": \""); if exists { escape(text,name); } else { text.append("Campfire"); }
    text.append("\",\n  \"icons\": [\n    {\n      \"src\": \""); text.append(small);
    text.append("\",\n      \"type\": \"image/png\",\n      \"sizes\": \"192x192\"\n    },\n    {\n      \"src\": \""); text.append(large);
    text.append("\",\n      \"type\": \"image/png\",\n      \"sizes\": \"512x512\"\n    },\n    {\n      \"src\": \""); text.append(large);
    text.append("\",\n      \"type\": \"image/png\",\n      \"sizes\": \"512x512\",\n      \"purpose\": \"maskable\"\n    }\n  ],\n  \"start_url\": \"/\",\n  \"display\": \"standalone\",\n  \"scope\": \"/\",\n  \"description\": \"A chat app from the makers of Basecamp and HEY.\",\n  \"categories\": [\"social\", \"business\", \"productivity\"],\n  \"theme_color\": \"#ffffff\",\n  \"background_color\": \"#ffffff\",\n  \"shortcuts\": [\n    {\n      \"name\": \"New chat room\",\n      \"description\": \"Open Campfire and start a new chat room\",\n      \"url\": \"rooms/opens/new\",\n      \"icons\": [{ \"src\": \"");
    escape(text,str(base,asset_path("add.svg")));
    text.append("\", \"sizes\": \"any\" }]\n    },\n    {\n      \"name\": \"My profile\",\n      \"description\": \"Open Campfire and view your profile\",\n      \"url\": \"/users/me/profile\",\n      \"icons\": [{ \"src\": \"");
    escape(text,str(base,asset_path("person.svg")));
    text.append("\", \"sizes\": \"any\" }]\n    }\n  ],\n  \"screenshots\": [\n    {\n      \"src\": \"");
    escape(text,str(base,asset_path("screenshots/android-chat.png")));
    text.append("\",\n      \"sizes\": \"1080x2400\",\n      \"form_factor\": \"narrow\",\n      \"label\": \"Campfire is an installable, self-hosted group chat system.\"\n    },\n    {\n      \"src\": \"");
    escape(text,str(base,asset_path("screenshots/android-sidebar.png")));
    text.append("\",\n      \"sizes\": \"1080x2400\",\n      \"form_factor\": \"narrow\",\n      \"label\": \"Easily invite people. Make rooms. @mentions, DMs, and mobile support.\"\n    },\n    {\n      \"src\": \"");
    escape(text,str(base,asset_path("screenshots/android-dark-mode.png")));
    text.append("\",\n      \"sizes\": \"1080x2400\",\n      \"form_factor\": \"narrow\",\n      \"label\": \"Full support for dark mode, customizable to your brand.\"\n    }\n  ]\n}\n");
    http::respond(out,200,"application/json; charset=utf-8",text);
}

fn service_worker(req: const http::Request&, out: http::Reply) {
    if http::path_of(req.target) != "/service-worker.js" && !accepts_format(req,"javascript") {
        public_exception(out,req,406); return;
    }
    http::respond(out,200,"text/javascript; charset=utf-8",SERVICE_WORKER);
}

// --- The account logo ----------------------------------------------------------------------------

// Account's :large and :small variants: resize_to_limit: [512, 512] or [192, 192], format: :png.
fn logo_variation(small: bool) -> Variation {
    return if small { named_variation("png", 192, 192) } else { named_variation("png", 512, 512) };
}

// Accounts::LogosController#show, public, an ActionController::Live controller's: stale?(etag:
// Current.account) (with the etaggers' suffix), then expires_in 5.minutes, public: true,
// stale_while_revalidate: 1.week, and send_file of the logo's processed :large or :small PNG
// variant, or the stock icon for a logo Rails cannot vary or an account without one; 304 when
// none_match holds the ETag (and since, an If-Modified-Since, is absent). Returns the logo blob
// whose variant isn't made yet, for a media thread, or 0; with fallback, such a logo gets the stock
// icon instead.
fn logo_answer(db: sqlite::Db, small: bool, none_match: const u8[:], since: bool, suffix: const u8[:], storage: const u8[:], fallback: bool, answer: MediaAnswer&) -> i64 {
    var pending: i64 = 0; var fresh = false; var stock = true;
    answer.status = 200; answer.content_type = "image/png";
    let failed = sqlite::run() {
        let rows = sql_rows(db,"SELECT a.id,a.updated_at,b.id,b.key,b.content_type,b.byte_size FROM accounts a LEFT JOIN active_storage_attachments t ON t.record_type='Account' AND t.name='logo' AND t.record_id=a.id LEFT JOIN active_storage_blobs b ON b.id=t.blob_id ORDER BY a.id,t.id DESC LIMIT 1",[]);
        for row in rows {
            let id, numeric = parse_int(cell(row,0));
            let etag = weak_etag(str(cache_key_with_version("accounts",id,cell(row,1)),suffix));
            answer.etag = etag;
            if etag_fresh(none_match,since,etag) { fresh = true; }
            if cell(row,2).len > 0 && variable_content_type(cell(row,4)) {
                let variants = sql_rows(db,"SELECT vb.key,vb.byte_size FROM active_storage_variant_records v JOIN active_storage_attachments va ON va.record_type='ActiveStorage::VariantRecord' AND va.name='image' AND va.record_id=v.id JOIN active_storage_blobs vb ON vb.id=va.blob_id WHERE v.blob_id=? AND v.variation_digest=?",[sql_text(cell(row,2)),str(if small { LOGO_SMALL_DIGEST } else { LOGO_LARGE_DIGEST })]);
                var served = false;
                for variant in variants {
                    let n, valid = parse_int(cell(variant,1));
                    if !fresh && !read_blob(storage,cell(variant,0),n,answer.body) { answer.status = 500; }
                    // send_file of ActiveStorage::Blob.service.path_for(key): named after the key.
                    answer.disposition = content_disposition("inline",cell(variant,0));
                    served = true;
                }
                if !served && !fallback && !fresh { let blob, valid = parse_int(cell(row,2)); pending = blob; }
                stock = !served;
            }
        }
        if pending == 0 && answer.status == 200 && stock {
            let name = if small { "app-icon-192.png" } else { "app-icon.png" };
            let index = asset_logical_index(str("logos/",name));
            if !fresh && !read_file(str("assets/reference/",asset_filename(index)),answer.body) { answer.status = 500; }
            answer.disposition = content_disposition("inline",name);
        }
    };
    if failed.len > 0 { answer.status = 500; pending = 0; }
    // The 304 has the 200's fields, as Thruster's cache answers it.
    if fresh && answer.status == 200 && pending == 0 { answer.status = 304; }
    answer.cache = "max-age=300, public, stale-while-revalidate=604800";
    answer.binary = true; answer.versioned = true;
    if answer.status != 200 && answer.status != 304 { answer.body.clear(); }
    return pending;
}

fn account_logo(db: sqlite::Db, req: const http::Request&, storage: const u8[:], out: http::Reply) {
    let size, has_size = http::query_of(req.target,"size");
    let small = has_size && size == "small";
    let none_match, has_none_match = http::field_of(req,"If-None-Match");
    let since_value, since = http::field_of(req,"If-Modified-Since");
    let suffix = etagger_suffix(req,"");
    var answer = MediaAnswer { .. };
    let pending = logo_answer(db,small,none_match,since,suffix,storage,false,answer);
    if pending > 0 {
        // Account#logo_variant: processed by a media thread while this exchange waits.
        if qput(MediaJob { kind: MEDIA_LOGO, blob: pending, record: if small { 1 } else { 0 }, wait: true, reply: http::later(out,60000), etag: suffix, .. }) { return; }
        answer = MediaAnswer { .. };
        let fallback = logo_answer(db,small,none_match,since,suffix,storage,true,answer);
    }
    if answer.status != 200 && answer.status != 304 { public_exception(out,req,answer.status); return; }
    send_answer(out,answer);
}

// Unauthenticated routes: the manifest, the service worker and the account logo.
fn public_route(db: sqlite::Db, req: const http::Request&, storage: const u8[:], out: http::Reply) -> bool {
    if req.method != "GET" && req.method != "HEAD" { return false; }
    let path = http::path_of(req.target);
    if path == "/webmanifest" || path == "/webmanifest.json" { webmanifest(db,req,out); return true; }
    if path == "/service-worker" || path == "/service-worker.js" { service_worker(req,out); return true; }
    if path == "/account/logo" || path == "/account/logo.png" { account_logo(db,req,storage,out); return true; }
    return false;
}

// AccountsController#update with a logo: the account[logo] file of a multipart form. The file is written
// before the transaction, and removed again if it does not commit.
fn store_logo(db, req: const http::Request&, body: const u8[:], storage: const u8[:], now: const u8[:], keys: u8[][>..]&, written: u8[>..]&, logo: i64&) -> i32 {
    let data, fields, found = http::find_part(req,body,"account[logo]");
    if found == http::PART_TYPE || found == http::PART_BAD { return 400; }
    let account = sql_number(db,"SELECT id FROM accounts ORDER BY id LIMIT 1",[]);
    if account == 0 { return 500; }
    let name, name_fields, has_name = http::find_part(req,body,"account[name]");
    if has_name == http::PART_FOUND && name.len > 0 { sql_rows(db,"UPDATE accounts SET name=?,updated_at=? WHERE id=?",[sql_text(name),sql_text(now),sql_text(account)]); }
    if found != http::PART_FOUND || data.len == 0 { return 302; }
    let part_name, filename, disposed = http::disposition(fields);
    let declared, typed = http::field_in(fields,"content-type");
    var upload = Upload { .. };
    if !stage_upload(storage,data,unquote_filename(filename),declared,upload) { sqlite::fail("Cannot write the logo"); }
    written.append(upload.key);
    if upload.filename.len == 0 { upload.filename = str("logo"); }
    purge_attachments(db,"record_type='Account' AND name='logo' AND record_id=?",[sql_text(account)],keys);
    logo = save_upload(db,upload,"logo","Account",account,now);
    // A logo libvips can't vary has no variants to make; a video or audio file is analyzed with
    // ffprobe instead (AnalyzeJob), which a negative logo asks for.
    if !variable_content_type(upload.content_type) { logo = if probed_content_type(upload.content_type) { -logo } else { 0 }; }
    sql_rows(db,"UPDATE accounts SET updated_at=? WHERE id=?",[sql_text(now),sql_text(account)]);
    return 302;
}

// --- Users and bans ------------------------------------------------------------------------------

fn parse_ipv4(text: const u8[:], out: u8[:]) -> bool {
    var part: i64 = 0; var value: i64 = 0; var digits: i64 = 0;
    for c in text {
        if c == '.' {
            if digits == 0 || part == 3 { return false; }
            out[part] = value as! u8; part++; value = 0; digits = 0;
        } else if c >= '0' && c <= '9' {
            if digits > 0 && value == 0 { return false; }
            value = value*10 + c - 48; digits++;
            if value > 255 { return false; }
        } else { return false; }
    }
    if digits == 0 || part != 3 { return false; }
    out[3] = value as! u8; return true;
}

fn ipv6_words(side: const u8[:], words: i64[>..]&) -> bool {
    if side.len == 0 { return true; }
    for group in split(side,":") {
        if group.len == 0 || group.len > 4 { return false; }
        var word: i64 = 0;
        for c in group { let d = hex_digit(c); if d < 0 { return false; } word = word*16 + d; }
        words.push(word);
    }
    return true;
}

fn parse_ipv6(text: const u8[:], out: u8[:]) -> bool {
    var body = text; var tail: u8[4] = [0;4]; var mapped = false;
    if find(text,".") >= 0 {
        var colon: i64 = -1; for c, i in text { if c == ':' { colon = i; } }
        if colon < 0 || !parse_ipv4(text[colon+1..],tail) { return false; }
        mapped = true;
        body = if ends_with(text[..colon+1],"::") { text[..colon+1] } else { text[..colon] };
    }
    var left: i64[>..] = []; var right: i64[>..] = [];
    let gap = find(body,"::");
    if gap >= 0 {
        if find(body[gap+2..],"::") >= 0 || !ipv6_words(body[..gap],left) || !ipv6_words(body[gap+2..],right) { return false; }
    } else if !ipv6_words(body,left) { return false; }
    let given = left.len + right.len + (if mapped { 2 } else { 0 });
    if gap >= 0 && given > 7 || gap < 0 && given != 8 { return false; }
    for i in 16 { out[i] = 0; }
    for word, i in left { out[2*i] = (word >> 8) as! u8; out[2*i+1] = (word & 255) as! u8; }
    let limit = if mapped { 12 } else { 16 };
    for word, i in right { let at = limit - 2*right.len + 2*i; out[at] = (word >> 8) as! u8; out[at+1] = (word & 255) as! u8; }
    if mapped { for i in 4 { out[12+i] = tail[i]; } }
    return true;
}

fn ipv4_internal(a: const u8[:]) -> bool {
    return a[0] == 127 || a[0] == 10 || a[0] == 172 && a[1] >= 16 && a[1] < 32 || a[0] == 192 && a[1] == 168 || a[0] == 169 && a[1] == 254;
}

// Ban's validation: IPAddr must parse it, and it must not be loopback, private or link-local.
fn public_address(text: const u8[:]) -> bool {
    var v4: u8[4] = [0;4];
    if parse_ipv4(text,v4) { return !ipv4_internal(v4); }
    var v6: u8[16] = [0;16];
    if !parse_ipv6(text,v6) { return false; }
    var zero = true; for i in 10 { if v6[i] != 0 { zero = false; } }
    if zero && v6[10] == 255 && v6[11] == 255 { return !ipv4_internal(v6[12..]); }
    var loopback = v6[15] == 1; for i in 15 { if v6[i] != 0 { loopback = false; } }
    return !loopback && (v6[0] & 254) != 252 && !(v6[0] == 254 && (v6[1] & 192) == 128);
}

fn user_title(name: const u8[:], bio: const u8[:]) -> u8[>..] {
    return str(name,if bio.len > 0 && name.len > 0 { " – " } else { "" },bio);
}

// accounts/users/_user.html.erb. Columns: id, name, bio, updated_at, role, status.
fn account_user_html(out: u8[>..]&, row: const u8[][:], current: i64, admin: bool, key: const u8[:]) {
    let id, valid = parse_int(cell(row,0));
    let administrator = cell(row,4) == "1"; let bot = cell(row,4) == "2"; let active = cell(row,5) == "0";
    out.append("<li class=\"flex align-center gap margin-none "); if cell(row,5) == "2" { out.append("banned"); }
    out.append("\">\n  <figure class=\"avatar flex-item-no-shrink\" style=\"--avatar-size: 3.75ch;\">\n    <a title=\"");
    escape(out,user_title(cell(row,1),cell(row,2))); format(out,"\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\"/users/",id,"\"><img aria-hidden=\"true\" loading=\"lazy\" src=\"");
    escape(out,str(avatar_path(id,key),"?v=",version_number(cell(row,3))));
    out.append("\" width=\"48\" height=\"48\" /></a>\n  </figure>\n\n  <div class=\"min-width\">\n    <div class=\"overflow-ellipsis fill-shade\"><strong>");
    escape(out,cell(row,1)); out.append("</strong></div>\n  </div>\n\n  <hr class=\"separator\" aria-hidden=\"true\">\n\n");
    if admin && active {
        if !bot {
            let disabled = if id == current { "disabled=\"disabled\" " } else { "" };
            format(out,"      <form data-controller=\"form\" action=\"/account/users/",id,"\" accept-charset=\"UTF-8\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\" />\n");
            format(out,"        <label class=\"btn txt-small flex-item-no-shrink\" for=\"role_user_",id,"\">\n          <span class=\"for-screen-reader\">Role: ",if administrator { "Administrator" } else { "Member" },"</span>\n");
            format(out,"          <img aria-hidden=\"true\" src=\"",asset_path("crown.svg"),"\" width=\"20\" height=\"20\" />\n");
            format(out,"          <input name=\"user[role]\" ",disabled,"type=\"hidden\" value=\"member\" /><input data-action=\"form#submit\" hidden=\"hidden\" id=\"role_user_",id,"\" ",disabled,"type=\"checkbox\" value=\"administrator\" ",if administrator { "checked=\"checked\" " } else { "" },"name=\"user[role]\" />\n        </label>\n</form>\n");
        }
        if id != current {
            format(out,"      <form class=\"button_to\" method=\"post\" action=\"/account/users/",id,"\"><input type=\"hidden\" name=\"_method\" value=\"delete\" /><button class=\"btn txt-small flex-item-no-shrink btn--negative\" data-turbo-confirm=\"Are you sure you want to permanently remove this person from the account? This can’t be undone.\" type=\"submit\">\n");
            format(out,"        <img aria-hidden=\"true\" src=\"",asset_path("minus.svg"),"\" width=\"20\" height=\"20\" />\n        <span class=\"for-screen-reader\">Delete ");
            escape(out,cell(row,1)); out.append("</span>\n</button></form>");
        }
    }
    if id == current {
        format(out,"    <a class=\"btn txt-small flex-item-no-shrink\" target=\"_top\" href=\"/users/me/profile\">\n      <img aria-hidden=\"true\" src=\"",asset_path("pencil.svg"),"\" width=\"20\" height=\"20\" />\n      <span class=\"for-screen-reader\">My settings</span>\n</a>");
    }
    out.append("</li>\n");
}

fn next_page_html(out: u8[>..]&, page: i64) {
    format(out,"<turbo-frame id=\"next_page_container\" loading=\"lazy\" src=\"/account/users.turbo_stream?page=",page,"\" class=\"flex center\">\n  <div class=\"spinner center\"></div>\n</turbo-frame>\n");
}

let USER_COLUMNS = "SELECT id,name,bio,updated_at,role,status FROM users ";

// Accounts::UsersController#index, a turbo stream of a page of 500.
fn account_users_stream(db, req: const http::Request&, user: i64, admin: bool, key: const u8[:], out: u8[>..]&) {
    let requested, has_page = http::query_int(req.target,"page");
    let page = if has_page && requested > 0 && requested < 1000000 { requested } else { 1 };
    let rows = sql_rows(db,str(USER_COLUMNS,"WHERE status=0 AND role<>2 ORDER BY LOWER(name),id LIMIT 501 OFFSET ?"),[sql_text((page-1)*500)]);
    out.append("<turbo-stream action=\"replace\" target=\"next_page_container\"><template>");
    for row, i in rows { if i < 500 { account_user_html(out,row,user,admin,key); } }
    out.append("</template></turbo-stream>\n\n");
    if rows.len > 500 {
        out.append("  <turbo-stream action=\"append\" target=\"account_users\"><template>"); next_page_html(out,page+1); out.append("</template></turbo-stream>\n");
    }
}

// --- Push subscriptions --------------------------------------------------------------------------

let PUSH_HOSTS = "jmt17.google.com fcm.googleapis.com updates.push.services.mozilla.com web.push.apple.com notify.windows.com";

// Push::Subscription's endpoint validation, but for resolving the host, which the sender does when it
// delivers: an absolute https URL on port 443 at one of the permitted push services.
fn push_endpoint_valid(endpoint: const u8[:]) -> bool {
    guard endpoint.len > 0 && endpoint.len <= 2048 && starts_with(endpoint,"https://") else { return false; }
    for c in endpoint {
        if c <= ' ' || c >= 127 || c == '"' || c == '<' || c == '>' || c == '\\' || c == '^' || c == '`' || c == '{' || c == '|' || c == '}' { return false; }
    }
    var authority = endpoint[8..];
    for c, i in authority { if c == '/' || c == '?' || c == '#' { authority = authority[..i]; break; } }
    var at: i64 = -1; for c, i in authority { if c == '@' { at = i; } }
    if at >= 0 { authority = authority[at+1..]; }
    var host = authority;
    let colon = find(authority,":");
    if colon >= 0 {
        host = authority[..colon];
        let port = authority[colon+1..];
        if port.len > 0 { let n, valid = parse_int(port); if !valid || n != 443 { return false; } }
    }
    let lower = html_lower(host);
    if lower.len == 0 { return false; }
    for permitted in split(PUSH_HOSTS," ") {
        if lower == permitted || ends_with(lower,str(".",permitted)) { return true; }
    }
    return false;
}

// The permitted push_subscription params: each given key, with its value or as nil.
struct PushParams {
    given: bool[3] = [false;3],
    nil: bool[3] = [false;3],
    present: bool = false,
    oversized: bool = false,
    endpoint: u8[..4096] = [],
    p256dh_key: u8[..1024] = [],
    auth_key: u8[..1024] = [],
}

fn push_value(params: const PushParams&, i: i64) -> const u8[:] {
    return if i == 0 { params.endpoint[..] } else if i == 1 { params.p256dh_key[..] } else { params.auth_key[..] };
}

fn set_push_value(params: PushParams&, i: i64, value: const u8[:]) {
    params.given[i] = true;
    if value.len > (if i == 0 { 4096 } else { 1024 }) { params.oversized = true; return; }
    if i == 0 { params.endpoint = value; } else if i == 1 { params.p256dh_key = value; } else { params.auth_key = value; }
}

let PUSH_KEYS = "endpoint p256dh_key auth_key";

fn push_params(req: const http::Request&, body: const u8[:]) -> PushParams {
    var params = PushParams { .. };
    if content_type_is(req,"application/json") {
        var text: u8[>..] = []; text.append(body);
        var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
        let root, error = json::parse(text,nodes,strings);
        if error.len > 0 { return params; }
        // ParamsWrapper wraps a JSON body without the key under it.
        var object = json::member(root,"push_subscription");
        if !object { object .= root; }
        guard object else { return params; }
        match object.val {
            Obj o => { params.present = o.count > 0; },
            Null => { return params; },
            _ => { params.present = true; return params; },
        }
        for name, i in split(PUSH_KEYS," ") {
            let node = json::member(object,name);
            if node {
                let value, string = json::as_string(node);
                if string { set_push_value(params,i,value); } else { params.given[i] = true; params.nil[i] = true; }
            }
        }
    } else {
        params.present = form_has_prefix(body,"push_subscription[");
        for name, i in split(PUSH_KEYS," ") {
            var value: u8[>..] = [];
            if form_last(body,str("push_subscription[",name,"]"),value) { set_push_value(params,i,value); }
        }
    }
    return params;
}

// The useragent gem's browser, version and platform, for the common browsers.
fn ua_after(agent: const u8[:], marker: const u8[:]) -> const u8[:] {
    let at = find(agent,marker); if at < 0 { return ""; }
    let rest = agent[at+marker.len..];
    for c, i in rest { if c == ' ' || c == ';' || c == ')' { return rest[..i]; } }
    return rest;
}

fn user_agent_label(agent: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    if find(agent,"Edg/") >= 0 { out.append("Edge "); out.append(ua_after(agent,"Edg/")); }
    else if find(agent,"OPR/") >= 0 { out.append("Opera "); out.append(ua_after(agent,"OPR/")); }
    else if find(agent,"Chrome/") >= 0 { out.append("Chrome "); out.append(ua_after(agent,"Chrome/")); }
    else if find(agent,"CriOS/") >= 0 { out.append("Chrome "); out.append(ua_after(agent,"CriOS/")); }
    else if find(agent,"Firefox/") >= 0 { out.append("Firefox "); out.append(ua_after(agent,"Firefox/")); }
    else if find(agent,"Safari/") >= 0 { out.append("Safari "); out.append(ua_after(agent,"Version/")); }
    else {
        let slash = find(agent,"/");
        if slash > 0 { out.append(agent[..slash]); out.push(' '); out.append(ua_after(agent,"/")); } else { out.push(' '); }
    }
    out.append(" on ");
    out.append(if find(agent,"iPhone") >= 0 { "iPhone" } else if find(agent,"iPad") >= 0 { "iPad" }
        else if find(agent,"Android") >= 0 { "Android" } else if find(agent,"Macintosh") >= 0 { "Macintosh" }
        else if find(agent,"Windows") >= 0 { "Windows" } else if find(agent,"CrOS") >= 0 { "ChromeOS" }
        else if find(agent,"X11") >= 0 || find(agent,"Linux") >= 0 { "X11" } else { "" });
    return out;
}

fn push_subscriptions_html(db, user: i64, out: u8[>..]&) {
    out.append("<section class=\"panel panel--wide flex flex-column gap\">\n  <h1 class=\"txt-align-center txt-large margin-none\">Push Notification Subscriptions</h1>\n  <div class=\"pad-inline fill-shade border-radius\" id=\"push_subscriptions\">\n    <menu class=\"pad flex flex-column gap\">\n");
    for row in sql_rows(db,"SELECT id,user_agent,endpoint FROM push_subscriptions WHERE user_id=? ORDER BY id",[sql_text(user)]) {
        out.append("      <li class=\"flex flex-column margin-none membership-item\">\n  <span class=\"overflow-ellipsis txt-primary txt-undecorated\">\n    <strong>");
        escape(out,user_agent_label(cell(row,1))); out.append("</strong><br>\n  </span>\n\n  <span class=\"flex align-start gap txt-small\">\n    <span>");
        escape(out,cell(row,2));
        format(out,"</span>\n\n    <span class=\"flex align-center gap\">\n      <form class=\"button_to\" method=\"post\" action=\"/users/me/push_subscriptions/",cell(row,0),"/test_notifications\"><button class=\"btn btn--reversed\" type=\"submit\">\n");
        format(out,"        <img aria-hidden=\"true\" src=\"",asset_path("notification-bell-everything.svg"),"\" width=\"20\" height=\"20\" />\n        <span class=\"for-screen-reader\">Send test notification</span>\n</button></form>\n");
        format(out,"      <form class=\"button_to\" method=\"post\" action=\"/users/me/push_subscriptions/",cell(row,0),"\"><input type=\"hidden\" name=\"_method\" value=\"delete\" /><button class=\"btn btn--negative\" type=\"submit\">\n");
        format(out,"        <img aria-hidden=\"true\" src=\"",asset_path("minus.svg"),"\" width=\"20\" height=\"20\" />\n        <span class=\"for-screen-reader\">Delete subscription</span>\n</button></form>    </span>\n  </span>\n</li>\n");
    }
    out.append("    </menu>\n  </div>\n</section>\n");
}

// Users::PushSubscriptionsController#create: an existing subscription with these params is touched if its
// endpoint is still valid, and a new one is saved if valid; inside the write transaction. A password change
// ends every session and subscription, so register_while_signed_in saves nothing for a session that is
// gone by then, and answers 401.
fn create_push_subscription(db, req: const http::Request&, body: const u8[:], user: i64, now: const u8[:]) -> i32 {
    let token = request_session_token(req);
    let params = push_params(req,body);
    if !params.present { return 400; }
    if params.oversized { return 422; }
    var query: u8[>..] = str("SELECT id,endpoint FROM push_subscriptions WHERE user_id=?");
    var args: u8[][>..] = []; args.push(sql_text(user));
    for name, i in split(PUSH_KEYS," ") {
        if !params.given[i] { continue; }
        if params.nil[i] { format(query," AND ",name," IS NULL"); } else { format(query," AND ",name,"=?"); args.push(str(push_value(params,i))); }
    }
    query.append(" ORDER BY id LIMIT 1");
    let existing = sql_rows(db,query,copy(args));
    let signed_in = token.len > 0 && sql_number(db,"SELECT count(*) FROM sessions WHERE token=?",[sql_text(token)]) > 0;
    for row in existing {
        if !push_endpoint_valid(cell(row,1)) { return 422; }
        if !signed_in { return 401; }
        sql_rows(db,"UPDATE push_subscriptions SET updated_at=? WHERE id=?",[sql_text(now),str(cell(row,0))]);
        return 200;
    }
    if !params.given[0] || params.nil[0] || !push_endpoint_valid(push_value(params,0)) { return 422; }
    if !signed_in { return 401; }
    let agent, has_agent = http::field_of(req,"User-Agent");
    sql_rows(db,str("INSERT INTO push_subscriptions(user_id,endpoint,p256dh_key,auth_key,user_agent,created_at,updated_at) VALUES(?,?,",
        if params.given[1] && !params.nil[1] { "?" } else { "NULL" },",",if params.given[2] && !params.nil[2] { "?" } else { "NULL" },",",if has_agent { "?" } else { "NULL" },",?,?)"),
        push_insert_args(user,params,if has_agent { agent } else { "" },has_agent,now));
    return 200;
}

fn push_insert_args(user: i64, params: const PushParams&, agent: const u8[:], has_agent: bool, now: const u8[:]) -> u8[][>..] {
    var args: u8[][>..] = [];
    args.push(sql_text(user)); args.push(str(push_value(params,0)));
    if params.given[1] && !params.nil[1] { args.push(str(push_value(params,1))); }
    if params.given[2] && !params.nil[2] { args.push(str(push_value(params,2))); }
    if has_agent { args.push(str(agent)); }
    args.push(sql_text(now)); args.push(sql_text(now));
    return args;
}

// --- Routing -------------------------------------------------------------------------------------

// Rack::MethodOverride: a POST's `_method` parameter from its form or multipart body (Rack doesn't
// parse JSON), else its X-HTTP-Method-Override header, when it names one of Rack's HTTP methods.
fn effective_method(req: const http::Request&, body: const u8[:]) -> u8[>..] {
    guard req.method == "POST" else { return str(req.method); }
    var override: u8[>..] = [];
    var found = false;
    if content_type_is(req,"multipart/form-data") {
        let value, fields, part = http::find_part(req,body,"_method");
        if part == http::PART_FOUND { override.append(value); found = true; }
    } else if !content_type_is(req,"application/json") {
        found = http::form_value(body,"_method",override);
    }
    if !found {
        let header, has_header = http::field_of(req,"X-HTTP-Method-Override");
        if has_header { override.append(header); }
    }
    let lower = html_lower(override);
    for name in ["get","head","put","post","delete","options","patch","link","unlink"] {
        if lower == name { return str(ascii_upper(name)); }
    }
    return str(req.method);
}

fn ascii_upper(text: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for c in text { out.push(if c >= 'a' && c <= 'z' { c - 32 } else { c }); }
    return out;
}

// Authenticated administration and push subscription routes; false for any other path.
fn admin_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], storage: const u8[:], key: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    var kind: i32 = 0; var id: i64 = 0;
    if starts_with(path,"/account") {
        if path == "/account/users" || path == "/account/users.turbo_stream" { kind = ADMIN_USERS; }
        else if starts_with(path,"/account/users/") { let n, valid = parse_int(path[15..]); if !valid { return false; } id = n; kind = ADMIN_USER; }
        else if path == "/account/join_code" { kind = ADMIN_JOIN_CODE; }
        else if path == "/account/logo" || path == "/account/logo.png" { kind = ADMIN_LOGO; }
        else { return false; }
    } else if starts_with(path,"/users/") {
        let rest = path[7..]; let slash = find(rest,"/");
        if slash <= 0 { return false; }
        let tail = rest[slash..];
        if tail == "/ban" { let n, valid = parse_int(rest[..slash]); if !valid { return false; } id = n; kind = ADMIN_BAN; }
        else if tail == "/push_subscriptions" { kind = ADMIN_PUSH_INDEX; }
        else if starts_with(tail,"/push_subscriptions/") {
            let more = tail[20..]; let stop = find(more,"/");
            let n, valid = parse_int(if stop < 0 { more } else { more[..stop] }); if !valid { return false; }
            id = n;
            if stop < 0 { kind = ADMIN_PUSH; } else if more[stop..] == "/test_notifications" { kind = ADMIN_PUSH_TEST; } else { return false; }
        } else { return false; }
    } else { return false; }
    let method = effective_method(req,body);
    let reading = method == "GET" || method == "HEAD";
    if !reading && !same_origin(req) { public_exception(out,req,422); return true; }
    var status: i32 = 404; var content: u8[>..] = []; var location: u8[>..] = []; var stream = false;
    var keys: u8[][>..] = []; var written: u8[>..] = []; var logo: i64 = 0;
    // A user deactivated or banned: once committed, their cable connections close for good. A banned user's
    // messages go after the commit, as remove_banned_content_later's job removes them.
    var revoked: i64 = 0; var banned: i64 = 0;
    if !reading { campfire_writer_enter(); }
    let failed = sqlite::run() {
        if !reading { sqlite::exec(db,"BEGIN IMMEDIATE"); }
        let admin = sql_number(db,"SELECT role FROM users WHERE id=? AND status=0",[sql_text(user)]) == 1;
        var now: u8[>..] = []; campfire_sql_now(now);
        if kind == ADMIN_USERS {
            if reading {
                if path == "/account/users.turbo_stream" || accepts_format(req,"text/vnd.turbo-stream.html") { account_users_stream(db,req,user,admin,key,content); status = 200; stream = true; }
                else { status = 406; }
            }
        } else if kind == ADMIN_USER {
            if method == "PATCH" || method == "PUT" || method == "DELETE" {
                if !admin { status = 403; }
                else if sql_number(db,"SELECT count(*) FROM users WHERE id=? AND status=0",[sql_text(id)]) == 0 { status = 404; }
                else if method == "DELETE" {
                    // User#deactivate
                    sql_rows(db,"DELETE FROM memberships WHERE user_id=? AND room_id IN (SELECT id FROM rooms WHERE type<>'Rooms::Direct')",[sql_text(id)]);
                    sql_rows(db,"DELETE FROM push_subscriptions WHERE user_id=?",[sql_text(id)]);
                    sql_rows(db,"DELETE FROM searches WHERE user_id=?",[sql_text(id)]);
                    sql_rows(db,"DELETE FROM sessions WHERE user_id=?",[sql_text(id)]);
                    sql_rows(db,"UPDATE users SET status=1,email_address=replace(email_address,'@',?),updated_at=? WHERE id=?",[sql_text(str("-deactivated-",random_uuid(),"@")),sql_text(now),sql_text(id)]);
                    status = 302; location = str("/account/edit"); revoked = id;
                } else if !form_has_prefix(body,"user[") { status = 400; }
                else {
                    var role: u8[>..] = [];
                    form_last(body,"user[role]",role);
                    sql_rows(db,"UPDATE users SET role=?,updated_at=? WHERE id=?",[sql_text(if role == "administrator" { "1" } else { "0" }),sql_text(now),sql_text(id)]);
                    status = 302; location = str("/account/edit");
                }
            }
        } else if kind == ADMIN_JOIN_CODE {
            if method == "POST" {
                if !admin { status = 403; }
                else { sql_rows(db,"UPDATE accounts SET join_code=?,updated_at=?",[sql_text(new_join_code()),sql_text(now)]); status = 302; location = str("/account/edit"); }
            }
        } else if kind == ADMIN_LOGO {
            if method == "DELETE" {
                if !admin { status = 403; }
                else {
                    let account = sql_number(db,"SELECT id FROM accounts ORDER BY id LIMIT 1",[]);
                    if sql_number(db,"SELECT count(*) FROM active_storage_attachments WHERE record_type='Account' AND name='logo' AND record_id=?",[sql_text(account)]) > 0 {
                        purge_attachments(db,"record_type='Account' AND name='logo' AND record_id=?",[sql_text(account)],keys);
                        sql_rows(db,"UPDATE accounts SET updated_at=? WHERE id=?",[sql_text(now),sql_text(account)]);
                    }
                    status = 302; location = str("/account/edit");
                }
            }
        } else if kind == ADMIN_BAN {
            if method == "POST" || method == "DELETE" {
                if !admin { status = 403; }
                else if sql_number(db,"SELECT count(*) FROM users WHERE id=?",[sql_text(id)]) == 0 { status = 404; }
                else if method == "DELETE" {
                    sql_rows(db,"DELETE FROM bans WHERE user_id=?",[sql_text(id)]);
                    sql_rows(db,"UPDATE users SET status=0,updated_at=? WHERE id=?",[sql_text(now),sql_text(id)]);
                    status = 302; location = str("/users/",id);
                } else {
                    let addresses = sql_rows(db,"SELECT DISTINCT ip_address FROM sessions WHERE user_id=? AND trim(coalesce(ip_address,''))<>''",[sql_text(id)]);
                    var valid = true; for row in addresses { if !public_address(cell(row,0)) { valid = false; } }
                    if !valid { status = 422; }
                    else {
                        for row in addresses { sql_rows(db,"INSERT INTO bans(user_id,ip_address,created_at,updated_at) VALUES(?,?,?,?)",[sql_text(id),str(cell(row,0)),sql_text(now),sql_text(now)]); }
                        sql_rows(db,"DELETE FROM sessions WHERE user_id=?",[sql_text(id)]);
                        sql_rows(db,"UPDATE users SET status=2,updated_at=? WHERE id=?",[sql_text(now),sql_text(id)]);
                        status = 302; location = str("/users/",id); revoked = id; banned = id;
                    }
                }
            }
        } else if kind == ADMIN_PUSH_INDEX {
            if method == "POST" { status = create_push_subscription(db,req,body,user,now); }
        } else if kind == ADMIN_PUSH {
            if method == "DELETE" {
                sql_rows(db,"DELETE FROM push_subscriptions WHERE id=? AND user_id=?",[sql_text(id),sql_text(user)]);
                status = 302; location = str("/users/me/push_subscriptions");
            }
        } else if kind == ADMIN_PUSH_TEST {
            // Rails delivers the test notification inline; here a delivery thread does (push.goose).
            if method == "POST" {
                if sql_number(db,"SELECT count(*) FROM push_subscriptions WHERE id=? AND user_id=?",[sql_text(id),sql_text(user)]) == 0 { status = 404; }
                else {
                    if !qput(DeliveryJob { kind: PUSH_TEST, a: id, text: site_base(req) }) { push_dropped(str("test notification for subscription ",id)); }
                    status = 302; location = str("/users/me/push_subscriptions");
                }
            }
        }
        if !reading { sqlite::exec(db,if status == 422 || status == 400 { "ROLLBACK" } else { "COMMIT" }); }
        // close_remote_connections, under writer admission so that the access log keeps commit order.
        if revoked > 0 && status == 302 { cable_revoke(revoked,false); }
    };
    if !reading { let cleanup = sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db,"ROLLBACK"); } }; campfire_writer_leave(); }
    if failed.len > 0 {
        status = 500; for e in failed { write_stderr(str(e.message,"\n")); }
        if written.len > 0 { delete_file(blob_path(storage,written)); }
    } else {
        if written.len > 0 && status != 302 { delete_file(blob_path(storage,written)); }
        if status == 302 { delete_blob_files(storage,keys); }
        // The logo's variants, made now rather than on its first request.
        if status == 302 && logo > 0 { process_later(MEDIA_LOGO,logo,0,logo_variation(false)); }
        if status == 302 && logo < 0 { process_later(MEDIA_ANALYZE,-logo,0,Variation { .. }); }
    }
    // `redirect_to *_url`: an absolute location.
    if status == 302 { redirect_found(out,str(site_base(req),location)); }
    else if status == 200 && stream { http::respond(out,200,"text/vnd.turbo-stream.html; charset=utf-8",content); }
    else if status == 200 { http::respond(out,200,"text/html; charset=utf-8",""); }
    // ensure_can_administer's head :forbidden; the rest are exceptions (no route, RecordNotFound,
    // UnknownFormat, ParameterMissing, RecordInvalid, a 500).
    else if status == 403 { respond_head(out,req,403); }
    // register_while_signed_in's head :unauthorized.
    else if status == 401 { respond_head(out,req,401,true); }
    else { public_exception(out,req,status); }
    if failed.len == 0 && status == 302 && banned > 0 { remove_banned_content_later(banned); }
    return true;
}
