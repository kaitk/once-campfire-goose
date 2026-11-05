namespace campfire;

import std;
import base64;
import json;
import hash;
import auth;

fn signed_id_key(secret: const u8[:]) -> u8[64] {
    var out: u8[64] = [0; 64];
    hash::pbkdf2_sha256(out, secret, "active_record/signed_id", 1000);
    return out;
}

fn base64_url(out: u8[>..]&, data: const u8[:]) {
    var encoded: u8[>..] = [];
    base64::encode(encoded, data);
    for c in encoded {
        if c != '=' { out.push(if c == '+' { '-' } else if c == '/' { '_' } else { c }); }
    }
}

fn base64_url_decode(out: u8[>..]&, data: const u8[:]) -> bool {
    var encoded: u8[>..] = [];
    for c in data { encoded.push(if c == '-' { '+' } else if c == '_' { '/' } else { c }); }
    if encoded.len % 4 == 1 { return false; }
    while encoded.len % 4 != 0 { encoded.push('='); }
    return base64::decode(out, encoded);
}

fn sign_id(id: i64, purpose: const u8[:], key: const u8[:], expiry: const u8[:] = "") -> u8[>..] {
    var envelope: u8[>..] = [];
    format(envelope, "{\"_rails\":{\"data\":", id, ",\"pur\":");
    json::format_string(envelope, purpose);
    if expiry.len > 0 { envelope.append(",\"exp\":"); json::format_string(envelope,expiry); }
    envelope.append("}}");
    var out: u8[>..] = [];
    base64_url(out, envelope);
    let mac = hash::hmac_sha256(key, out);
    out.append("--");
    let digits = "0123456789abcdef";
    for c in mac { out.push(digits[c >> 4]); out.push(digits[c & 15]); }
    return out;
}

fn signed_integer(node: json::Node?) -> i64 {
    let number, integer = json::as_i64(node);
    if integer { return number; }
    let text, string = json::as_string(node);
    if string {
        let value, valid = parse_int(text);
        if valid { return value; }
    }
    return 0;
}

fn verify_id(raw: const u8[:], purpose: const u8[:], key: const u8[:], now: const u8[:]) -> i64 {
    var expires = false;
    return verify_expiring_id(raw, purpose, key, now, expires);
}

// verify_id, and whether the token has an expiry, so that its answer depends on the time.
fn verify_expiring_id(raw: const u8[:], purpose: const u8[:], key: const u8[:], now: const u8[:], expires: bool&) -> i64 {
    expires = false;
    guard raw.len <= 8192 else { return 0; }
    // The URL-safe payload itself may contain "--"; the digest has a fixed suffix.
    var split: i64 = -1;
    var digest_bytes: i64 = 0;
    if raw.len > 66 && raw[raw.len - 66..raw.len - 64] == "--" {
        split = raw.len - 66; digest_bytes = 32;
    } else if raw.len > 42 && raw[raw.len - 42..raw.len - 40] == "--" {
        split = raw.len - 42; digest_bytes = 20;
    }
    guard split > 0 else { return 0; }
    var supplied: u8[32] = [0; 32];
    for i in digest_bytes {
        let hi = hex_digit(raw[split + 2 + i * 2]);
        let lo = hex_digit(raw[split + 3 + i * 2]);
        guard hi >= 0 && lo >= 0 else { return 0; }
        supplied[i] = (hi * 16 + lo) as u8;
    }
    let payload = raw[..split];
    if digest_bytes == 32 {
        guard hash::equal(supplied, hash::hmac_sha256(key, payload)) else { return 0; }
    } else {
        guard hash::equal(supplied[..20], hmac_sha1(key, payload)) else { return 0; }
    }
    var decoded: u8[>..] = [];
    guard base64_url_decode(decoded, payload) else { return 0; }
    var nodes: json::Node[>..] = [];
    var strings: u8[>..] = [];
    let root, error = json::parse(decoded, nodes, strings);
    let envelope = json::member(root, "_rails");
    guard envelope else { return 0; }
    let actual, has_purpose = json::as_string(json::member(envelope, "pur"));
    guard has_purpose && actual == purpose else { return 0; }
    let expiry = json::member(envelope, "exp");
    if expiry {
        match expiry.val {
            Null => {},
            Str value => {
                expires = true;
                guard value.s.len == 24 && value.s[23] == 'Z' && now.len == 24 && compare(value.s, now) > 0 else { return 0; }
            },
            _ => { return 0; },
        }
    }
    let data = json::member(envelope, "data");
    if data { return signed_integer(data); }
    let message, has_message = json::as_string(json::member(envelope, "message"));
    guard has_message else { return 0; }
    var text: u8[>..] = [];
    guard base64_url_decode(text, message) else { return 0; }
    var value_nodes: json::Node[>..] = [];
    var value_strings: u8[>..] = [];
    let value, parse_error = json::parse(text, value_nodes, value_strings);
    return signed_integer(value);
}

