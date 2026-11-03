namespace campfire;
import std;

// AllowBrowser: allow_browser versions: { safari: 17.2, chrome: 120, firefox: 121, opera: 104,
// ie: false } (app/controllers/concerns/allow_browser.rb), and the parts of the useragent gem
// (0.16.11) its BrowserBlocker reads: UserAgent.parse's products, the browser class that claims
// them (UserAgent::Browsers::ALL, in order), and its browser, version and bot?. As in the Rust
// port's user_agent.rs; a case where the gem raises is not blocked here (Rails answers 500).

// One product of the header, its parts cut to a bounded size.
struct UaProduct { name: u8[..128] = [], version: u8[..128] = [], comment: u8[..1024] = [], has_comment: bool = false }

fn ua_bounded(text: const u8[:], n: i64) -> const u8[:] { return text[..min(n, text.len)]; }

let UA_BASE: i32 = 0;
let UA_EDGE: i32 = 1;
let UA_IE: i32 = 2;
let UA_OPERA: i32 = 3;
let UA_WECHAT: i32 = 4;
let UA_VIVALDI: i32 = 5;
let UA_CHROME: i32 = 6;
let UA_ITUNES: i32 = 7;
let UA_PLAYSTATION: i32 = 8;
let UA_PODCAST_ADDICT: i32 = 9;
let UA_WEBKIT: i32 = 10;
let UA_GECKO: i32 = 11;
let UA_WMP: i32 = 12;
let UA_COREMEDIA: i32 = 13;
let UA_LAVF: i32 = 14;

fn ua_space(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == 11 || c == 12 || c == '\r'; }
fn ua_digit(c: u8) -> bool { return c >= '0' && c <= '9'; }
fn ua_alpha(c: u8) -> bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'; }

// String#downcase as far as matching ASCII names needs: A-Z, and U+212A KELVIN SIGN, which Ruby
// lowercases to "k".
fn ua_lower(text: const u8[:]) -> u8[>..] {
    var out: u8[>..] = []; var i: i64 = 0;
    while i < text.len {
        let c = text[i];
        if c == 0xe2 && i + 2 < text.len && text[i+1] == 0x84 && text[i+2] == 0xaa { out.push('k'); i += 3; continue; }
        out.push(if c >= 'A' && c <= 'Z' { c + 32 } else { c }); i += 1;
    }
    return out;
}
fn ua_same(a: const u8[:], b: const u8[:]) -> bool { return ua_lower(a) == ua_lower(b); }
fn ua_contains_ci(haystack: const u8[:], lower_needle: const u8[:]) -> bool { return find(ua_lower(haystack), lower_needle) >= 0; }

// String#strip: whitespace and NULs at either end.
fn ua_strip(text: const u8[:]) -> const u8[:] {
    var a: i64 = 0; var b = text.len;
    while a < b && (ua_space(text[a]) || text[a] == 0) { a += 1; }
    while b > a && (ua_space(text[b-1]) || text[b-1] == 0) { b -= 1; }
    return text[a..b];
}

// ActiveSupport's present? for a string.
fn ua_present(text: const u8[:]) -> bool {
    for c in text { if !ua_space(c) && c != 0xa0 { return true; } }
    return false;
}

// A comment's parts: String#split("; "), trailing empty parts dropped.
fn ua_items(comment: const u8[:]) -> u8[][>..] {
    // The parts' bounds, then the parts up to the last that isn't empty.
    var bounds: i64[>..] = [];
    var start: i64 = 0; var i: i64 = 0;
    while i + 1 < comment.len {
        if comment[i] == ';' && comment[i+1] == ' ' { bounds.push(start); bounds.push(i); i += 2; start = i; } else { i += 1; }
    }
    bounds.push(start); bounds.push(comment.len);
    var keep: i64 = 0;
    for k in bounds.len / 2 { if bounds[2*k+1] > bounds[2*k] { keep = k + 1; } }
    var items: u8[][>..] = [];
    for k in keep { items.push(str(comment[bounds[2*k]..bounds[2*k+1]])); }
    return items;
}

// The comment's part n, or "".
fn ua_item(comment: const u8[:], n: i64) -> u8[>..] {
    var k: i64 = 0;
    for item in ua_items(comment) { if k == n { return str(item); } k += 1; }
    return [];
}

