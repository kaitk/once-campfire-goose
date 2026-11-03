namespace campfire;

// SearchesController, RoomsController#index and #show (with TrackedRoomVisit and the permalinks
// /rooms/:id/@:message_id), WelcomeController, MessagesController#index (message paging) and
// MessagesController#create's room_not_found, with the flash they set and show.

import std;
import http;
import http.compression;
import sqlite;
import json;
import base64;
import hash;
import database;
import html;
import auth;
import cache;
import admin_routes;
import browser_routes;
import route_support;
import view_types;
import view_data;
import view_helpers;
import views_generated;
import sessions;
import active_storage;
import auth_routes;

struct PageKeys {
    cookie: const u8[:] = "",
    avatar: const u8[:] = "",
    stream: const u8[:] = "",
    vapid: const u8[:] = "",
    storage: const u8[:] = "",
}

// --- Query sanitizing ----------------------------------------------------------------------------

// Ruby's /[[:word:]]/ outside ASCII (Letter, Mark, Decimal_Number, Connector_Punctuation), as the
// Rails image's Ruby 3.4 (Unicode 15.0) matches it: the ranges come from
//   (128..0x10FFFF).select { |c| [c].pack("U") =~ /[[:word:]]/ }
// run in that image.
fn query_word(c: u32) -> bool {
    if c < 128 { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'; }
    let starts = [170,181,186,192,216,248,710,736,748,750,768,886,890,895,902,904,908,910,931,1015,1155,1329,1369,1376,1425,1471,1473,1476,1479,1488,1519,1552,1568,1646,1749,1759,1770,1791,1808,1869,1984,2042,2045,2048,2112,2144,2160,2185,2200,2275,2406,2417,2437,2447,2451,2474,2482,2486,2492,2503,2507,2519,2524,2527,2534,2556,2558,2561,2565,2575,2579,2602,2610,2613,2616,2620,2622,2631,2635,2641,2649,2654,2662,2689,2693,2703,2707,2730,2738,2741,2748,2759,2763,2768,2784,2790,2809,2817,2821,2831,2835,2858,2866,2869,2876,2887,2891,2901,2908,2911,2918,2929,2946,2949,2958,2962,2969,2972,2974,2979,2984,2990,3006,3014,3018,3024,3031,3046,3072,3086,3090,3114,3132,3142,3146,3157,3160,3165,3168,3174,3200,3205,3214,3218,3242,3253,3260,3270,3274,3285,3293,3296,3302,3313,3328,3342,3346,3398,3402,3412,3423,3430,3450,3457,3461,3482,3507,3517,3520,3530,3535,3542,3544,3558,3570,3585,3648,3664,3713,3716,3718,3724,3749,3751,3776,3782,3784,3792,3804,3840,3864,3872,3893,3895,3897,3902,3913,3953,3974,3993,4038,4096,4176,4256,4295,4301,4304,4348,4682,4688,4696,4698,4704,4746,4752,4786,4792,4800,4802,4808,4824,4882,4888,4957,4992,5024,5112,5121,5743,5761,5792,5870,5888,5919,5952,5984,5998,6002,6016,6103,6108,6112,6155,6159,6176,6272,6320,6400,6432,6448,6470,6512,6528,6576,6608,6656,6688,6752,6783,6800,6823,6832,6912,6992,7019,7040,7168,7232,7245,7296,7312,7357,7376,7380,7424,7960,7968,8008,8016,8025,8027,8029,8031,8064,8118,8126,8130,8134,8144,8150,8160,8178,8182,8204,8255,8276,8305,8319,8336,8400,8450,8455,8458,8469,8473,8484,8486,8488,8490,8495,8508,8517,8526,8544,9398,11264,11499,11520,11559,11565,11568,11631,11647,11680,11688,11696,11704,11712,11720,11728,11736,11744,11823,12293,12321,12337,12344,12353,12441,12445,12449,12540,12549,12593,12704,12784,13312,19968,42192,42240,42512,42560,42612,42623,42775,42786,42891,42960,42963,42965,42994,43052,43072,43136,43216,43232,43259,43261,43312,43360,43392,43471,43488,43520,43584,43600,43616,43642,43739,43744,43762,43777,43785,43793,43808,43816,43824,43868,43888,44012,44016,44032,55216,55243,63744,64112,64256,64275,64285,64298,64312,64318,64320,64323,64326,64467,64848,64914,65008,65024,65056,65075,65101,65136,65142,65296,65313,65343,65345,65382,65474,65482,65490,65498,65536,65549,65576,65596,65599,65616,65664,65856,66045,66176,66208,66272,66304,66349,66384,66432,66464,66504,66513,66560,66720,66736,66776,66816,66864,66928,66940,66956,66964,66967,66979,66995,67003,67072,67392,67424,67456,67463,67506,67584,67592,67594,67639,67644,67647,67680,67712,67808,67828,67840,67872,67968,68030,68096,68101,68108,68117,68121,68152,68159,68192,68224,68288,68297,68352,68416,68448,68480,68608,68736,68800,68864,68912,69248,69291,69296,69373,69415,69424,69488,69552,69600,69632,69734,69759,69826,69840,69872,69888,69942,69956,69968,70006,70016,70089,70094,70108,70144,70163,70206,70272,70280,70282,70287,70303,70320,70384,70400,70405,70415,70419,70442,70450,70453,70459,70471,70475,70480,70487,70493,70502,70512,70656,70736,70750,70784,70855,70864,71040,71096,71128,71168,71236,71248,71296,71360,71424,71453,71472,71488,71680,71840,71935,71945,71948,71957,71960,71991,71995,72016,72096,72106,72154,72163,72192,72263,72272,72349,72368,72704,72714,72760,72784,72818,72850,72873,72960,72968,72971,73018,73020,73023,73040,73056,73063,73066,73104,73107,73120,73440,73472,73490,73534,73552,73648,73728,74752,74880,77712,77824,78912,82944,92160,92736,92768,92784,92864,92880,92912,92928,92992,93008,93027,93053,93760,93952,94031,94095,94176,94179,94192,94208,100352,101632,110576,110581,110589,110592,110898,110928,110933,110948,110960,113664,113776,113792,113808,113821,118528,118576,119141,119149,119163,119173,119210,119362,119808,119894,119966,119970,119973,119977,119982,119995,119997,120005,120071,120077,120086,120094,120123,120128,120134,120138,120146,120488,120514,120540,120572,120598,120630,120656,120688,120714,120746,120772,120782,121344,121403,121461,121476,121499,121505,122624,122661,122880,122888,122907,122915,122918,122928,123023,123136,123184,123200,123214,123536,123584,124112,124896,124904,124909,124912,124928,125136,125184,125264,126464,126469,126497,126500,126503,126505,126516,126521,126523,126530,126535,126537,126539,126541,126545,126548,126551,126553,126555,126557,126559,126561,126564,126567,126572,126580,126585,126590,126592,126603,126625,126629,126635,127280,127312,127344,130032,131072,173824,177984,178208,183984,194560,196608,201552,917760];
    let ends = [170,181,186,214,246,705,721,740,748,750,884,887,893,895,902,906,908,929,1013,1153,1327,1366,1369,1416,1469,1471,1474,1477,1479,1514,1522,1562,1641,1747,1756,1768,1788,1791,1866,1969,2037,2042,2045,2093,2139,2154,2183,2190,2273,2403,2415,2435,2444,2448,2472,2480,2482,2489,2500,2504,2510,2519,2525,2531,2545,2556,2558,2563,2570,2576,2600,2608,2611,2614,2617,2620,2626,2632,2637,2641,2652,2654,2677,2691,2701,2705,2728,2736,2739,2745,2757,2761,2765,2768,2787,2799,2815,2819,2828,2832,2856,2864,2867,2873,2884,2888,2893,2903,2909,2915,2927,2929,2947,2954,2960,2965,2970,2972,2975,2980,2986,3001,3010,3016,3021,3024,3031,3055,3084,3088,3112,3129,3140,3144,3149,3158,3162,3165,3171,3183,3203,3212,3216,3240,3251,3257,3268,3272,3277,3286,3294,3299,3311,3315,3340,3344,3396,3400,3406,3415,3427,3439,3455,3459,3478,3505,3515,3517,3526,3530,3540,3542,3551,3567,3571,3642,3662,3673,3714,3716,3722,3747,3749,3773,3780,3782,3790,3801,3807,3840,3865,3881,3893,3895,3897,3911,3948,3972,3991,4028,4038,4169,4253,4293,4295,4301,4346,4680,4685,4694,4696,4701,4744,4749,4784,4789,4798,4800,4805,4822,4880,4885,4954,4959,5007,5109,5117,5740,5759,5786,5866,5880,5909,5940,5971,5996,6000,6003,6099,6103,6109,6121,6157,6169,6264,6314,6389,6430,6443,6459,6509,6516,6571,6601,6617,6683,6750,6780,6793,6809,6823,6862,6988,7001,7027,7155,7223,7241,7293,7304,7354,7359,7378,7418,7957,7965,8005,8013,8023,8025,8027,8029,8061,8116,8124,8126,8132,8140,8147,8155,8172,8180,8188,8205,8256,8276,8305,8319,8348,8432,8450,8455,8467,8469,8477,8484,8486,8488,8493,8505,8511,8521,8526,8584,9449,11492,11507,11557,11559,11565,11623,11631,11670,11686,11694,11702,11710,11718,11726,11734,11742,11775,11823,12295,12335,12341,12348,12438,12442,12447,12538,12543,12591,12686,12735,12799,19903,42124,42237,42508,42539,42610,42621,42737,42783,42888,42954,42961,42963,42969,43047,43052,43123,43205,43225,43255,43259,43309,43347,43388,43456,43481,43518,43574,43597,43609,43638,43714,43741,43759,43766,43782,43790,43798,43814,43822,43866,43881,44010,44013,44025,55203,55238,55291,64109,64217,64262,64279,64296,64310,64316,64318,64321,64324,64433,64829,64911,64967,65019,65039,65071,65076,65103,65140,65276,65305,65338,65343,65370,65470,65479,65487,65495,65500,65547,65574,65594,65597,65613,65629,65786,65908,66045,66204,66256,66272,66335,66378,66426,66461,66499,66511,66517,66717,66729,66771,66811,66855,66915,66938,66954,66962,66965,66977,66993,67001,67004,67382,67413,67431,67461,67504,67514,67589,67592,67637,67640,67644,67669,67702,67742,67826,67829,67861,67897,68023,68031,68099,68102,68115,68119,68149,68154,68159,68220,68252,68295,68326,68405,68437,68466,68497,68680,68786,68850,68903,68921,69289,69292,69297,69404,69415,69456,69509,69572,69622,69702,69749,69818,69826,69864,69881,69940,69951,69959,70003,70006,70084,70092,70106,70108,70161,70199,70209,70278,70280,70285,70301,70312,70378,70393,70403,70412,70416,70440,70448,70451,70457,70468,70472,70477,70480,70487,70499,70508,70516,70730,70745,70753,70853,70855,70873,71093,71104,71133,71232,71236,71257,71352,71369,71450,71467,71481,71494,71738,71913,71942,71945,71955,71958,71989,71992,72003,72025,72103,72151,72161,72164,72254,72263,72345,72349,72440,72712,72758,72768,72793,72847,72871,72886,72966,72969,73014,73018,73021,73031,73049,73061,73064,73102,73105,73112,73129,73462,73488,73530,73538,73561,73648,74649,74862,75075,77808,78895,78933,83526,92728,92766,92777,92862,92873,92909,92916,92982,92995,93017,93047,93071,93823,94026,94087,94111,94177,94180,94193,100343,101589,101640,110579,110587,110590,110882,110898,110930,110933,110951,111355,113770,113788,113800,113817,113822,118573,118598,119145,119154,119170,119179,119213,119364,119892,119964,119967,119970,119974,119980,119993,119995,120003,120069,120074,120084,120092,120121,120126,120132,120134,120144,120485,120512,120538,120570,120596,120628,120654,120686,120712,120744,120770,120779,120831,121398,121452,121461,121476,121503,121519,122654,122666,122886,122904,122913,122916,122922,122989,123023,123180,123197,123209,123214,123566,123641,124153,124902,124907,124910,124926,125124,125142,125259,125273,126467,126495,126498,126500,126503,126514,126519,126521,126523,126530,126535,126537,126539,126543,126546,126548,126551,126553,126555,126557,126559,126562,126564,126570,126578,126583,126588,126590,126601,126619,126627,126633,126651,127305,127337,127369,130041,173791,177977,178205,183969,191456,195101,201546,205743,917999];
    var low: i64=0; var high=starts.len;
    while low<high { let middle=(low+high)/2; if c<starts[middle] { high=middle; } else if c>ends[middle] { low=middle+1; } else { return true; } }
    return false;
}

// SearchesController#query: params[:q].gsub(/[^[:word:]]/, " "), each character that isn't a word
// character becoming one space. False for text that isn't UTF-8, which Rails refuses (a 400).
fn search_query(raw: const u8[:], out: u8[>..]&) -> bool {
    var i: i64 = 0;
    while i < raw.len {
        let first = raw[i];
        var c: u32 = first; var extra: i64 = 0;
        if first >= 248 { return false; }
        else if first >= 240 { c = first & 7; extra = 3; }
        else if first >= 224 { c = first & 15; extra = 2; }
        else if first >= 192 { c = first & 31; extra = 1; }
        else if first >= 128 { return false; }
        if i + 1 + extra > raw.len { return false; }
        for j in extra {
            let next = raw[i + 1 + j];
            if next & 192 != 128 { return false; }
            c = (c << 6) | (next & 63);
        }
        if extra == 1 && c < 128 || extra == 2 && (c < 2048 || c >= 55296 && c <= 57343) || extra == 3 && (c < 65536 || c > 1114111) { return false; }
        if query_word(c) { out.append(raw[i..i + 1 + extra]); } else { out.push(' '); }
        i += 1 + extra;
    }
    return true;
}

// `present?` for a sanitized query: anything but spaces.
fn query_present(query: const u8[:]) -> bool {
    for c in query { if c != ' ' { return true; } }
    return false;
}

// Active Model's integer cast of a parameter or cookie (`find_by(id: ...)`): leading spaces, a sign
// and digits, whatever follows; false when it doesn't start like a number.
fn rails_id(text: const u8[:]) -> i64, bool {
    var i: i64 = 0;
    while i < text.len && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n' || text[i] == '\r') { i += 1; }
    var negative = false;
    if i < text.len && (text[i] == '+' || text[i] == '-') { negative = text[i] == '-'; i += 1; }
    var value: i64 = 0; var digits: i64 = 0;
    while i < text.len && text[i] >= '0' && text[i] <= '9' {
        if digits < 18 { value = value * 10 + (text[i] - '0'); }
        digits += 1; i += 1;
    }
    if digits == 0 { return 0, false; }
    return if negative { -value } else { value }, true;
}

// --- The flash -------------------------------------------------------------------------------------

// Rails keeps the flash in its session cookie, `_campfire_session`, until a page in the application
// layout shows it; the cookie is Rails' encrypted session (auth_routes.goose).
let FLASH_COOKIE = "_campfire_session";
let FLASH_CLEARED = "_campfire_session=; path=/; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT; httponly; samesite=lax";
let FLASH_CLEARED_FIELD = "Set-Cookie: _campfire_session=; path=/; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT; httponly; samesite=lax\n";

// The Set-Cookie value for `redirect_to ..., alert:` (kind "alert") or `notice:`.
fn flash_cookie(kind: const u8[:], message: const u8[:], key: const u8[:]) -> u8[>..] {
    return session_flash_cookie(kind, message);
}

// Whether req carries a flash cookie at all (a page that would show it isn't served from the cache).
fn has_flash(req: const http::Request&) -> bool {
    let raw, present = http::cookie_of(req, FLASH_COOKIE);
    return present;
}

// The request's flash, as the application layout shows it: ctx.notice, and ctx.has_alert for an alert.
fn read_flash(req: const http::Request&, key: const u8[:], ctx: ViewContext&, bytes: u8[>..]&) -> bool {
    let message, is_alert, present = session_flash(req);
    guard present else { return false; }
    ctx.notice = view_keep(bytes, message);
    ctx.has_alert = is_alert;
    return true;
}

// --- Responses -----------------------------------------------------------------------------------

// The formats a request asks for, as ActionDispatch reads Accept: a browser's (one listing */*
// among others) or none means HTML; otherwise HTML must be among them for an HTML template.
fn html_acceptable(req: const http::Request&) -> bool {
    let accept, has_accept = http::field_of(req, "Accept");
    guard has_accept && trim(accept).len > 0 else { return true; }
    let parts = split(accept, ',');
    for part in parts {
        let semicolon = find(part, ";");
        let media = trim(if semicolon >= 0 { part[..semicolon] } else { part });
        if media == "text/html" || media == "application/xhtml+xml" || media == "*/*" || media == "text/*" { return true; }
    }
    return false;
}

// ActionController::MissingExactTemplate's 406, as Rails renders it.
fn respond_not_acceptable(out: http::Reply) {
    http::respond(out, 406, "application/json; charset=UTF-8", "{\"status\":406,\"error\":\"Not Acceptable\"}");
}

fn respond_server_error(out: http::Reply, failed: sqlite::Error[:]) {
    for e in failed { write_stderr(str("database error ", e.code, ": ", e.message, "\n")); }
    http::respond(out, 500, "text/plain", "Internal Server Error");
}

// `redirect_to path` with the extra header lines (`Name: value` each, newline-separated).
fn redirect_with(out: http::Reply, req: const http::Request&, path: const u8[:], extra: const u8[:]) {
    http::start(out, 302);
    http::field(out, "Location", str(request_base(req), path));
    header_lines(out, extra);
    http::finish(out, http::TEXT, "Redirecting");
}

// A page rendered for user: with the flash it took, never cached, and its cookie cleared; otherwise
// through the response cache, with extra headers replayed on hits.
fn send_html_page(out: http::Reply, req: const http::Request&, entries: CachedPage[:], bytes: u8[>..]&, state: CacheState&,
                  user: i64, page: const u8[:], took_flash: bool, extra: const u8[:]) {
    if took_flash || has_flash(req) {
        let headers: u8[>..] = if took_flash { str(extra, "Set-Cookie: ", FLASH_CLEARED, "\n") } else { str(extra) };
        respond_html(out, req, 200, page, headers);
    } else {
        cache_page(entries, bytes, state, user, req, page, out, extra);
    }
}

fn turbo_frame(req: const http::Request&) -> bool {
    let frame, framed = http::field_of(req, "Turbo-Frame");
    return framed;
}

// --- Rooms the user visits -------------------------------------------------------------------------

// TrackedRoomVisit#last_room_visited: the room in the last_room cookie when the user is in it, else
// `Current.user.rooms.original`, their earliest room; 0 when they have none.
fn visited_room(db, user: i64, req: const http::Request&) -> i64 {
    let cookie, has_cookie = http::cookie_of(req, "last_room");
    var wanted: i64 = 0;
    if has_cookie { var value: u8[>..] = []; if http::decode(cookie, value, false) { let id, valid = rails_id(value); if valid { wanted = id; } } }
    return sql_number(db, "SELECT r.id FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? ORDER BY (r.id=?) DESC,r.created_at LIMIT 1",
        [sql_text(user), sql_text(wanted)]);
}

// The message columns message_view reads, around a filter of the room's messages.
let PAGE_START = "SELECT m.id,m.client_message_id,u.name,idx.body,rt.body,m.creator_id,m.created_at,m.updated_at,m.room_id,r.name,r.type FROM (SELECT * FROM messages WHERE room_id=?1 ";
let PAGE_END = ") m LEFT JOIN users u ON u.id=m.creator_id JOIN rooms r ON r.id=m.room_id LEFT JOIN message_search_index idx ON idx.rowid=m.id LEFT JOIN action_text_rich_texts rt ON rt.record_type='Message' AND rt.name='body' AND rt.record_id=m.id ORDER BY m.created_at";
let PAGE_LAST: i32 = 0;
let PAGE_BEFORE: i32 = 1;
let PAGE_AFTER: i32 = 2;

// Message::Pagination: last_page, page_before(anchor) or page_after(anchor), 40 messages in order.
// Returns the latest updated_at among them.
fn message_page(db, room: i64, kind: i32, anchor: const u8[:], ctx: const ViewContext&, key: const u8[:], bytes: u8[>..]&,
                boosts: BoostView[>..]&, messages: MessageView[>..]&) -> u8[>..] {
    let filter = if kind == PAGE_BEFORE { "AND created_at < ?2 ORDER BY created_at DESC LIMIT 40" }
        else if kind == PAGE_AFTER { "AND created_at > ?2 ORDER BY created_at LIMIT 40" } else { "ORDER BY created_at DESC LIMIT 40" };
    var q = sqlite::Stmt {}; var latest: u8[>..] = [];
    let failed = sqlite::run() {
        q = sqlite::prepare(db, str(PAGE_START, filter, PAGE_END));
        sqlite::bind_i64(q, 1, room);
        if kind != PAGE_LAST { sqlite::bind_text(q, 2, anchor); }
        while sqlite::step(q) {
            let updated = view_text(q, 7); if compare(updated, latest) > 0 { latest.clear(); latest.append(updated); }
            messages.push(message_view(db, q, key, ctx.storage_key, bytes, boosts));
        }
    };
    sqlite::finalize(q); for e in failed { sqlite::fail(e.code, e.message); }
    return latest;
}

// A message of the room: its created_at, or "" when it isn't one.
fn room_message_created(db, room: i64, text: const u8[:]) -> u8[] {
    let id, valid = rails_id(text);
    if !valid { return []; }
    return sql_value(db, "SELECT created_at FROM messages WHERE id=? AND room_id=?", [sql_text(id), sql_text(room)]);
}

// --- Routes --------------------------------------------------------------------------------------

// Search, the root, rooms#index and #show with permalinks, and message paging. False for any other
// request, after a few comparisons.
fn search_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], entries: CachedPage[:], bytes: u8[>..]&,
                state: CacheState&, keys: const PageKeys&, out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    let reading = req.method == "GET" || req.method == "HEAD";
    if path == "/" && reading { root_page(db, user, req, keys, out); return true; }
    if path == "/rooms" && reading { rooms_index(db, user, req, out); return true; }
    if path == "/searches" {
        if reading { search_page(db, user, req, entries, bytes, state, keys, out); return true; }
        if effective_method(req, body) == "POST" { record_search(db, user, req, body, out); return true; }
        return false;
    }
    guard reading && starts_with(path, "/rooms/") else { return false; }
    let rest = path[7..]; let slash = find(rest, "/");
    if slash < 0 { room_page(db, user, req, rest, "", false, entries, bytes, state, keys, out); return true; }
    let tail = rest[slash..];
    if starts_with(tail, "/@") && tail.len > 2 && find(tail[2..], "/") < 0 {
        room_page(db, user, req, rest[..slash], tail[2..], true, entries, bytes, state, keys, out); return true;
    }
    if tail == "/messages" { messages_page(db, user, req, rest[..slash], entries, bytes, state, keys, out); return true; }
    return false;
}