// The decoded payload of raw, a Rails MessageVerifier token, once its HMAC-SHA256 or HMAC-SHA1
// digest checks out against key.
fn verified_payload(raw: const u8[:], key: const u8[:], decoded: u8[>..]&) -> bool {
    guard raw.len <= 8192 else { return false; }
    var split: i64 = -1;
    var digest_bytes: i64 = 0;
    if raw.len > 66 && raw[raw.len - 66..raw.len - 64] == "--" {
        split = raw.len - 66; digest_bytes = 32;
    } else if raw.len > 42 && raw[raw.len - 42..raw.len - 40] == "--" {
        split = raw.len - 42; digest_bytes = 20;
    }
    guard split > 0 else { return false; }
    var supplied: u8[32] = [0; 32];
    for i in digest_bytes {
        let hi = hex_digit(raw[split + 2 + i * 2]);
        let lo = hex_digit(raw[split + 3 + i * 2]);
        guard hi >= 0 && lo >= 0 else { return false; }
        supplied[i] = (hi * 16 + lo) as u8;
    }
    let payload = raw[..split];
    if digest_bytes == 32 {
        guard hash::equal(supplied, hash::hmac_sha256(key, payload)) else { return false; }
    } else {
        guard hash::equal(supplied[..20], hmac_sha1(key, payload)) else { return false; }
    }
    return base64_url_decode(decoded, payload);
}

// SignedGlobalID's key: Rails.application.message_verifier(:signed_global_ids).
fn sgid_key(secret: const u8[:]) -> u8[64] {
    var out: u8[64] = [0; 64];
    hash::pbkdf2_sha256(out, secret, "signed_global_ids", 1000);
    return out;
}

// user.attachable_sgid, to_sgid(expires_in: nil, for: "attachable"): it signs
// gid://campfire/User/<id>?expires_in with HMAC-SHA1, in padded URL-safe Base64.
fn attachable_sgid(id: i64, key: const u8[:]) -> u8[>..] {
    var encoded: u8[>..] = [];
    base64::encode(encoded, str("{\"_rails\":{\"data\":\"gid://campfire/User/", id, "?expires_in\",\"pur\":\"attachable\"}}"));
    var out: u8[>..] = [];
    for c in encoded { out.push(if c == '+' { '-' } else if c == '/' { '_' } else { c }); }
    let mac = hmac_sha1(key, out);
    out.append("--");
    let digits = "0123456789abcdef";
    for c in mac { out.push(digits[c >> 4]); out.push(digits[c & 15]); }
    return out;
}

// The user an attachable SGID signs, as GlobalID::Locator.locate_signed(sgid, for: "attachable")
// finds it, or 0. Attachable SGIDs never expire, so one that carries an expiry is refused.
fn verify_sgid(raw: const u8[:], key: const u8[:]) -> i64 {
    var decoded: u8[>..] = [];
    guard verified_payload(raw, key, decoded) else { return 0; }
    var nodes: json::Node[>..] = [];
    var strings: u8[>..] = [];
    let root, error = json::parse(decoded, nodes, strings);
    let envelope = json::member(root, "_rails");
    guard envelope else { return 0; }
    let purpose, has_purpose = json::as_string(json::member(envelope, "pur"));
    guard has_purpose && purpose == "attachable" else { return 0; }
    let expiry = json::member(envelope, "exp");
    if expiry {
        match expiry.val {
            Null => {},
            _ => { return 0; },
        }
    }
    var gid: u8[>..] = [];
    let data, has_data = json::as_string(json::member(envelope, "data"));
    if has_data { gid.append(data); } else {
        // Rails 7.0's envelope: the Base64 of the serialized string.
        let message, has_message = json::as_string(json::member(envelope, "message"));
        guard has_message && base64_url_decode(gid, message) else { return 0; }
    }
    let prefix = "gid://campfire/User/";
    let at = find(gid, prefix);
    guard at >= 0 && at <= 8 else { return 0; }
    let start = at + prefix.len;
    var end = start;
    while end < gid.len && gid[end] >= '0' && gid[end] <= '9' { end += 1; }
    guard end > start && (end == gid.len || gid[end] == '?' || gid[end] == '"') else { return 0; }
    let id, valid = parse_int(gid[start..end]);
    return if valid { id } else { 0 };
}

