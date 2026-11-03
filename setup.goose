namespace campfire;
import std;
import http;
import sqlite;
import hash;
import database;
import auth;
import sessions;
import messages;
import html;
import view_assets_generated;

fn random_token() -> u8[] {
    var bytes: u8[32] = [0;32]; hash::random_bytes(bytes);
    var out: u8[>..] = []; let digits="0123456789abcdef";
    for c in bytes { out.push(digits[c >> 4]); out.push(digits[c & 15]); }
    return out;
}

fn redirect(out: http::Reply, path: const u8[:]) {
    http::start(out,303); http::field(out,"Location",path); http::finish(out,http::TEXT,"Redirecting");
}

fn session_created(out: http::Reply, token: const u8[:], key: const u8[:], location: const u8[:]) {
    var expiry: u8[>..]=[]; campfire_expiry(expiry);
    http::start(out,303);
    http::field(out,"Set-Cookie",str("session_token=",sign_cookie(token,key,expiry),"; Path=/; HttpOnly; SameSite=Lax; Max-Age=630720000"));
    http::field(out,"Location",location); http::finish(out,http::TEXT,"Signed in");
}

fn simple_page(title: const u8[:], content: const u8[:]) -> u8[>..] {
    var out: u8[>..]=[];
    out.append("<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>");
    escape(out,title); out.append("</title>"); out.append(VIEW_STYLESHEET_TAGS); out.append(VIEW_IMPORTMAP_TAGS);
    out.append("</head><body><nav id=\"nav\"></nav><main id=\"main-content\"><section class=\"center max-width pad\">");
    out.append(content); out.append("</section></main></body></html>"); return out;
}