// WelcomeController#show: the last room visited, or the welcome page when the user has no rooms.
fn root_page(db: sqlite::Db, user: i64, req: const http::Request&, keys: const PageKeys&, out: http::Reply) {
    var room: i64 = 0; var page: u8[>..] = []; var took = false; var view_bytes: u8[>..] = [];
    let acceptable = html_acceptable(req);
    let failed = sqlite::run() {
        room = visited_room(db, user, req);
        if room == 0 && acceptable {
            var ctx = load_view_context(db, user, keys.avatar, keys.stream, keys.vapid, req, view_bytes, keys.storage);
            ctx.title = "No rooms yet"; ctx.body_class = "sidebar";
            if turbo_frame(req) { render_welcome_frame_html(page, ctx); }
            else { took = read_flash(req, keys.cookie, ctx, view_bytes); render_welcome_html(page, ctx); }
        }
    };
    if failed.len > 0 { respond_server_error(out, failed); }
    else if room > 0 { redirect_to_path(out, req, str("/rooms/", room)); }
    else if !acceptable { respond_not_acceptable(out); }
    else { respond_html(out, req, 200, page, if took { FLASH_CLEARED_FIELD } else { "" }); }
}

// RoomsController#index: `redirect_to room_url(Current.user.rooms.last)`; with no rooms, room_url(nil)
// raises (a 500).
fn rooms_index(db: sqlite::Db, user: i64, req: const http::Request&, out: http::Reply) {
    var room: i64 = 0;
    let failed = sqlite::run() { room = sql_number(db, "SELECT r.id FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? ORDER BY r.id DESC LIMIT 1", [sql_text(user)]); };
    if failed.len > 0 { respond_server_error(out, failed); }
    else if room == 0 { http::respond(out, 500, "text/plain", "Internal Server Error"); }
    else { redirect_to_path(out, req, str("/rooms/", room)); }
}