// UserAgent::MATCHER at the start of s: ^['"]*([^/\s]+)/?([^\s,]*)(\s\(([^\)]*)\)|,gzip\(gfe\))?
// The match's length, or 0 for none, and the product.
fn ua_match(s: const u8[:]) -> i64, UaProduct {
    var quotes: i64 = 0; while quotes < s.len && (s[quotes] == '\'' || s[quotes] == '"') { quotes += 1; }
    var start: i64 = 0;
    if quotes < s.len && s[quotes] != '/' && !ua_space(s[quotes]) { start = quotes; }
    else if quotes > 0 { start = quotes - 1; }
    else { return 0, UaProduct { .. }; }
    var i = start + 1;
    while i < s.len && s[i] != '/' && !ua_space(s[i]) { i += 1; }
    let name = s[start..i];
    if i < s.len && s[i] == '/' { i += 1; }
    let version_start = i;
    while i < s.len && !ua_space(s[i]) && s[i] != ',' { i += 1; }
    let version = s[version_start..i];
    var comment: u8[>..] = []; var has_comment = false;
    if i + 1 < s.len && ua_space(s[i]) && s[i+1] == '(' {
        let close = find(s[i+2..], ")");
        if close >= 0 { comment.append(s[i+2..i+2+close]); has_comment = true; i += 2 + close + 1; }
    } else if starts_with(s[i..], ",gzip(gfe)") { i += 10; }
    var product = UaProduct { .. };
    product.name = ua_bounded(name, 128); product.version = ua_bounded(version, 128); product.comment = ua_bounded(comment, 1024); product.has_comment = has_comment;
    return i, product;
}

fn ua_parse(agent: const u8[:]) -> UaProduct[>..] {
    if ua_strip(agent).len == 0 { return ua_products("Mozilla/4.0 (compatible)"); }
    return ua_products(agent);
}

fn ua_products(agent: const u8[:]) -> UaProduct[>..] {
    var products: UaProduct[>..] = [];
    var rest = agent[..];
    loop {
        let length, product = ua_match(rest);
        if length == 0 || products.len >= 64 { break; }
        products.push(product);
        rest = ua_strip(rest[length..]);
    }
    return products;
}

fn ua_has(products: const UaProduct[:], name: const u8[:]) -> bool { for p in products { if p.name == name { return true; } } return false; }
fn ua_detect(products: const UaProduct[:], name: const u8[:]) -> i64 { for p, i in products { if ua_same(p.name, name) { return i; } } return -1; }

// WEBKIT_VERSION_REGEXP, /\A(?<webkit>AppleWebKit)\/(?<version>[\d\.]+)/i: the version, or "".
fn ua_webkit_comment_version(item: const u8[:]) -> u8[>..] {
    let lower = ua_lower(item);
    guard lower.len > 12 && starts_with(lower, "applewebkit/") else { return []; }
    var end: i64 = 12; while end < lower.len && (ua_digit(lower[end]) || lower[end] == '.') { end += 1; }
    return str(lower[12..end]);
}

// joined_comment =~ /Trident.+rv:/ on one line.
fn ua_trident_rv(s: const u8[:]) -> bool {
    var at = find(s, "Trident");
    while at >= 0 {
        let rest = s[at+7..]; let newline = find(rest, "\n");
        let line = if newline >= 0 { rest[..newline] } else { rest };
        if line.len > 1 && find(line[1..], "rv:") >= 0 { return true; }
        let next = find(s[at+1..], "Trident"); at = if next >= 0 { at + 1 + next } else { -1 };
    }
    return false;
}

fn ua_joined(p: const UaProduct&) -> const u8[:] { return p.comment; }

fn ua_kind(products: const UaProduct[:]) -> i32 {
    guard products.len > 0 else { return UA_BASE; }
    let first = products[0]; let last = products[products.len-1];
    if last.name == "Edge" { return UA_EDGE; }
    if first.has_comment {
        if ua_items(first.comment).len > 1 && find(ua_item(first.comment, 1), "MSIE") >= 0 || ua_trident_rv(first.comment) { return UA_IE; }
    }
    if first.name == "Opera" || last.name == "OPR" { return UA_OPERA; }
    for p in products { if ua_contains_ci(p.name, "micromessenger") { return UA_WECHAT; } }
    if ua_has(products, "Vivaldi") { return UA_VIVALDI; }
    if ua_has(products, "Chrome") || ua_has(products, "CriOS") { return UA_CHROME; }
    if ua_has(products, "iTunes") { return UA_ITUNES; }
    if first.has_comment {
        let item = ua_item(first.comment, 0);
        if find(item, "PLAYSTATION 3") >= 0 || find(item, "PlayStation Vita") >= 0 || find(item, "PlayStation 4") >= 0 { return UA_PLAYSTATION; }
    }
    if products.len >= 3 && products[0].name == "Podcast" && products[1].name == "Addict" && products[2].name == "-" { return UA_PODCAST_ADDICT; }
    for p in products {
        if ua_same(p.name, "applewebkit") { return UA_WEBKIT; }
        if p.has_comment { for item in ua_items(p.comment) { if ua_webkit_comment_version(item).len > 0 { return UA_WEBKIT; } } }
    }
    if first.name == "Mozilla" { return UA_GECKO; }
    let fv = first.version;
    let odd_player = fv == "4.1.0.3856" || fv == "7.10.0.3059" || fv == "7.0.0.1956";
    for p in products { if (p.name == "NSPlayer" || p.name == "Windows-Media-Player" || p.name == "WMFSDK") && !odd_player { return UA_WMP; } }
    if ua_has(products, "AppleCoreMedia") { return UA_COREMEDIA; }
    for p in products { if p.name == "Lavf" || p.name == "NSPlayer" && fv == "4.1.0.3856" { return UA_LAVF; } }
    return UA_BASE;
}

