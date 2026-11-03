// What Active Storage's VideoAnalyzer and AudioAnalyzer make of ffprobe's JSON
// (activestorage/lib/active_storage/analyzer/{video,audio}_analyzer.rb at the reference's Rails
// revision), with Ruby's Float() and Integer() conversions, and the metadata Blob#analyze saves,
// written as ActiveSupport::JSON writes it.
namespace campfire;

import std;
import json;

// Float#to_s, as Ruby's JSON writes a Float: the shortest digits that read back, laid out fixed
// for decimal exponents from -3 through 16 (65.84, 320.0, 0.0001), past them as d.ddde+XX
// (1.0e+16, 1.0e-05).
fn ruby_float(out: u8[>..]&, v: f64) {
    if v != v || v - v != 0.0 { out.append("null"); return; }
    var text: u8[>..] = []; json::format_number(text, v);
    var at: i64 = 0;
    if text.len > 0 && text[0] == '-' { out.push('-'); at = 1; }
    let e = find(text[at..], "e");
    let mantissa = if e >= 0 { text[at..at + e] } else { text[at..] };
    var exponent: i64 = 0;
    if e >= 0 { let n, valid = parse_int(text[at + e + 1..]); if valid { exponent = n; } }
    var digits: u8[>..] = []; var point: i64 = -1;
    for c, i in mantissa { if c == '.' { point = i; } else { digits.push(c); } }
    var decpt = (if point >= 0 { point } else { mantissa.len }) + exponent;
    var lead: i64 = 0;
    while lead < digits.len && digits[lead] == '0' { lead += 1; }
    var end = digits.len;
    while end > lead && digits[end - 1] == '0' { end -= 1; }
    if lead == end { out.append("0.0"); return; }
    let d = digits[lead..end];
    decpt -= lead;
    if decpt > 0 && decpt <= 16 {
        if decpt >= d.len { out.append(d); for _ in decpt - d.len { out.push('0'); } out.append(".0"); }
        else { out.append(d[..decpt]); out.push('.'); out.append(d[decpt..]); }
    } else if decpt <= 0 && decpt > -4 {
        out.append("0."); for _ in -decpt { out.push('0'); } out.append(d);
    } else {
        out.push(d[0]); out.push('.');
        if d.len > 1 { out.append(d[1..]); } else { out.push('0'); }
        out.push('e');
        let x = decpt - 1;
        out.push(if x < 0 { '-' } else { '+' });
        let magnitude = if x < 0 { -x } else { x };
        if magnitude < 10 { out.push('0'); }
        format(out, magnitude);
    }
}

fn ruby_float_text(v: f64) -> u8[>..] { var out: u8[>..] = []; ruby_float(out, v); return out; }

// An extracted metadata member: its name, a NUL, and its JSON.
fn member_entry(name: const u8[:], value: const u8[:]) -> u8[>..] { return str(name, "\x00", value); }

// A String as ActiveSupport::JSON writes it with Rails 8.2's defaults: JSON's escapes, and <, >
// and & as \u003c, \u003e and \u0026.
fn rails_json_string(out: u8[>..]&, s: const u8[:]) {
    var escaped: u8[>..] = []; json::format_string(escaped, s);
    for c in escaped {
        if c == '<' { out.append("\\u003c"); } else if c == '>' { out.append("\\u003e"); } else if c == '&' { out.append("\\u0026"); } else { out.push(c); }
    }
}

// A parsed value as ActiveSupport::JSON writes what JSON.parse made of it.
recursive fn rails_json_value(out: u8[>..]&, n: json::Node&) {
    match n.val {
        Null => { out.append("null"); },
        Bool b => { out.append(if b.v { "true" } else { "false" }); },
        Int i => { format(out, i.v); },
        Num x => { ruby_float(out, x.v); },
        Str t => { rails_json_string(out, t.s); },
        Arr a => {
            out.push('['); var first = true;
            json::each(n) { c => if !first { out.push(','); } first = false; rails_json_value(out, c); };
            out.push(']');
        },
        Obj o => {
            out.push('{'); var first = true;
            json::each(n) { c => if !first { out.push(','); } first = false; rails_json_string(out, c.key); out.push(':'); rails_json_value(out, c); };
            out.push('}');
        },
    }
}