// RoomsController#show, and /rooms/:id/@:message_id: set_room (back to the root with an alert for a
// room the user isn't in), remember_last_room_visited, then the last page of messages, or the pages
// around the message when it is one of the room's.
fn room_page(db: sqlite::Db, user: i64, req: const http::Request&, room_text: const u8[:], message_text: const u8[:], permalink: bool,
             entries: CachedPage[:], bytes: u8[>..]&, state: CacheState&, keys: const PageKeys&, out: http::Reply) {
    if !has_flash(req) && cached_page(entries, bytes, state, user, req, out) { return; }
    let room, valid = rails_id(room_text);
    let acceptable = html_acceptable(req);
    var found = false; var took = false; var page: u8[>..] = []; var view_bytes: u8[>..] = [];
    var q = sqlite::Stmt {}; var messages: MessageView[>..] = []; var boosts: BoostView[>..] = [];
    let failed = sqlite::run() {
        q = sqlite::prepare(db, "SELECT r.id,r.name,r.type,r.updated_at FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=?");
        sqlite::bind_i64(q, 1, if valid { room } else { 0 }); sqlite::bind_i64(q, 2, user);
        found = sqlite::step(q);
        if found && acceptable {
            var ctx = load_view_context(db, user, keys.avatar, keys.stream, keys.vapid, req, view_bytes, keys.storage);
            ctx.room = room_view(q, view_bytes); ctx.body_class = "sidebar";
            if ctx.room.direct { let name = direct_room_name(db, room, user); ctx.room.display_name = if name.len > 0 { view_keep(view_bytes, name) } else { ctx.user.name }; }
            ctx.title = ctx.room.display_name;
            ctx.messages_stream_name = view_keep(view_bytes, signed_stream(str(gid_param(view_text(q, 2), room), ":messages"), keys.stream));
            let anchor: u8[>..] = if permalink { room_message_created(db, room, message_text) } else { str("") };
            if anchor.len > 0 {
                // page_around: page_before(message) + [message] + page_after(message).
                let id, valid_id = rails_id(message_text);
                let before = message_page(db, room, PAGE_BEFORE, anchor, ctx, keys.avatar, view_bytes, boosts, messages);
                let message, exists = load_message_view(db, id, keys.avatar, keys.storage, view_bytes, boosts);
                if exists { messages.push(message); }
                let after = message_page(db, room, PAGE_AFTER, anchor, ctx, keys.avatar, view_bytes, boosts, messages);
            } else {
                let latest = message_page(db, room, PAGE_LAST, "", ctx, keys.avatar, view_bytes, boosts, messages);
            }
            ctx.messages = messages;
            if turbo_frame(req) { render_room_frame_html(page, ctx); }
            else { took = read_flash(req, keys.cookie, ctx, view_bytes); render_room_html(page, ctx); }
        }
    };
    sqlite::finalize(q);
    if failed.len > 0 { respond_server_error(out, failed); }
    else if !found { redirect_with(out, req, "/", str("Set-Cookie: ", flash_cookie("alert", "Room not found or inaccessible", keys.cookie), "\n")); }
    // remember_last_room_visited ran before the render found no template for the format.
    else if !acceptable { respond_not_acceptable(out); }
    else { send_html_page(out, req, entries, bytes, state, user, page, took, str("Set-Cookie: ", last_room_cookie(room), "\n")); }
}