// application: the first product, or for the WebKit-based classes the first with a comment.
fn ua_application(products: const UaProduct[:], kind: i32) -> i64 {
    if kind == UA_CHROME || kind == UA_VIVALDI || kind == UA_WEBKIT || kind == UA_ITUNES || kind == UA_COREMEDIA {
        for p, i in products { if p.has_comment && ua_items(p.comment).len > 0 { return i; } }
        return -1;
    }
    return if products.len > 0 { 0 } else { -1 };
}

// IOS_VERSION_REGEX, /CPU (?:iPhone |iPod )?OS ([\d_]+) like Mac OS X/: the version, or "".
fn ua_ios_version(os: const u8[:]) -> u8[>..] {
    var at = find(os, "CPU ");
    while at >= 0 {
        let rest = os[at+4..];
        let prefixes: const u8[:][3] = ["iPhone ", "iPod ", ""];
        for prefix in prefixes {
            if starts_with(rest, prefix) && starts_with(rest[prefix.len..], "OS ") {
                let tail = rest[prefix.len+3..]; var n: i64 = 0;
                while n < tail.len && (ua_digit(tail[n]) || tail[n] == '_') { n += 1; }
                if n > 0 && starts_with(tail[n..], " like Mac OS X") { return str(tail[..n]); }
            }
        }
        let next = find(os[at+1..], "CPU "); at = if next >= 0 { at + 1 + next } else { -1 };
    }
    return [];
}

// OperatingSystems.normalize_os, as far as the checks here read it.
fn ua_normalize_os(os: const u8[:]) -> u8[>..] {
    let ios = ua_ios_version(os);
    if ios.len > 0 { var v: u8[>..] = []; for c in ios { v.push(if c == '_' { '.' as u8 } else { c }); } return str("iOS ", v); }
    return str(os);
}

// Webkit#os, or "" for nil.
fn ua_webkit_os(products: const UaProduct[:]) -> u8[>..] {
    let app = ua_application(products, UA_WEBKIT); guard app >= 0 else { return []; }
    let comment = products[app].comment;
    let count = ua_items(comment).len;
    let first = ua_item(comment, 0); let second = ua_item(comment, 1);
    if count > 0 && find(first, "Windows NT") >= 0 { return ua_normalize_os(first); }
    if count < 3 || count > 1 && find(second, "Android") >= 0 { return if count > 1 { ua_normalize_os(second) } else { [] }; }
    for item in ua_items(comment) { if ua_ios_version(item).len > 0 { return ua_normalize_os(item); } }
    return ua_normalize_os(ua_item(comment, 2));
}

fn ua_webkit_browser(products: const UaProduct[:]) -> u8[>..] {
    if find(ua_webkit_os(products), "Android") >= 0 { return str("Android"); }
    let app = ua_application(products, UA_WEBKIT);
    // Webkit#platform == "BlackBerry": BB10, or a first part BlackBerry that no later Android or
    // Windows reading displaces.
    if app >= 0 {
        let comment = products[app].comment;
        let first = ua_item(comment, 0);
        var android = false; for item in ua_items(comment) { if find(item, "Android") >= 0 { android = true; } }
        if find(first, "Windows") < 0 && (first == "BB10" || first == "BlackBerry" && !android) { return str("BlackBerry"); }
    }
    return str("Safari");
}