// --- generates_token_for -------------------------------------------------------------------------

// Rails.application.message_verifier("active_record/token_for"), which generates_token_for signs with.
fn token_for_key(secret: const u8[:]) -> u8[64] {
    var out: u8[64] = [0; 64];
    hash::pbkdf2_sha256(out, secret, "active_record/token_for", 1000);
    return out;
}

struct TokenForConfig { key: u8[64] = [0; 64] }
var token_for_config = TokenForConfig { .. };

// User::Transferable: generates_token_for :transfer, expires_in: 4.hours, whose purpose is the class,
// the name and the expiry in seconds.
let TRANSFER_TOKEN_PURPOSE = "User\ntransfer\n14400";

// password_salt&.last(10) of a bcrypt digest ("$2a$12$" and the 22-character salt, then the hash);
// false (nil) without one.
fn transfer_salt(digest: const u8[:]) -> const u8[:], bool {
    guard digest.len >= 29 && digest[0] == '$' else { return "", false; }
    return digest[19..29], true;
}

// generate_token_for(:transfer): [id, salt] with the expiry and purpose, URL-safe Base64, HMAC-SHA1.
fn sign_transfer_token(user: i64, digest: const u8[:], key: const u8[:], expiry: const u8[:]) -> u8[>..] {
    let salt, salted = transfer_salt(digest);
    var envelope: u8[>..] = [];
    format(envelope, "{\"_rails\":{\"data\":[", user, ",");
    if salted { json::format_string(envelope, salt); } else { envelope.append("null"); }
    envelope.append("],\"exp\":"); json::format_string(envelope, expiry);
    envelope.append(",\"pur\":"); json::format_string(envelope, TRANSFER_TOKEN_PURPOSE);
    envelope.append("}}");
    var out: u8[>..] = [];
    base64_url(out, envelope);
    let mac = hmac_sha1(key, out);
    out.append("--");
    let digits = "0123456789abcdef";
    for c in mac { out.push(digits[c >> 4]); out.push(digits[c & 15]); }
    return out;
}

// find_by_token_for(:transfer, raw)'s first half: the user a token names once its digest, purpose and
// expiry check out, with the salt it was bound to (salted false for nil); 0 for any other token. The
// caller compares the salt with the user's current one, as Rails compares the payload with the record's.
fn verify_transfer_token(raw: const u8[:], key: const u8[:], now: const u8[:], salt: u8[>..]&, salted: bool&) -> i64 {
    var decoded: u8[>..] = [];
    guard verified_payload(raw, key, decoded) else { return 0; }
    var nodes: json::Node[>..] = [];
    var strings: u8[>..] = [];
    let root, error = json::parse(decoded, nodes, strings);
    let envelope = json::member(root, "_rails");
    guard envelope else { return 0; }
    let purpose, has_purpose = json::as_string(json::member(envelope, "pur"));
    guard has_purpose && purpose == TRANSFER_TOKEN_PURPOSE else { return 0; }
    let expiry = json::member(envelope, "exp");
    if expiry {
        match expiry.val {
            Null => {},
            Str value => {
                guard value.s.len == 24 && value.s[23] == 'Z' && now.len == 24 && compare(value.s, now) > 0 else { return 0; }
            },
            _ => { return 0; },
        }
    }
    let data = json::member(envelope, "data");
    guard data else { return 0; }
    match data.val {
        Arr => {},
        _ => { return 0; },
    }
    var id: i64 = 0; var count: i64 = 0; var valid = true;
    var c = data.first;
    while c {
        if count == 0 {
            let n, integer = json::as_i64(c);
            if integer && n > 0 { id = n; } else { valid = false; }
        } else if count == 1 {
            let text, string = json::as_string(c);
            if string { salt.append(text); salted = true; }
            else {
                match c.val {
                    Null => { salted = false; },
                    _ => { valid = false; },
                }
            }
        }
        count += 1;
        c .= c.next;
    }
    return if valid && count == 2 { id } else { 0 };
}