// A present `before` or `after` parameter of message paging.
fn paging_param(req: const http::Request&, name: const u8[:]) -> u8[>..], bool {
    let raw, present = http::query_of(req.target, name);
    var value: u8[>..] = [];
    if !present || !http::decode(raw, value, true) || trim(value).len == 0 { return value, false; }
    return value, true;
}

// MessagesController#index (layout false): the page before or after a message of the room, or the last
// page; a 404 for a room the user isn't in or a message not in it, 204 for an empty page, and
// `fresh_when @messages`: an ETag, Last-Modified from the newest update, and 304 when the request's
// validators still hold.
fn messages_page(db: sqlite::Db, user: i64, req: const http::Request&, room_text: const u8[:], entries: CachedPage[:], bytes: u8[>..]&,
                 state: CacheState&, keys: const PageKeys&, out: http::Reply) {
    if cached_page(entries, bytes, state, user, req, out) { return; }
    let room, valid = rails_id(room_text);
    var status: i32 = 200; var page: u8[>..] = []; var latest: u8[>..] = []; var view_bytes: u8[>..] = [];
    var messages: MessageView[>..] = []; var boosts: BoostView[>..] = [];
    let before, has_before = paging_param(req, "before");
    let after, has_after = paging_param(req, "after");
    let failed = sqlite::run() {
        var anchor: u8[>..] = [];
        if !valid || sql_number(db, "SELECT count(*) FROM memberships WHERE room_id=? AND user_id=?", [sql_text(room), sql_text(user)]) == 0 { status = 404; }
        else if has_before || has_after {
            anchor.append(room_message_created(db, room, if has_before { before } else { after }));
            if anchor.len == 0 { status = 404; }
        }
        if status == 200 {
            var ctx = load_view_context(db, user, keys.avatar, keys.stream, keys.vapid, req, view_bytes, keys.storage);
            let kind = if has_before { PAGE_BEFORE } else if has_after { PAGE_AFTER } else { PAGE_LAST };
            latest = message_page(db, room, kind, anchor, ctx, keys.avatar, view_bytes, boosts, messages);
            if messages.len == 0 { status = 204; }
            else if !html_acceptable(req) { status = 406; }
            else { ctx.messages = messages; render_messages_html(page, ctx); }
        }
    };
    if failed.len > 0 { respond_server_error(out, failed); return; }
    if status == 404 { http::respond(out, 404, "text/plain", "Not found"); return; }
    if status == 204 { respond_empty(out, 204); return; }
    if status == 406 { respond_not_acceptable(out); return; }
    let digest = hash::sha256(page);
    let digits = "0123456789abcdef"; var etag = str("W/\"");
    for c in digest[..16] { etag.push(digits[c >> 4]); etag.push(digits[c & 15]); }
    etag.push('"');
    let modified = campfire_epoch_ms(latest) / 1000;
    var date: u8[>..] = []; http::format_date(date, modified);
    let extra = str("Cache-Control: max-age=0, private, must-revalidate\nETag: ", etag, "\nLast-Modified: ", date, "\n");
    // Request#fresh?: every validator the request sends must hold.
    let since, has_since = http::field_of(req, "If-Modified-Since");
    let tags, has_tags = http::field_of(req, "If-None-Match");
    var fresh = has_since || has_tags;
    if has_since { let t, ok = http::parse_date(since); fresh = fresh && ok && t >= modified; }
    if has_tags {
        var hit = false;
        for tag in split(tags, ',') { let t = trim(tag); if t == etag || t == "*" { hit = true; } }
        fresh = fresh && hit;
    }
    if fresh { http::start(out, 304); header_lines(out, extra); http::finish(out, http::NO_TYPE, ""); return; }
    cache_page(entries, bytes, state, user, req, page, out, extra);
}