fn ua_gecko_browser(products: const UaProduct[:]) -> u8[>..] {
    let names: const u8[:][5] = ["PaleMoon", "Firefox", "Camino", "Iceweasel", "Seamonkey"];
    for name in names { if ua_detect(products, name) >= 0 { return str(name); } }
    return if products.len > 0 { str(products[0].name) } else { [] };
}

fn ua_browser(products: const UaProduct[:], kind: i32) -> u8[>..] {
    if kind == UA_BASE { let app = ua_application(products, kind); return if app >= 0 { str(products[app].name) } else { [] }; }
    if kind == UA_EDGE { return str("Edge"); }
    if kind == UA_IE { return str("Internet Explorer"); }
    if kind == UA_OPERA { return str("Opera"); }
    if kind == UA_WECHAT { return str("Wechat Browser"); }
    if kind == UA_VIVALDI { return str("Vivaldi"); }
    if kind == UA_CHROME { return if ua_detect(products, "Iron") >= 0 { str("Iron") } else { str("Chrome") }; }
    if kind == UA_WEBKIT { return ua_webkit_browser(products); }
    if kind == UA_GECKO { return ua_gecko_browser(products); }
    return str("other");
}

// /MSIE\s|rv:/ followed by [\d\.]+: the version, or "".
fn ua_ie_version(s: const u8[:]) -> u8[>..] {
    for i in s.len {
        var start: i64 = -1;
        if starts_with(s[i..], "MSIE") && i + 4 < s.len && ua_space(s[i+4]) { start = i + 5; }
        else if starts_with(s[i..], "rv:") { start = i + 3; }
        if start >= 0 {
            var n = start; while n < s.len && (ua_digit(s[n]) || s[n] == '.') { n += 1; }
            if n > start { return str(s[start..n]); }
        }
    }
    return [];
}

fn ua_webkit_build_version(build: const u8[:]) -> u8[>..] {
    let table: const u8[:][30] = ["85.7=1.0", "85.8.5=1.0.3", "85.8.2=1.0.3", "124=1.2", "125.2=1.2.2", "125.4=1.2.3", "125.5.5=1.2.4", "125.5.6=1.2.4",
                 "125.5.7=1.2.4", "312.1.1=1.3", "312.1=1.3", "312.5=1.3.1", "312.5.1=1.3.1", "312.5.2=1.3.1", "312.8=1.3.2", "312.8.1=1.3.2",
                 "412=2.0", "412.6=2.0", "412.6.2=2.0", "412.7=2.0.1", "416.11=2.0.2", "416.12=2.0.2", "417.9=2.0.3", "418=2.0.3",
                 "418.8=2.0.4", "418.9=2.0.4", "418.9.1=2.0.4", "419=2.0.4", "425.13=2.2", "534.52.7=5.1.2"];
    for entry in table { let eq = find(entry, "="); if entry[..eq] == build { return str(entry[eq+1..]); } }
    return [];
}

// The browser's version, and false where the gem would raise.
fn ua_version(products: const UaProduct[:], kind: i32) -> u8[>..], bool {
    let app = ua_application(products, kind);
    let base: u8[>..] = if app >= 0 { str(products[app].version) } else { [] };
    if kind == UA_IE { return ua_ie_version(if app >= 0 { products[app].comment[..] } else { "" }), true; }
    if kind == UA_OPERA {
        if products.len > 0 && find(products[0].comment, "Opera Mini") >= 0 {
            for item in ua_items(products[0].comment) {
                if find(item, "Opera Mini") >= 0 {
                    let at = find(item, "Opera Mini/"); if at < 0 { return [], true; }
                    let tail = item[at+11..]; var n: i64 = 0; while n < tail.len && (ua_digit(tail[n]) || tail[n] == '.') { n += 1; }
                    return str(tail[..n]), true;
                }
            }
            return [], true;
        }
        let v = ua_detect(products, "Version"); if v >= 0 { return str(products[v].version), true; }
        let o = ua_detect(products, "OPR"); if o >= 0 { return str(products[o].version), true; }
        return base, true;
    }
    if kind == UA_CHROME {
        var p = ua_detect(products, "CriOs"); if p < 0 { p = ua_detect(products, "chrome"); }
        if p < 0 { return [], false; }
        return str(products[p].version), true;
    }
    if kind == UA_WEBKIT {
        let v = ua_detect(products, "Version"); if v >= 0 { return str(products[v].version), true; }
        let os = ua_webkit_os(products); let at = find(os, "iOS ");
        if at >= 0 && ua_webkit_browser(products) == "Safari" {
            let tail = os[at+4..]; var n: i64 = 0; while n < tail.len && (ua_digit(tail[n]) || tail[n] == '.') { n += 1; }
            if n > 0 { return str(tail[..n]), true; }
        }
        var build: u8[>..] = [];
        let w = ua_detect(products, "applewebkit");
        if w >= 0 { build = str(products[w].version); }
        else { for p in products { if p.has_comment && build.len == 0 { for item in ua_items(p.comment) { if build.len == 0 { build = ua_webkit_comment_version(item); } } } } }
        return ua_webkit_build_version(build), true;
    }
    if kind == UA_GECKO {
        let g = ua_detect(products, ua_gecko_browser(products)); if g < 0 { return [], false; }
        if ua_strip(products[g].version).len == 0 { return base, true; }
        return str(products[g].version), true;
    }
    return base, true;
}