fn is_json_object(n: json::Node?) -> bool {
    guard n else { return false; }
    match n.val {
        Obj o => { return true; },
        _ => { return false; },
    }
}

// String#strip's white space, either side.
fn strip_space(text: const u8[:]) -> const u8[:] {
    var start: i64 = 0; var end = text.len;
    while start < end && (text[start] == ' ' || (text[start] >= 9 && text[start] <= 13) || text[start] == 0) { start += 1; }
    while end > start && (text[end - 1] == ' ' || (text[end - 1] >= 9 && text[end - 1] <= 13) || text[end - 1] == 0) { end -= 1; }
    return text[start..end];
}

// Float(string) for the decimals ffprobe writes: white space either side, an optional sign.
fn float_text(raw: const u8[:]) -> f64, bool {
    let text = strip_space(raw);
    var number: u8[>..] = [];
    number.append(if text.len > 1 && text[0] == '+' && text[1] != '-' { text[1..] } else { text });
    guard number.len > 0 else { return 0.0, false; }
    let scanned = json::scan_number(number, 0);
    guard scanned.end == number.len else { return 0.0, false; }
    return scanned.value, true;
}

// Integer(string): white space either side, an optional sign, a 0x, 0b, 0o, 0d or 0 radix prefix,
// and digits with single underscores between them.
fn integer_text(raw: const u8[:]) -> i64, bool {
    let text = strip_space(raw);
    var at: i64 = 0; var negative = false;
    if at < text.len && (text[at] == '+' || text[at] == '-') { negative = text[at] == '-'; at += 1; }
    var base: i64 = 10;
    if at + 1 < text.len && text[at] == '0' {
        let p = text[at + 1];
        if p == 'x' || p == 'X' { base = 16; at += 2; }
        else if p == 'b' || p == 'B' { base = 2; at += 2; }
        else if p == 'o' || p == 'O' { base = 8; at += 2; }
        else if p == 'd' || p == 'D' { at += 2; }
        else { base = 8; at += 1; }
    }
    var value: i64 = 0; var digit_before = false;
    for c in text[at..] {
        if c == '_' { guard digit_before else { return 0, false; } digit_before = false; continue; }
        var digit: i64 = 99;
        if c >= '0' && c <= '9' { digit = c - '0'; }
        else if c >= 'a' && c <= 'z' { digit = c - 'a' + 10; }
        else if c >= 'A' && c <= 'Z' { digit = c - 'A' + 10; }
        guard digit < base && value <= (9223372036854775807 - digit) / base else { return 0, false; }
        value = value * base + digit; digit_before = true;
    }
    guard digit_before else { return 0, false; }
    let signed = if negative { -value } else { value };
    return signed, true;
}

// Ruby's Float(value) for what ffprobe writes: a number, or a string of one.
fn probe_float(n: json::Node?) -> f64, bool {
    guard n else { return 0.0, false; }
    match n.val {
        Int i => { return i.v, true; },
        Num x => { return x.v, true; },
        Str t => { return float_text(t.s); },
        _ => { return 0.0, false; },
    }
}

// Ruby's Integer(value): an integer, a finite float truncated, or a string of one.
fn probe_integer(n: json::Node?) -> i64, bool {
    guard n else { return 0, false; }
    match n.val {
        Int i => { return i.v, true; },
        Num x => {
            guard x.v - x.v == 0.0 && x.v < 9.2e18 && x.v > -9.2e18 else { return 0, false; }
            return x.v as i64, true;
        },
        Str t => { return integer_text(t.s); },
        _ => { return 0, false; },
    }
}