// SearchesController#index: the query's last 100 reachable messages when it is present, the user's
// recent searches, and the way back to their last room.
fn search_page(db: sqlite::Db, user: i64, req: const http::Request&, entries: CachedPage[:], bytes: u8[>..]&, state: CacheState&,
               keys: const PageKeys&, out: http::Reply) {
    let raw, has_q = http::query_of(req.target, "q");
    var q: u8[>..] = []; var query: u8[>..] = [];
    if has_q && (!http::decode(raw, q, true) || !search_query(q, query)) { http::respond(out, 400, "text/plain", "Bad request"); return; }
    if !has_flash(req) && cached_page(entries, bytes, state, user, req, out) { return; }
    let present = has_q && query_present(query);
    var status: i32 = 200; var took = false; var page: u8[>..] = []; var view_bytes: u8[>..] = [];
    var found = sqlite::Stmt {}; var recent = sqlite::Stmt {};
    var messages: MessageView[>..] = []; var boosts: BoostView[>..] = []; var searches: const u8[:][>..] = [];
    let failed = sqlite::run() {
        var ctx = load_view_context(db, user, keys.avatar, keys.stream, keys.vapid, req, view_bytes, keys.storage);
        if present {
            // Current.user.reachable_messages.search(query).last_page_of_matches(100), Rails #304: the newest
            // 100 by the index's rowid (the message id), shown oldest first. The query goes to MATCH as it is.
            found = sqlite::prepare(db, "SELECT m.id,m.client_message_id,u.name,idx.body,rt.body,m.creator_id,m.created_at,m.updated_at,m.room_id,r.name,r.type FROM (SELECT m.* FROM messages m JOIN memberships mm ON mm.room_id=m.room_id JOIN message_search_index idx ON idx.rowid=m.id WHERE mm.user_id=? AND idx.body MATCH ? ORDER BY idx.rowid DESC LIMIT 100) m LEFT JOIN users u ON u.id=m.creator_id JOIN rooms r ON r.id=m.room_id JOIN message_search_index idx ON idx.rowid=m.id LEFT JOIN action_text_rich_texts rt ON rt.record_type='Message' AND rt.name='body' AND rt.record_id=m.id ORDER BY m.id");
            sqlite::bind_i64(found, 1, user); sqlite::bind_text(found, 2, query);
            while sqlite::step(found) { messages.push(message_view(db, found, keys.avatar, keys.storage, view_bytes, boosts)); }
        }
        recent = sqlite::prepare(db, "SELECT query FROM searches WHERE user_id=? ORDER BY updated_at DESC"); sqlite::bind_i64(recent, 1, user);
        while sqlite::step(recent) { searches.push(view_keep(view_bytes, view_text(recent, 0))); }
        ctx.return_to_room_id = visited_room(db, user, req);
        if !html_acceptable(req) { status = 406; }
        // room_path(nil) raises when the user has no rooms.
        else if ctx.return_to_room_id == 0 { status = 500; }
        ctx.title = "Search"; ctx.body_class = "sidebar searches";
        ctx.has_query = present; ctx.query = view_keep(view_bytes, query);
        ctx.has_q = has_q; ctx.q = view_keep(view_bytes, q);
        ctx.messages = messages; ctx.recent_searches = searches;
        if status != 200 {}
        else if turbo_frame(req) { render_search_frame_html(page, ctx); }
        else { took = read_flash(req, keys.cookie, ctx, view_bytes); render_search_html(page, ctx); }
    };
    sqlite::finalize(recent); sqlite::finalize(found);
    if failed.len > 0 { respond_server_error(out, failed); return; }
    if status == 406 { respond_not_acceptable(out); return; }
    if status == 500 { http::respond(out, 500, "text/plain", "Internal Server Error"); return; }
    send_html_page(out, req, entries, bytes, state, user, page, took, "");
}