fn ua_bot(products: const UaProduct[:], kind: i32) -> bool {
    let app = ua_application(products, kind);
    guard app >= 0 else { return true; }
    for p in products { if p.has_comment { for item in ua_items(p.comment) { if ua_contains_ci(item, "bot") { return true; } } } }
    if ua_detect(products, "Chrome-Lighthouse") >= 0 { return true; }
    return find(products[app].name, "bot") >= 0;
}

// UserAgent::Version: a version that starts with digits, then the end or a dot, compares by its
// segments; any other is only equal to itself, and below everything else.
fn ua_version_comparable(v: const u8[:]) -> bool {
    var n: i64 = 0; while n < v.len && ua_digit(v[n]) { n += 1; }
    return ua_present(v) && n > 0 && (n == v.len || v[n] == '.');
}

// str.scan(/\d+|[A-Za-z][0-9A-Za-z-]*$/)[n]: a number without leading zeros and marked with a
// leading '#', or "#0" past the end.
fn ua_segment(v: const u8[:], n: i64) -> u8[>..] {
    var k: i64 = 0;
    for segment in ua_segments(v) { if k == n { return str(segment); } k += 1; }
    return str("#0");
}

fn ua_segments(v: const u8[:]) -> u8[][>..] {
    var out: u8[][>..] = []; var i: i64 = 0;
    while i < v.len {
        if ua_digit(v[i]) {
            let start = i; while i < v.len && ua_digit(v[i]) { i += 1; }
            var digits = v[start..i]; while digits.len > 1 && digits[0] == '0' { digits = digits[1..]; }
            out.push(str("#", digits));
        } else if ua_alpha(v[i]) {
            var end = i + 1; while end < v.len && (ua_alpha(v[end]) || ua_digit(v[end]) || v[end] == '-') { end += 1; }
            if end == v.len { out.push(str(v[i..])); i = end; } else { i += 1; }
        } else { i += 1; }
    }
    return out;
}

// version < minimum, by UserAgent::Version#<=>.
fn ua_version_below(version: const u8[:], minimum: const u8[:]) -> bool {
    guard ua_version_comparable(version) else { return version != minimum; }
    for i in 6 {
        let a = ua_segment(version, i);
        let b = ua_segment(minimum, i);
        if a == b { continue; }
        let a_int = a[0] == '#'; let b_int = b[0] == '#';
        if !a_int && b_int { return true; }
        if a_int && !b_int { return false; }
        if a_int { return if a.len != b.len { a.len < b.len } else { compare(a, b) < 0 }; }
        return compare(a, b) < 0;
    }
    return false;
}

// ActionController::AllowBrowser::BrowserBlocker#blocked? for a User-Agent.
fn browser_blocked(agent: const u8[:]) -> bool {
    guard ua_present(agent) else { return false; }
    let products = ua_parse(agent);
    let kind = ua_kind(products);
    let version, ok = ua_version(products, kind);
    guard ok && ua_present(version) else { return false; }
    let browser = ua_lower(ua_browser(products, kind));
    var minimum: u8[>..] = [];
    if browser == "safari" { minimum = str("17.2"); }
    else if browser == "chrome" { minimum = str("120"); }
    else if browser == "firefox" { minimum = str("121"); }
    else if browser == "opera" { minimum = str("104"); }
    else if browser != "internet explorer" { return false; }
    let below = minimum.len == 0 || ua_version_below(version, minimum);
    return below && !ua_bot(products, kind);
}

// ApplicationPlatform#apple_messages?: Messages poses as Facebook's and Twitter's crawlers.
fn apple_messages(agent: const u8[:]) -> bool {
    return ua_contains_ci(agent, "facebookexternalhit") && ua_contains_ci(agent, "twitterbot");
}