// hash[name] as the analyzers read it: null where the member is missing or null.
fn probe_field(n: json::Node?, name: const u8[:]) -> json::Node? {
    let field = json::member(n, name);
    guard field else { return null; }
    match field.val {
        Null => { return null; },
        _ => { return field; },
    }
}

// streams.detect { |stream| stream["codec_type"] == codec_type }: null when there is none.
fn probe_stream(root: json::Node?, codec_type: const u8[:]) -> json::Node? {
    var found: json::Node? = null;
    let streams = json::member(root, "streams");
    if streams {
        json::each(streams) { stream =>
            let kind, named = json::as_string(json::member(stream, "codec_type"));
            if !found && named && kind == codec_type { found .= stream; }
        };
    }
    return found;
}

// VideoAnalyzer#metadata: { width:, height:, duration:, angle:, display_aspect_ratio:, audio:,
// video: }.compact, as names and their JSON. False, with why, where Rails' Float() or Integer()
// raises.
fn video_metadata(root: json::Node?, members: u8[][>..]&, error: u8[>..]&) -> bool {
    let video = probe_stream(root, "video");
    let audio = probe_stream(root, "audio");
    // angle: the rotate tag, or the display matrix's rotation.
    var angle: i64 = 0; var has_angle = false;
    let rotate = probe_field(probe_field(video, "tags"), "rotate");
    if rotate {
        let a, valid = probe_integer(rotate);
        guard valid else { error.append("invalid value for Integer(): the rotate tag"); return false; }
        angle = a; has_angle = true;
    } else {
        var matrix: json::Node? = null;
        let side_data = probe_field(video, "side_data_list");
        if side_data {
            json::each(side_data) { data =>
                let kind, named = json::as_string(json::member(data, "side_data_type"));
                if !matrix && named && kind == "Display Matrix" { matrix .= data; }
            };
        }
        let rotation = probe_field(matrix, "rotation");
        if rotation {
            let a, valid = probe_integer(rotation);
            guard valid else { error.append("invalid value for Integer(): the display matrix's rotation"); return false; }
            angle = a; has_angle = true;
        }
    }
    // display_aspect_ratio: "n:d" as [n, d], unless n is 0.
    var numerator: i64 = 0; var denominator: i64 = 0; var has_ratio = false;
    let descriptor = probe_field(video, "display_aspect_ratio");
    if descriptor {
        let text, is_text = json::as_string(descriptor);
        guard is_text else { error.append("undefined method 'split' for the display aspect ratio"); return false; }
        let colon = find(text, ":");
        let n, n_valid = integer_text(if colon >= 0 { text[..colon] } else { text });
        guard text.len > 0 && n_valid else { error.append(str("invalid value for Integer(): ", text)); return false; }
        guard colon >= 0 else { error.append("can't convert nil into Integer"); return false; }
        let d, d_valid = integer_text(text[colon + 1..]);
        guard d_valid else { error.append(str("invalid value for Integer(): ", text)); return false; }
        if n != 0 { numerator = n; denominator = d; has_ratio = true; }
    }
    // The encoded width; the display height (width * Float(d) / n) or else the encoded height.
    var encoded_width: f64 = 0.0; var has_width = false;
    let width_field = probe_field(video, "width");
    if width_field {
        let w, valid = probe_float(width_field);
        guard valid else { error.append("invalid value for Float(): the width"); return false; }
        encoded_width = w; has_width = true;
    }
    var tall: f64 = 0.0; var has_tall = false;
    if has_width && has_ratio { let scale: f64 = denominator; tall = encoded_width * (scale / numerator); has_tall = true; }
    else {
        let height_field = probe_field(video, "height");
        if height_field {
            let h, valid = probe_float(height_field);
            guard valid else { error.append("invalid value for Float(): the height"); return false; }
            tall = h; has_tall = true;
        }
    }
    let rotated = has_angle && (angle == 90 || angle == 270 || angle == -90 || angle == -270);
    if rotated {
        if has_tall { members.push(member_entry("width", ruby_float_text(tall))); }
        if has_width { members.push(member_entry("height", ruby_float_text(encoded_width))); }
    } else {
        if has_width { members.push(member_entry("width", ruby_float_text(encoded_width))); }
        if has_tall { members.push(member_entry("height", ruby_float_text(tall))); }
    }
    // duration: the stream's, or the container's.
    var duration = probe_field(video, "duration");
    if !duration { duration .= probe_field(json::member(root, "format"), "duration"); }
    if duration {
        let seconds, valid = probe_float(duration);
        guard valid else { error.append("invalid value for Float(): the duration"); return false; }
        members.push(member_entry("duration", ruby_float_text(seconds)));
    }
    if has_angle { members.push(member_entry("angle", str(angle))); }
    if has_ratio { members.push(member_entry("display_aspect_ratio", str("[", numerator, ",", denominator, "]"))); }
    members.push(member_entry("audio", if audio { "true" } else { "false" }));
    members.push(member_entry("video", if video { "true" } else { "false" }));
    return true;
}