// SearchesController's before_action set_messages for an action that only needs it to run: a `q`
// that isn't UTF-8 is a 400, and one MATCH can't parse is a 500. True when it answered.
fn set_messages_failed(db: sqlite::Db, req: const http::Request&, body: const u8[:], out: http::Reply) -> bool {
    var q: u8[>..] = [];
    var has_q = http::form_value(body, "q", q);
    if !has_q { let raw, in_query = http::query_of(req.target, "q"); has_q = in_query && http::decode(raw, q, true); }
    guard has_q else { return false; }
    var query: u8[>..] = [];
    if !search_query(q, query) { http::respond(out, 400, "text/plain", "Bad request"); return true; }
    guard query_present(query) else { return false; }
    let checked = sqlite::run() { sql_rows(db, "SELECT rowid FROM message_search_index WHERE body MATCH ? LIMIT 1", [sql_text(query)]); };
    if checked.len > 0 { respond_server_error(out, checked); return true; }
    return false;
}

// SearchesController#create: set_messages runs the search first (a query MATCH can't parse fails
// there), then Search.record finds or creates the user's search and touches it, keeping their ten
// latest, and the redirect shows it.
fn record_search(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], out: http::Reply) {
    if !same_origin(req) { http::respond(out, 422, "text/plain", "Invalid origin"); return; }
    var q: u8[>..] = [];
    var has_q = http::form_value(body, "q", q);
    if !has_q { let raw, in_query = http::query_of(req.target, "q"); has_q = in_query && http::decode(raw, q, true); }
    var query: u8[>..] = [];
    if has_q && !search_query(q, query) { http::respond(out, 400, "text/plain", "Bad request"); return; }
    // Search.record(nil): the query column is NOT NULL.
    if !has_q { http::respond(out, 500, "text/plain", "Internal Server Error"); return; }
    if query_present(query) {
        let checked = sqlite::run() { sql_rows(db, "SELECT rowid FROM message_search_index WHERE body MATCH ? LIMIT 1", [sql_text(query)]); };
        if checked.len > 0 { respond_server_error(out, checked); return; }
    }
    var now: u8[>..] = []; campfire_sql_now(now);
    let failed = write_transaction(db) {
        let existing = sql_number(db, "SELECT id FROM searches WHERE user_id=? AND query=? LIMIT 1", [sql_text(user), sql_text(query)]);
        if existing > 0 { sql_rows(db, "UPDATE searches SET updated_at=? WHERE id=?", [sql_text(now), sql_text(existing)]); }
        else {
            sql_rows(db, "INSERT INTO searches(user_id,query,created_at,updated_at) VALUES(?,?,?,?)", [sql_text(user), sql_text(query), sql_text(now), sql_text(now)]);
            // after_create :trim_recent_searches
            sql_rows(db, "DELETE FROM searches WHERE user_id=? AND id NOT IN (SELECT id FROM searches WHERE user_id=? ORDER BY updated_at DESC LIMIT 10)", [sql_text(user), sql_text(user)]);
        }
    };
    if failed.len > 0 { respond_server_error(out, failed); return; }
    redirect_to_path(out, req, search_url(query));
}

// MessagesController#create's `render action: :room_not_found` for a room the user can't post to: the
// composer's frame in the application layout.
fn room_not_found(db: sqlite::Db, user: i64, req: const http::Request&, keys: const PageKeys&, out: http::Reply) {
    var page: u8[>..] = []; var content: u8[>..] = []; var took = false; var view_bytes: u8[>..] = [];
    let failed = sqlite::run() {
        var ctx = load_view_context(db, user, keys.avatar, keys.stream, keys.vapid, req, view_bytes, keys.storage);
        render_room_not_found_html(content, ctx);
        ctx.page_content = content;
        if turbo_frame(req) { page.append("<html>\n  <head>\n    \n  </head>\n  <body>\n    "); page.append(content); page.append("\n  </body>\n</html>\n"); }
        else { took = read_flash(req, keys.cookie, ctx, view_bytes); render_page_html(page, ctx); }
    };
    if failed.len > 0 { respond_server_error(out, failed); return; }
    respond_html(out, req, 200, page, if took { FLASH_CLEARED_FIELD } else { "" });
}