// AudioAnalyzer#metadata: { duration:, bit_rate:, sample_rate:, tags: }.compact.
fn audio_metadata(root: json::Node?, members: u8[][>..]&, error: u8[>..]&) -> bool {
    let audio = probe_stream(root, "audio");
    let duration = probe_field(audio, "duration");
    if duration {
        let seconds, valid = probe_float(duration);
        guard valid else { error.append("invalid value for Float(): the duration"); return false; }
        members.push(member_entry("duration", ruby_float_text(seconds)));
    }
    for name in ["bit_rate", "sample_rate"] {
        let field = probe_field(audio, name);
        if field {
            let n, valid = probe_integer(field);
            guard valid else { error.append(str("invalid value for Integer(): the ", name)); return false; }
            members.push(member_entry(name, str(n)));
        }
    }
    // Hash(tags): an object as it is, an empty array or string as {}.
    let tags = probe_field(audio, "tags");
    if tags {
        var v: u8[>..] = [];
        if is_json_object(tags) { rails_json_value(v, tags); }
        else {
            let text, is_text = json::as_string(tags);
            match tags.val {
                Arr a => { guard a.count == 0 else { error.append("can't convert Array into Hash"); return false; } },
                _ => { guard is_text && text.len == 0 else { error.append("can't convert the tags into Hash"); return false; } },
            }
            v.append("{}");
        }
        members.push(member_entry("tags", v));
    }
    return true;
}

// metadata.merge(extracted.merge(analyzed: true)), as Blob#analyze saves it: the stored members in
// their order, with the extracted value where a name is extracted again, then the new names.
fn merged_metadata(stored: const u8[:], extracted: const u8[][:]) -> u8[>..] {
    var entries: u8[][>..] = []; var used: bool[>..] = [];
    for entry in extracted { entries.push(str(entry)); used.push(false); }
    entries.push(member_entry("analyzed", "true")); used.push(false);
    var out: u8[>..] = []; out.push('{');
    var first = true;
    var text: u8[>..] = []; text.append(stored);
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let root, parse_error = json::parse(text, nodes, strings);
    if root && is_json_object(root) {
        json::each(root) { member =>
            if !first { out.push(','); } first = false;
            rails_json_string(out, member.key); out.push(':');
            var replaced = false;
            for entry, i in entries {
                let at = find(entry, "\x00");
                if !replaced && !used[i] && entry[..at] == member.key { out.append(entry[at + 1..]); used[i] = true; replaced = true; }
            }
            if !replaced { rails_json_value(out, member); }
        };
    }
    for entry, i in entries {
        let at = find(entry, "\x00");
        if !used[i] { if !first { out.push(','); } first = false; rails_json_string(out, entry[..at]); out.push(':'); out.append(entry[at + 1..]); }
    }
    out.push('}');
    return out;
}
