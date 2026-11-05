namespace campfire;
import std;
import html5_entities;

// What Rails stores as a rich text body. ActionText::Content.new(html).to_html is the HTML, stripped,
// parsed as a fragment in a <body> by Nokogiri's HTML5 parser (gumbo, scripting off, no quirks),
// its attachments canonicalized (action-text-attachment emptied, a gallery's div stripped of its
// attributes, action-text-markdown unwrapped) and written back by Nokogiri's HTML5 serializer; and
// assigning RichText#body does that twice, as the serialized attribute's cast is
// deserialize(serialize(value)) (ActiveModel::Type::Helpers::Mutable) and the save serializes the
// Content that gives. The second pass changes what the first can't keep: a <pre>'s leading newline
// is dropped again, a CR from &#13; becomes a LF, text left at either end is stripped. Rails doesn't
// sanitize what it stores; the presentation sanitizes when it renders.
//
// The tokenizer is the WHATWG one, named character references and script data escapes included.
// The tree builder follows the "in body" rules and those of tables, select, template and foreign
// (SVG and MathML) content, with the adoption agency, active formatting reconstruction and foster
// parenting. False, with nothing written, past gumbo's limits, where Nokogiri raises (and Rails
// answers 500, storing nothing): more than 400 open elements, or 400 attributes on one. Malformed
// UTF-8, which Rails refuses too (String#strip raises), is read with each bad byte as U+FFFD.
fn action_text_html(out: u8[>..]&, html: const u8[:]) -> bool {
    var first: u8[>..] = [];
    let ok, settled = action_text_pass(first,html);
    if !ok { return false; }
    if settled { out.append(first); return true; }
    let again, done = action_text_pass(out,first);
    return again;
}

// One ActionText::Content.new(html).to_html, and whether a second would give the same: when it's
// plain text, or the HTML came back as it was.
fn action_text_pass(out: u8[>..]&, html: const u8[:]) -> bool, bool {
    // String#strip: ASCII whitespace and NUL at either end.
    var start: i64 = 0; var end = html.len;
    while start < end && h5_strip_space(html[start]) { start += 1; }
    while end > start && h5_strip_space(html[end-1]) { end -= 1; }
    // The input stream drops a byte order mark.
    var marked = false;
    if end - start >= 3 && html[start..start+3] == "\xEF\xBB\xBF" { start += 3; marked = true; }
    let source = html[start..end];
    // Plain text without markup, references, CRs, NULs or broken UTF-8 is one text node.
    var plain = true; var high = false;
    for c in source {
        if c == '<' || c == '&' || c == '\r' || c == 0 { plain = false; break; }
        if c >= 0x80 { high = true; }
    }
    if plain && (!high || h5_valid_utf8(source)) { h5_text(out,source); return true, !marked; }
    // The input stream: CR LF and CR become LF, malformed UTF-8 U+FFFD.
    var src: u8[>..] = [];
    var i: i64 = 0;
    while i < source.len {
        let c = source[i];
        if c == '\r' { src.push('\n'); i += 1; if i < source.len && source[i] == '\n' { i += 1; } continue; }
        if c < 0x80 { src.push(c); i += 1; continue; }
        let size = h5_utf8_size(source,i);
        if size == 0 { src.append("\xEF\xBF\xBD"); i += 1; continue; }
        src.append(source[i..i+size]); i += size;
    }
    let begin = out.len;
    if !html5_fragment(out,src) { return false, true; }
    return true, !marked && out[begin..] == source;
}

fn h5_strip_space(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == 11 || c == 12 || c == '\r' || c == 0; }

// The length of the well-formed UTF-8 sequence at s[i], or 0.
fn h5_utf8_size(s: const u8[:], i: i64) -> i64 {
    let c = s[i];
    var size: i64 = 0; var low: u8 = 0x80; var high: u8 = 0xBF;
    if c >= 0xC2 && c <= 0xDF { size = 2; }
    else if c >= 0xE0 && c <= 0xEF { size = 3; if c == 0xE0 { low = 0xA0; } if c == 0xED { high = 0x9F; } }
    else if c >= 0xF0 && c <= 0xF4 { size = 4; if c == 0xF0 { low = 0x90; } if c == 0xF4 { high = 0x8F; } }
    else { return 0; }
    if i + size > s.len { return 0; }
    if s[i+1] < low || s[i+1] > high { return 0; }
    for k in size - 2 { let b = s[i+2+k]; if b < 0x80 || b > 0xBF { return 0; } }
    return size;
}

fn h5_valid_utf8(s: const u8[:]) -> bool {
    var i: i64 = 0;
    while i < s.len {
        if s[i] < 0x80 { i += 1; continue; }
        let size = h5_utf8_size(s,i);
        if size == 0 { return false; }
        i += size;
    }
    return true;
}

// The serializer's text escaping: &, <, > and the no-break space.
fn h5_text(out: u8[>..]&, text: const u8[:]) {
    var i: i64 = 0;
    while i < text.len {
        let c = text[i];
        if c == '&' { out.append("&amp;"); } else if c == '<' { out.append("&lt;"); } else if c == '>' { out.append("&gt;"); }
        else if c == 0xC2 && i + 1 < text.len && text[i+1] == 0xA0 { out.append("&nbsp;"); i += 1; }
        else { out.push(c); }
        i += 1;
    }
}

// An attribute value's: &, ", <, > and the no-break space.
fn h5_attribute(out: u8[>..]&, text: const u8[:]) {
    var i: i64 = 0;
    while i < text.len {
        let c = text[i];
        if c == '&' { out.append("&amp;"); } else if c == '"' { out.append("&quot;"); }
        else if c == '<' { out.append("&lt;"); } else if c == '>' { out.append("&gt;"); }
        else if c == 0xC2 && i + 1 < text.len && text[i+1] == 0xA0 { out.append("&nbsp;"); i += 1; }
        else { out.push(c); }
        i += 1;
    }
}

// Whether name is one of set's "|"-separated names.
fn h5_in(name: const u8[:], set: const u8[:]) -> bool {
    var i: i64 = 1;
    while i < set.len {
        var j = i; while j < set.len && set[j] != '|' { j += 1; }
        if j - i == name.len && set[i..j] == name { return true; }
        i = j + 1;
    }
    return false;
}

fn h5_alpha(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
fn h5_alnum(c: u8) -> bool { return h5_alpha(c) || (c >= '0' && c <= '9'); }
fn h5_space(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == 12; }
fn h5_lower(c: u8) -> u8 { return if c >= 'A' && c <= 'Z' { c + 32 } else { c }; }

// The entry of the named character reference name (with its ";" if it has one), or -1.
fn h5_entity(name: const u8[:]) -> i64 {
    var low: i64 = 0; var high: i64 = H5_ENTITY_COUNT - 1;
    while low <= high {
        let mid = (low + high) / 2;
        let at = H5_ENTITY_AT[mid] as i64;
        var k: i64 = 0; var order: i64 = 0;
        while true {
            let e = H5_ENTITY_DATA[at+k];
            if k == name.len { order = if e == 0 { 0 } else { -1 }; break; }
            if e == 0 { order = 1; break; }
            if name[k] != e { order = if name[k] < e { -1 } else { 1 }; break; }
            k += 1;
        }
        if order == 0 { return mid; }
        if order < 0 { high = mid - 1; } else { low = mid + 1; }
    }
    return -1;
}

fn h5_entity_value(entry: i64) -> const u8[:] {
    let at = H5_ENTITY_AT[entry] as i64; let end = H5_ENTITY_AT[entry+1] as i64;
    let zero = find(H5_ENTITY_DATA[at..end],"\x00");
    return H5_ENTITY_DATA[at+zero+1..end];
}

fn h5_push_utf8(out: u8[>..<]&, c: i64) {
    if c < 0x80 { out.push(c as u8); }
    else if c < 0x800 { out.push((0xC0 | (c >> 6)) as u8); out.push((0x80 | (c & 63)) as u8); }
    else if c < 0x10000 { out.push((0xE0 | (c >> 12)) as u8); out.push((0x80 | ((c >> 6) & 63)) as u8); out.push((0x80 | (c & 63)) as u8); }
    else { out.push((0xF0 | (c >> 18)) as u8); out.push((0x80 | ((c >> 12) & 63)) as u8); out.push((0x80 | ((c >> 6) & 63)) as u8); out.push((0x80 | (c & 63)) as u8); }
}

// A numeric character reference's character: NUL, a surrogate or past U+10FFFF is U+FFFD, and C1
// controls are read as windows-1252.
fn h5_numeric(c: i64) -> i64 {
    if c == 0 || c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF) { return 0xFFFD; }
    if c >= 0x80 && c <= 0x9F {
        let w: i32[32] = [0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
                          0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178];
        return w[c - 0x80] as i64;
    }
    return c;
}

struct H5Node { kind: i64 = 0, ns: i64 = 0, parent: i64 = -1, first: i64 = -1, last: i64 = -1, next: i64 = -1, prev: i64 = -1, at: i64 = 0, len: i64 = 0, attrs: i64 = 0, nattrs: i64 = 0 }
struct H5Attr { name_at: i64 = 0, name_len: i64 = 0, value_at: i64 = 0, value_len: i64 = 0 }

let H5_ELEMENT = 1;
let H5_TEXT = 2;
let H5_COMMENT = 3;
let H5_CDATA = 4;

let NS_HTML = 0;
let NS_SVG = 1;
let NS_MATH = 2;

// Tokens
let T_TEXT = 0;
let T_START = 1;
let T_END = 2;
let T_COMMENT = 3;
let T_EOF = 4;
let T_CDATA = 5;

// Tokenizer content states
let TS_DATA = 0;
let TS_RCDATA = 1;
let TS_RAWTEXT = 2;
let TS_SCRIPT = 3;
let TS_PLAINTEXT = 4;

// Insertion modes
let M_BODY = 0;
let M_TABLE = 1;
let M_TABLE_TEXT = 2;
let M_CAPTION = 3;
let M_COLGROUP = 4;
let M_TBODY = 5;
let M_ROW = 6;
let M_CELL = 7;
let M_SELECT = 8;
let M_SELECT_TABLE = 9;
let M_TEMPLATE = 10;
let M_TEXT = 11;

// Scopes
let SC_DEFAULT = 0;
let SC_LIST = 1;
let SC_BUTTON = 2;
let SC_TABLE = 3;
let SC_SELECT = 4;

let H5_SPECIAL = "|address|applet|area|article|aside|base|basefont|bgsound|blockquote|body|br|button|caption|center|col|colgroup|dd|details|dir|div|dl|dt|embed|fieldset|figcaption|figure|footer|form|frame|frameset|h1|h2|h3|h4|h5|h6|head|header|hgroup|hr|html|iframe|img|input|keygen|li|link|listing|main|marquee|menu|meta|nav|noembed|noframes|noscript|object|ol|p|param|plaintext|pre|script|search|section|select|source|style|summary|table|tbody|td|template|textarea|tfoot|th|thead|title|tr|track|ul|wbr|xmp|";
let H5_VOID = "|area|base|basefont|bgsound|br|col|embed|frame|hr|img|input|keygen|link|meta|param|source|track|wbr|";
let H5_RAW = "|style|script|xmp|iframe|noembed|noframes|plaintext|";
let H5_FORMATTING = "|a|b|big|code|em|font|i|nobr|s|small|strike|strong|tt|u|";
let H5_IMPLIED = "|dd|dt|li|optgroup|option|p|rb|rp|rt|rtc|";
let H5_IMPLIED_ALL = "|caption|colgroup|dd|dt|li|optgroup|option|p|rb|rp|rt|rtc|tbody|td|tfoot|th|thead|tr|";
let H5_CLOSES_P = "|address|article|aside|blockquote|center|details|dialog|dir|div|dl|fieldset|figcaption|figure|footer|header|hgroup|main|menu|nav|ol|p|search|section|summary|ul|";
let H5_BLOCK_END = "|address|article|aside|blockquote|button|center|details|dialog|dir|div|dl|fieldset|figcaption|figure|footer|header|hgroup|listing|main|menu|nav|ol|pre|search|section|summary|ul|";
let H5_HEADINGS = "|h1|h2|h3|h4|h5|h6|";
let H5_BREAKOUT = "|b|big|blockquote|body|br|center|code|dd|div|dl|dt|em|embed|h1|h2|h3|h4|h5|h6|head|hr|i|img|li|listing|menu|meta|nobr|ol|p|pre|ruby|s|small|span|strong|strike|sub|sup|table|tt|u|ul|var|";
let H5_SVG_TAGS = "|altGlyph|altGlyphDef|altGlyphItem|animateColor|animateMotion|animateTransform|clipPath|feBlend|feColorMatrix|feComponentTransfer|feComposite|feConvolveMatrix|feDiffuseLighting|feDisplacementMap|feDistantLight|feDropShadow|feFlood|feFuncA|feFuncB|feFuncG|feFuncR|feGaussianBlur|feImage|feMerge|feMergeNode|feMorphology|feOffset|fePointLight|feSpecularLighting|feSpotLight|feTile|feTurbulence|foreignObject|glyphRef|linearGradient|radialGradient|textPath|";
let H5_SVG_ATTRIBUTES = "|attributeName|attributeType|baseFrequency|baseProfile|calcMode|clipPathUnits|diffuseConstant|edgeMode|filterUnits|glyphRef|gradientTransform|gradientUnits|kernelMatrix|kernelUnitLength|keyPoints|keySplines|keyTimes|lengthAdjust|limitingConeAngle|markerHeight|markerUnits|markerWidth|maskContentUnits|maskUnits|numOctaves|pathLength|patternContentUnits|patternTransform|patternUnits|pointsAtX|pointsAtY|pointsAtZ|preserveAlpha|preserveAspectRatio|primitiveUnits|refX|refY|repeatCount|repeatDur|requiredExtensions|requiredFeatures|specularConstant|specularExponent|spreadMethod|startOffset|stdDeviation|stitchTiles|surfaceScale|systemLanguage|tableValues|targetX|targetY|textLength|viewBox|viewTarget|xChannelSelector|yChannelSelector|zoomAndPan|";

// The mixed-case spelling in set of a lowercase name, or the name.
fn h5_case(name: const u8[:], set: const u8[:]) -> const u8[:] {
    var i: i64 = 1;
    while i < set.len {
        var j = i; while j < set.len && set[j] != '|' { j += 1; }
        if j - i == name.len {
            var same = true;
            for k in name.len { if h5_lower(set[i+k]) != name[k] { same = false; break; } }
            if same { return set[i..j]; }
        }
        i = j + 1;
    }
    return name;
}

// The parse and canonicalization of src (already stripped and normalized), serialized into out.
fn html5_fragment(out: u8[>..]&, src: const u8[:]) -> bool {
    var nodes: H5Node[>..] = [];
    var attrs: H5Attr[>..] = [];
    var bytes: u8[>..] = [];
    var stack: i64[>..<] = [];
    var afe: i64[>..<] = [];
    var tmodes: i64[>..<] = [];
    var tb: u8[>..<] = [];
    var ta: H5Attr[>..<] = [];
    var pending: u8[>..<] = [];
    let n = src.len;
    var pos: i64 = 0;
    var tstate = TS_DATA;
    var last_start: u8[..16] = "";
    var tkind = T_EOF; var tself = false; var tname_at: i64 = 0; var tname_len: i64 = 0; var tstart: i64 = 0;
    var mode = M_BODY; var original = M_BODY; var foster = false; var form: i64 = -1; var skip_lf = false;
    // gumbo's max_tree_depth and max_attributes
    let LIMIT = 400; var too_many = false;

    bytes.append("html");
    nodes.push(H5Node { kind: H5_ELEMENT, ns: NS_HTML, at: 0, len: 4 });
    stack.push(0);

    // --- The tree ---
    fn nname(i: i64) -> const u8[:] { let at = nodes[i].at; return bytes[at..at+nodes[i].len]; }
    fn tname() -> const u8[:] { return tb[tname_at..tname_at+tname_len]; }
    fn text() -> const u8[:] { return tb[tstart..]; }
    fn is_html(i: i64, name: const u8[:]) -> bool { return nodes[i].kind == H5_ELEMENT && nodes[i].ns == NS_HTML && nname(i) == name; }
    fn html_in(i: i64, set: const u8[:]) -> bool { return nodes[i].kind == H5_ELEMENT && nodes[i].ns == NS_HTML && h5_in(nname(i),set); }
    fn cur() -> i64 { return stack[stack.len-1]; }
    fn attr_value(i: i64, name: const u8[:]) -> const u8[:], bool {
        for k in nodes[i].nattrs {
            let a = attrs[nodes[i].attrs+k];
            if bytes[a.name_at..a.name_at+a.name_len] == name { return bytes[a.value_at..a.value_at+a.value_len], true; }
        }
        return bytes[0..0], false;
    }

    fn special(i: i64) -> bool {
        let ns = nodes[i].ns;
        if ns == NS_HTML { return h5_in(nname(i),H5_SPECIAL); }
        if ns == NS_MATH { return h5_in(nname(i),"|mi|mo|mn|ms|mtext|annotation-xml|"); }
        return h5_in(nname(i),"|foreignObject|desc|title|");
    }
    fn mathml_text_point(i: i64) -> bool { return nodes[i].ns == NS_MATH && h5_in(nname(i),"|mi|mo|mn|ms|mtext|"); }
    fn html_point(i: i64) -> bool {
        if nodes[i].ns == NS_SVG { return h5_in(nname(i),"|foreignObject|desc|title|"); }
        if nodes[i].ns == NS_MATH && nname(i) == "annotation-xml" {
            let encoding, has = attr_value(i,"encoding");
            if !has { return false; }
            var lower: u8[>..] = []; for c in encoding { lower.push(h5_lower(c)); }
            return lower == "text/html" || lower == "application/xhtml+xml";
        }
        return false;
    }
    fn boundary(i: i64, scope: i64) -> bool {
        let ns = nodes[i].ns; let name = nname(i);
        if ns == NS_HTML {
            if scope == SC_TABLE { return name == "html" || name == "table" || name == "template"; }
            if scope == SC_SELECT { return !(name == "optgroup" || name == "option"); }
            if h5_in(name,"|applet|caption|html|table|td|th|marquee|object|template|") { return true; }
            if scope == SC_LIST { return name == "ol" || name == "ul"; }
            if scope == SC_BUTTON { return name == "button"; }
            return false;
        }
        if scope == SC_TABLE { return false; }
        if scope == SC_SELECT { return true; }
        if ns == NS_MATH { return h5_in(name,"|mi|mo|mn|ms|mtext|annotation-xml|"); }
        return h5_in(name,"|foreignObject|desc|title|");
    }
    fn in_scope(name: const u8[:], scope: i64) -> bool {
        var k = stack.len - 1;
        while k >= 0 { let e = stack[k]; if is_html(e,name) { return true; } if boundary(e,scope) { return false; } k -= 1; }
        return false;
    }
    fn set_in_scope(set: const u8[:], scope: i64) -> bool {
        var k = stack.len - 1;
        while k >= 0 { let e = stack[k]; if html_in(e,set) { return true; } if boundary(e,scope) { return false; } k -= 1; }
        return false;
    }
    fn node_in_scope(node: i64, scope: i64) -> bool {
        var k = stack.len - 1;
        while k >= 0 { let e = stack[k]; if e == node { return true; } if boundary(e,scope) { return false; } k -= 1; }
        return false;
    }
    fn stack_index(node: i64) -> i64 { var k = stack.len - 1; while k >= 0 { if stack[k] == node { return k; } k -= 1; } return -1; }
    fn afe_index(node: i64) -> i64 { var k = afe.len - 1; while k >= 0 { if afe[k] == node { return k; } k -= 1; } return -1; }
    fn stack_remove(k: i64) { var j = k; while j + 1 < stack.len { stack[j] = stack[j+1]; j += 1; } let gone = stack.pop(); }
    fn stack_insert(k: i64, node: i64) { stack.push(node); var j = stack.len - 1; while j > k { stack[j] = stack[j-1]; j -= 1; } stack[k] = node; }
    fn afe_remove(k: i64) { var j = k; while j + 1 < afe.len { afe[j] = afe[j+1]; j += 1; } let gone = afe.pop(); }
    fn afe_insert(k: i64, node: i64) { afe.push(node); var j = afe.len - 1; while j > k { afe[j] = afe[j-1]; j -= 1; } afe[k] = node; }
    fn template_open() -> bool { for e in stack { if is_html(e,"template") { return true; } } return false; }
    fn pop_until(name: const u8[:]) { while stack.len > 1 { let e = stack.pop(); if is_html(e,name) { return; } } }
    fn pop_until_set(set: const u8[:]) { while stack.len > 1 { let e = stack.pop(); if html_in(e,set) { return; } } }
    fn implied(except: const u8[:]) { while stack.len > 1 && html_in(cur(),H5_IMPLIED) && nname(cur()) != except { let e = stack.pop(); } }
    fn implied_all() { while stack.len > 1 && html_in(cur(),H5_IMPLIED_ALL) { let e = stack.pop(); } }
    fn close_p() { implied("p"); pop_until("p"); }
    fn clear_to_marker() { while afe.len > 0 { let e = afe.pop(); if e < 0 { return; } } }
    fn clear_to(set: const u8[:]) { while stack.len > 1 && !html_in(cur(),set) { let e = stack.pop(); } }

    fn detach(node: i64) {
        let p = nodes[node].parent;
        if p < 0 { return; }
        let prev = nodes[node].prev; let next = nodes[node].next;
        if prev >= 0 { nodes[prev].next = next; } else { nodes[p].first = next; }
        if next >= 0 { nodes[next].prev = prev; } else { nodes[p].last = prev; }
        nodes[node].parent = -1; nodes[node].prev = -1; nodes[node].next = -1;
    }
    // Inserts node into parent before `before` (at the end for -1).
    fn insert_before(parent: i64, node: i64, before: i64) {
        nodes[node].parent = parent;
        if before < 0 {
            let last = nodes[parent].last;
            nodes[node].prev = last; nodes[node].next = -1;
            if last >= 0 { nodes[last].next = node; } else { nodes[parent].first = node; }
            nodes[parent].last = node;
        } else {
            let prev = nodes[before].prev;
            nodes[node].prev = prev; nodes[node].next = before; nodes[before].prev = node;
            if prev >= 0 { nodes[prev].next = node; } else { nodes[parent].first = node; }
        }
    }
    // The appropriate place for inserting a node: a parent, and the node to go before (or -1).
    fn place(target_override: i64) -> i64, i64 {
        let target = if target_override >= 0 { target_override } else { cur() };
        if foster && html_in(target,"|table|tbody|tfoot|thead|tr|") {
            var table: i64 = -1; var template: i64 = -1;
            var k = stack.len - 1;
            while k >= 0 {
                if table < 0 && is_html(stack[k],"table") { table = k; }
                if template < 0 && is_html(stack[k],"template") { template = k; }
                k -= 1;
            }
            if template >= 0 && (table < 0 || template > table) { return stack[template], -1; }
            if table < 0 { return stack[0], -1; }
            let t = stack[table];
            if nodes[t].parent >= 0 { return nodes[t].parent, t; }
            return stack[table-1], -1;
        }
        return target, -1;
    }
    fn insert_node(node: i64, target_override: i64) { let parent, before = place(target_override); insert_before(parent,node,before); }

    fn append_text(node: i64, s: const u8[:]) {
        if nodes[node].at + nodes[node].len != bytes.len {
            let at = nodes[node].at; let len = nodes[node].len;
            nodes[node].at = bytes.len;
            for k in len { bytes.push(bytes[at+k]); }
        }
        bytes.append(s); nodes[node].len += s.len;
    }
    fn insert_text(s: const u8[:]) { insert_run(s,H5_TEXT); }
    // Characters join the text before them, which is written as a CDATA section when the last of its
    // characters other than spaces came from one (gumbo's text buffer takes its last token's kind).
    fn insert_run(s: const u8[:], kind: i64) {
        if s.len == 0 { return; }
        let parent, before = place(-1);
        let neighbour = if before < 0 { nodes[parent].last } else { nodes[before].prev };
        if neighbour >= 0 && (nodes[neighbour].kind == H5_TEXT || nodes[neighbour].kind == H5_CDATA) {
            var sets = kind == H5_CDATA;
            if !sets { for c in s { if !h5_space(c) { sets = true; break; } } }
            if sets { nodes[neighbour].kind = kind; }
            append_text(neighbour,s); return;
        }
        let node = nodes.len;
        nodes.push(H5Node { kind: kind, at: bytes.len, len: s.len });
        bytes.append(s);
        insert_before(parent,node,before);
    }
    // Text with each NUL dropped (in HTML content) or made U+FFFD (in foreign content).
    fn insert_chars(s: const u8[:], nul_replaced: bool) {
        var begin: i64 = 0;
        for c, k in s {
            if c != 0 { continue; }
            insert_text(s[begin..k]);
            if nul_replaced { insert_text("\xEF\xBF\xBD"); }
            begin = k + 1;
        }
        insert_text(s[begin..]);
    }
    fn insert_comment() {
        let node = nodes.len;
        nodes.push(H5Node { kind: H5_COMMENT, at: bytes.len, len: tb.len });
        bytes.append(tb[..]);
        insert_node(node,-1);
    }
    fn clone_node(old: i64) -> i64 {
        let node = nodes.len;
        nodes.push(H5Node { kind: H5_ELEMENT, ns: nodes[old].ns, at: nodes[old].at, len: nodes[old].len, attrs: nodes[old].attrs, nattrs: nodes[old].nattrs });
        return node;
    }
    // An element named name, with the token's attributes (adjusted for ns) when with_attributes.
    fn element(name: const u8[:], ns: i64, with_attributes: bool) -> i64 {
        let node = nodes.len;
        let at = bytes.len;
        if ns == NS_SVG { bytes.append(h5_case(name,H5_SVG_TAGS)); } else { bytes.append(name); }
        let len = bytes.len - at;
        let first = attrs.len;
        if with_attributes {
            for a in ta {
                let raw = tb[a.name_at..a.name_at+a.name_len];
                let name_at = bytes.len;
                if ns == NS_SVG { bytes.append(h5_case(raw,H5_SVG_ATTRIBUTES)); }
                else if ns == NS_MATH && raw == "definitionurl" { bytes.append("definitionURL"); }
                else { bytes.append(raw); }
                let name_len = bytes.len - name_at;
                let value_at = bytes.len;
                bytes.append(tb[a.value_at..a.value_at+a.value_len]);
                attrs.push(H5Attr { name_at: name_at, name_len: name_len, value_at: value_at, value_len: a.value_len });
            }
        }
        nodes.push(H5Node { kind: H5_ELEMENT, ns: ns, at: at, len: len, attrs: first, nattrs: attrs.len - first });
        return node;
    }
    fn insert_element(name: const u8[:], ns: i64, with_attributes: bool) -> i64 {
        let node = element(name,ns,with_attributes);
        insert_node(node,-1);
        stack.push(node);
        return node;
    }
    fn insert_token(ns: i64) -> i64 { return insert_element(tname(),ns,true); }
    fn same_element(a: i64, b: i64) -> bool {
        if nodes[a].ns != nodes[b].ns || nname(a) != nname(b) || nodes[a].nattrs != nodes[b].nattrs { return false; }
        for k in nodes[a].nattrs {
            let x = attrs[nodes[a].attrs+k];
            let value, has = attr_value(b,bytes[x.name_at..x.name_at+x.name_len]);
            if !has || value != bytes[x.value_at..x.value_at+x.value_len] { return false; }
        }
        return true;
    }
    fn push_formatting(node: i64) {
        var count: i64 = 0; var earliest: i64 = -1; var k = afe.len - 1;
        while k >= 0 && afe[k] >= 0 { if same_element(afe[k],node) { count += 1; earliest = k; } k -= 1; }
        if count >= 3 { afe_remove(earliest); }
        afe.push(node);
    }
    fn reconstruct() {
        if afe.len == 0 { return; }
        var k = afe.len - 1;
        if afe[k] < 0 || stack_index(afe[k]) >= 0 { return; }
        while k > 0 && afe[k-1] >= 0 && stack_index(afe[k-1]) < 0 { k -= 1; }
        while k < afe.len {
            let node = clone_node(afe[k]);
            insert_node(node,-1); stack.push(node);
            afe[k] = node; k += 1;
        }
    }
    // The adoption agency algorithm; true when the token is to be handled as any other end tag.
    fn adoption(subject: const u8[:]) -> bool {
        let current = cur();
        if is_html(current,subject) && afe_index(current) < 0 { let e = stack.pop(); return false; }
        for outer in 8 {
            var fi: i64 = -1; var k = afe.len - 1;
            while k >= 0 && afe[k] >= 0 { if is_html(afe[k],subject) { fi = k; break; } k -= 1; }
            if fi < 0 { return true; }
            let formatting = afe[fi];
            let si = stack_index(formatting);
            if si < 0 { afe_remove(fi); return false; }
            if !node_in_scope(formatting,SC_DEFAULT) { return false; }
            var furthest: i64 = -1; var j = si + 1;
            while j < stack.len { if special(stack[j]) { furthest = stack[j]; break; } j += 1; }
            if furthest < 0 {
                while stack.len > si { let e = stack.pop(); }
                afe_remove(fi); return false;
            }
            let common = stack[si-1];
            var bookmark = fi;
            var node_i = stack_index(furthest); var last = furthest;
            var inner: i64 = 0;
            while true {
                inner += 1;
                node_i -= 1;
                var node = stack[node_i];
                if node == formatting { break; }
                var ai = afe_index(node);
                if inner > 3 && ai >= 0 { afe_remove(ai); if ai < bookmark { bookmark -= 1; } ai = -1; }
                if ai < 0 { stack_remove(node_i); continue; }
                let copy = clone_node(node);
                afe[ai] = copy; stack[node_i] = copy; node = copy;
                if last == furthest { bookmark = ai + 1; }
                detach(last); insert_before(node,last,-1);
                last = node;
            }
            detach(last); insert_node(last,common);
            let copy = clone_node(formatting);
            while nodes[furthest].first >= 0 { let child = nodes[furthest].first; detach(child); insert_before(copy,child,-1); }
            insert_before(furthest,copy,-1);
            let at = afe_index(formatting);
            afe_remove(at); if at < bookmark { bookmark -= 1; }
            afe_insert(bookmark,copy);
            stack_remove(stack_index(formatting));
            stack_insert(stack_index(furthest)+1,copy);
        }
        return false;
    }
    fn any_other_end(name: const u8[:]) {
        var k = stack.len - 1;
        while k > 0 {
            let e = stack[k];
            if is_html(e,name) { implied(name); while stack.len > k { let x = stack.pop(); } return; }
            if special(e) { return; }
            k -= 1;
        }
    }
    fn reset_mode() {
        var k = stack.len - 1;
        while k > 0 {
            let e = stack[k];
            if nodes[e].ns == NS_HTML {
                let name = nname(e);
                if name == "select" {
                    var a = k - 1;
                    while a > 0 { if is_html(stack[a],"template") { break; } if is_html(stack[a],"table") { mode = M_SELECT_TABLE; return; } a -= 1; }
                    mode = M_SELECT; return;
                }
                if name == "td" || name == "th" { mode = M_CELL; return; }
                if name == "tr" { mode = M_ROW; return; }
                if name == "tbody" || name == "thead" || name == "tfoot" { mode = M_TBODY; return; }
                if name == "caption" { mode = M_CAPTION; return; }
                if name == "colgroup" { mode = M_COLGROUP; return; }
                if name == "table" { mode = M_TABLE; return; }
                if name == "template" { mode = tmodes[tmodes.len-1]; return; }
                if name == "body" { mode = M_BODY; return; }
            }
            k -= 1;
        }
        mode = M_BODY;
    }
    fn generic_text(state: i64) {
        let e = insert_token(NS_HTML);
        tstate = state; last_start.clear(); format(last_start,tname()); original = mode; mode = M_TEXT;
    }
    fn template_start() { let e = insert_token(NS_HTML); afe.push(-1); mode = M_TEMPLATE; tmodes.push(M_TEMPLATE); }
    fn template_end() {
        if !template_open() { return; }
        implied_all(); pop_until("template"); clear_to_marker();
        let m = tmodes.pop(); reset_mode();
    }
    // Start tags handled by "in head" from the other modes: base, link, meta, title, style and the rest.
    fn head_start(name: const u8[:]) -> bool {
        if h5_in(name,"|base|basefont|bgsound|link|meta|") { let e = insert_token(NS_HTML); let x = stack.pop(); return true; }
        if name == "title" { generic_text(TS_RCDATA); return true; }
        if name == "noframes" || name == "style" { generic_text(TS_RAWTEXT); return true; }
        if name == "script" { generic_text(TS_SCRIPT); return true; }
        if name == "template" { template_start(); return true; }
        return false;
    }
    fn foreign_start(ns: i64) {
        let e = insert_token(ns);
        if tself { let x = stack.pop(); }
    }

    // --- Insertion modes ---
    fn in_body() -> bool {
        if tkind == T_TEXT {
            let s = text();
            var real = false; for c in s { if c != 0 { real = true; break; } }
            if real { reconstruct(); insert_chars(s,false); }
            return false;
        }
        if tkind == T_COMMENT { insert_comment(); return false; }
        if tkind == T_EOF { return false; }
        let name = tname();
        if tkind == T_START {
            if name == "html" || name == "body" || name == "frameset" { return false; }
            if head_start(name) { return false; }
            if h5_in(name,H5_CLOSES_P) {
                if in_scope("p",SC_BUTTON) { close_p(); }
                let e = insert_token(NS_HTML); return false;
            }
            if h5_in(name,H5_HEADINGS) {
                if in_scope("p",SC_BUTTON) { close_p(); }
                if html_in(cur(),H5_HEADINGS) { let x = stack.pop(); }
                let e = insert_token(NS_HTML); return false;
            }
            if name == "pre" || name == "listing" {
                if in_scope("p",SC_BUTTON) { close_p(); }
                let e = insert_token(NS_HTML); skip_lf = true; return false;
            }
            if name == "form" {
                let templated = template_open();
                if form >= 0 && !templated { return false; }
                if in_scope("p",SC_BUTTON) { close_p(); }
                let e = insert_token(NS_HTML);
                if !templated { form = e; }
                return false;
            }
            if name == "li" || name == "dd" || name == "dt" {
                var k = stack.len - 1;
                while k > 0 {
                    let e = stack[k];
                    if name == "li" && is_html(e,"li") { implied("li"); pop_until("li"); break; }
                    if name != "li" && (is_html(e,"dd") || is_html(e,"dt")) { let which = nname(e); implied(which); pop_until_set("|dd|dt|"); break; }
                    if special(e) && !html_in(e,"|address|div|p|") { break; }
                    k -= 1;
                }
                if in_scope("p",SC_BUTTON) { close_p(); }
                let e = insert_token(NS_HTML); return false;
            }
            if name == "plaintext" {
                if in_scope("p",SC_BUTTON) { close_p(); }
                let e = insert_token(NS_HTML); tstate = TS_PLAINTEXT; return false;
            }
            if name == "button" {
                if in_scope("button",SC_DEFAULT) { implied(""); pop_until("button"); }
                reconstruct(); let e = insert_token(NS_HTML); return false;
            }
            if name == "a" {
                var k = afe.len - 1; var found: i64 = -1;
                while k >= 0 && afe[k] >= 0 { if is_html(afe[k],"a") { found = afe[k]; break; } k -= 1; }
                if found >= 0 {
                    if adoption("a") { any_other_end("a"); }
                    let ai = afe_index(found); if ai >= 0 { afe_remove(ai); }
                    let si = stack_index(found); if si >= 0 { stack_remove(si); }
                }
                reconstruct(); let e = insert_token(NS_HTML); push_formatting(e); return false;
            }
            if name == "nobr" {
                reconstruct();
                if in_scope("nobr",SC_DEFAULT) { if adoption("nobr") { any_other_end("nobr"); } reconstruct(); }
                let e = insert_token(NS_HTML); push_formatting(e); return false;
            }
            if h5_in(name,H5_FORMATTING) { reconstruct(); let e = insert_token(NS_HTML); push_formatting(e); return false; }
            if name == "applet" || name == "marquee" || name == "object" { reconstruct(); let e = insert_token(NS_HTML); afe.push(-1); return false; }
            if name == "table" {
                if in_scope("p",SC_BUTTON) { close_p(); }
                let e = insert_token(NS_HTML); mode = M_TABLE; return false;
            }
            if h5_in(name,"|area|br|embed|img|keygen|wbr|input|") { reconstruct(); let e = insert_token(NS_HTML); let x = stack.pop(); return false; }
            if h5_in(name,"|param|source|track|") { let e = insert_token(NS_HTML); let x = stack.pop(); return false; }
            if name == "hr" {
                if in_scope("p",SC_BUTTON) { close_p(); }
                let e = insert_token(NS_HTML); let x = stack.pop(); return false;
            }
            if name == "image" { tname_at = tb.len; tb.append("img"); tname_len = 3; return true; }
            if name == "textarea" { generic_text(TS_RCDATA); skip_lf = true; return false; }
            if name == "xmp" {
                if in_scope("p",SC_BUTTON) { close_p(); }
                reconstruct(); generic_text(TS_RAWTEXT); return false;
            }
            if name == "iframe" || name == "noembed" { generic_text(TS_RAWTEXT); return false; }
            if name == "select" {
                reconstruct(); let e = insert_token(NS_HTML);
                mode = if mode == M_TABLE || mode == M_CAPTION || mode == M_TBODY || mode == M_ROW || mode == M_CELL { M_SELECT_TABLE } else { M_SELECT };
                return false;
            }
            if name == "optgroup" || name == "option" {
                if is_html(cur(),"option") { let x = stack.pop(); }
                reconstruct(); let e = insert_token(NS_HTML); return false;
            }
            if name == "rb" || name == "rtc" {
                if in_scope("ruby",SC_DEFAULT) { implied(""); }
                let e = insert_token(NS_HTML); return false;
            }
            if name == "rp" || name == "rt" {
                if in_scope("ruby",SC_DEFAULT) { implied("rtc"); }
                let e = insert_token(NS_HTML); return false;
            }
            if name == "math" { reconstruct(); foreign_start(NS_MATH); return false; }
            if name == "svg" { reconstruct(); foreign_start(NS_SVG); return false; }
            if h5_in(name,"|caption|col|colgroup|frame|head|tbody|td|tfoot|th|thead|tr|") { return false; }
            reconstruct(); let e = insert_token(NS_HTML); return false;
        }
        // End tags
        if name == "template" { template_end(); return false; }
        if name == "body" || name == "html" { return false; }
        if h5_in(name,H5_BLOCK_END) {
            if !in_scope(name,SC_DEFAULT) { return false; }
            implied(""); pop_until(name); return false;
        }
        if name == "form" {
            if !template_open() {
                let node = form; form = -1;
                if node < 0 || !node_in_scope(node,SC_DEFAULT) { return false; }
                implied("");
                let k = stack_index(node); if k >= 0 { stack_remove(k); }
                return false;
            }
            if !in_scope("form",SC_DEFAULT) { return false; }
            implied(""); pop_until("form"); return false;
        }
        if name == "p" {
            if !in_scope("p",SC_BUTTON) { let e = insert_element("p",NS_HTML,false); }
            close_p(); return false;
        }
        if name == "li" {
            if !in_scope("li",SC_LIST) { return false; }
            implied("li"); pop_until("li"); return false;
        }
        if name == "dd" || name == "dt" {
            if !in_scope(name,SC_DEFAULT) { return false; }
            implied(name); pop_until(name); return false;
        }
        if h5_in(name,H5_HEADINGS) {
            if !set_in_scope(H5_HEADINGS,SC_DEFAULT) { return false; }
            implied(""); pop_until_set(H5_HEADINGS); return false;
        }
        if h5_in(name,H5_FORMATTING) { if adoption(name) { any_other_end(name); } return false; }
        if name == "applet" || name == "marquee" || name == "object" {
            if !in_scope(name,SC_DEFAULT) { return false; }
            implied(""); pop_until(name); clear_to_marker(); return false;
        }
        if name == "br" { reconstruct(); let e = insert_element("br",NS_HTML,false); let x = stack.pop(); return false; }
        any_other_end(name); return false;
    }

    fn in_text() -> bool {
        if tkind == T_TEXT { insert_text(text()); return false; }
        if tkind == T_EOF { let x = stack.pop(); mode = original; return true; }
        if tkind == T_END { let x = stack.pop(); mode = original; }
        return false;
    }

    fn table_anything() -> bool { foster = true; let again = in_body(); foster = false; return again; }

    fn in_table() -> bool {
        if tkind == T_TEXT && html_in(cur(),"|table|tbody|template|tfoot|thead|tr|") {
            pending.clear(); original = mode; mode = M_TABLE_TEXT; return true;
        }
        if tkind == T_COMMENT { insert_comment(); return false; }
        if tkind == T_EOF { return in_body(); }
        if tkind == T_TEXT { return table_anything(); }
        let name = tname();
        if tkind == T_START {
            if name == "caption" { clear_to("|table|template|html|"); afe.push(-1); let e = insert_token(NS_HTML); mode = M_CAPTION; return false; }
            if name == "colgroup" { clear_to("|table|template|html|"); let e = insert_token(NS_HTML); mode = M_COLGROUP; return false; }
            if name == "col" { clear_to("|table|template|html|"); let e = insert_element("colgroup",NS_HTML,false); mode = M_COLGROUP; return true; }
            if name == "tbody" || name == "tfoot" || name == "thead" { clear_to("|table|template|html|"); let e = insert_token(NS_HTML); mode = M_TBODY; return false; }
            if name == "td" || name == "th" || name == "tr" { clear_to("|table|template|html|"); let e = insert_element("tbody",NS_HTML,false); mode = M_TBODY; return true; }
            if name == "table" {
                if !in_scope("table",SC_TABLE) { return false; }
                pop_until("table"); reset_mode(); return true;
            }
            if name == "style" || name == "script" || name == "template" { let handled = head_start(name); return false; }
            if name == "input" {
                let kind, has = attr_token("type");
                if has && h5_ascii_lower_eq(kind,"hidden") { let e = insert_token(NS_HTML); let x = stack.pop(); return false; }
                return table_anything();
            }
            if name == "form" {
                if template_open() || form >= 0 { return false; }
                let e = insert_token(NS_HTML); form = e; let x = stack.pop(); return false;
            }
            return table_anything();
        }
        if name == "table" {
            if !in_scope("table",SC_TABLE) { return false; }
            pop_until("table"); reset_mode(); return false;
        }
        if h5_in(name,"|body|caption|col|colgroup|html|tbody|td|tfoot|th|thead|tr|") { return false; }
        if name == "template" { template_end(); return false; }
        return table_anything();
    }
    fn attr_token(name: const u8[:]) -> const u8[:], bool {
        for a in ta { if tb[a.name_at..a.name_at+a.name_len] == name { return tb[a.value_at..a.value_at+a.value_len], true; } }
        return tb[0..0], false;
    }

    fn in_table_text() -> bool {
        if tkind == T_TEXT { for c in text() { if c != 0 { pending.push(c); } } return false; }
        var spaces = true; for c in pending { if !h5_space(c) { spaces = false; break; } }
        if spaces { insert_text(pending[..]); }
        else { foster = true; reconstruct(); insert_text(pending[..]); foster = false; }
        pending.clear(); mode = original; return true;
    }

    fn in_caption() -> bool {
        if tkind == T_START || tkind == T_END {
            let name = tname();
            let closing = (tkind == T_END && (name == "caption" || name == "table")) ||
                          (tkind == T_START && h5_in(name,"|caption|col|colgroup|tbody|td|tfoot|th|thead|tr|"));
            if closing {
                if !in_scope("caption",SC_TABLE) { return false; }
                implied(""); pop_until("caption"); clear_to_marker(); mode = M_TABLE;
                return !(tkind == T_END && name == "caption");
            }
            if tkind == T_END && h5_in(name,"|body|col|colgroup|html|tbody|td|tfoot|th|thead|tr|") { return false; }
        }
        return in_body();
    }

    fn in_colgroup() -> bool {
        if tkind == T_TEXT {
            // Character by character: spaces are inserted, and anything else ends the group, or is
            // dropped when the current node isn't one (in a template).
            while true {
                let s = text(); var k: i64 = 0;
                while k < s.len && h5_space(s[k]) { k += 1; }
                insert_text(s[..k]);
                if k == s.len { return false; }
                tstart += k;
                if is_html(cur(),"colgroup") { break; }
                tstart += 1;
            }
        } else if tkind == T_COMMENT { insert_comment(); return false; }
        else if tkind == T_START && tname() == "html" { return in_body(); }
        else if tkind == T_START && tname() == "col" { let e = insert_token(NS_HTML); let x = stack.pop(); return false; }
        else if tkind == T_END && tname() == "colgroup" { if is_html(cur(),"colgroup") { let x = stack.pop(); mode = M_TABLE; } return false; }
        else if tkind == T_END && tname() == "col" { return false; }
        else if (tkind == T_START || tkind == T_END) && tname() == "template" { return in_body(); }
        else if tkind == T_EOF { return in_body(); }
        if !is_html(cur(),"colgroup") { return false; }
        let x = stack.pop(); mode = M_TABLE; return true;
    }

    fn in_tbody() -> bool {
        if tkind == T_START || tkind == T_END {
            let name = tname();
            if tkind == T_START && name == "tr" { clear_to("|tbody|tfoot|thead|template|html|"); let e = insert_token(NS_HTML); mode = M_ROW; return false; }
            if tkind == T_START && (name == "th" || name == "td") { clear_to("|tbody|tfoot|thead|template|html|"); let e = insert_element("tr",NS_HTML,false); mode = M_ROW; return true; }
            if tkind == T_END && (name == "tbody" || name == "tfoot" || name == "thead") {
                if !in_scope(name,SC_TABLE) { return false; }
                clear_to("|tbody|tfoot|thead|template|html|"); let x = stack.pop(); mode = M_TABLE; return false;
            }
            if (tkind == T_START && h5_in(name,"|caption|col|colgroup|tbody|tfoot|thead|")) || (tkind == T_END && name == "table") {
                if !set_in_scope("|tbody|thead|tfoot|",SC_TABLE) { return false; }
                clear_to("|tbody|tfoot|thead|template|html|"); let x = stack.pop(); mode = M_TABLE; return true;
            }
            if tkind == T_END && h5_in(name,"|body|caption|col|colgroup|html|td|th|tr|") { return false; }
        }
        return in_table();
    }

    fn in_row() -> bool {
        if tkind == T_START || tkind == T_END {
            let name = tname();
            if tkind == T_START && (name == "th" || name == "td") { clear_to("|tr|template|html|"); let e = insert_token(NS_HTML); mode = M_CELL; afe.push(-1); return false; }
            if tkind == T_END && name == "tr" {
                if !in_scope("tr",SC_TABLE) { return false; }
                clear_to("|tr|template|html|"); let x = stack.pop(); mode = M_TBODY; return false;
            }
            if (tkind == T_START && h5_in(name,"|caption|col|colgroup|tbody|tfoot|thead|tr|")) || (tkind == T_END && name == "table") {
                if !in_scope("tr",SC_TABLE) { return false; }
                clear_to("|tr|template|html|"); let x = stack.pop(); mode = M_TBODY; return true;
            }
            if tkind == T_END && (name == "tbody" || name == "tfoot" || name == "thead") {
                if !in_scope(name,SC_TABLE) || !in_scope("tr",SC_TABLE) { return false; }
                clear_to("|tr|template|html|"); let x = stack.pop(); mode = M_TBODY; return true;
            }
            if tkind == T_END && h5_in(name,"|body|caption|col|colgroup|html|td|th|") { return false; }
        }
        return in_table();
    }

    fn close_cell() { implied(""); pop_until_set("|td|th|"); clear_to_marker(); mode = M_ROW; }
    fn in_cell() -> bool {
        if tkind == T_START || tkind == T_END {
            let name = tname();
            if tkind == T_END && (name == "td" || name == "th") {
                if !in_scope(name,SC_TABLE) { return false; }
                implied(""); pop_until(name); clear_to_marker(); mode = M_ROW; return false;
            }
            if tkind == T_START && h5_in(name,"|caption|col|colgroup|tbody|td|tfoot|th|thead|tr|") {
                if !set_in_scope("|td|th|",SC_TABLE) { return false; }
                close_cell(); return true;
            }
            if tkind == T_END && h5_in(name,"|body|caption|col|colgroup|html|") { return false; }
            if tkind == T_END && h5_in(name,"|table|tbody|tfoot|thead|tr|") {
                if !in_scope(name,SC_TABLE) { return false; }
                close_cell(); return true;
            }
        }
        return in_body();
    }

    fn in_select() -> bool {
        if tkind == T_TEXT { insert_chars(text(),false); return false; }
        if tkind == T_COMMENT { insert_comment(); return false; }
        if tkind == T_EOF { return in_body(); }
        let name = tname();
        if tkind == T_START {
            if name == "html" { return in_body(); }
            if name == "option" { if is_html(cur(),"option") { let x = stack.pop(); } let e = insert_token(NS_HTML); return false; }
            if name == "optgroup" {
                if is_html(cur(),"option") { let x = stack.pop(); }
                if is_html(cur(),"optgroup") { let x = stack.pop(); }
                let e = insert_token(NS_HTML); return false;
            }
            if name == "hr" {
                if is_html(cur(),"option") { let x = stack.pop(); }
                if is_html(cur(),"optgroup") { let x = stack.pop(); }
                let e = insert_token(NS_HTML); let x = stack.pop(); return false;
            }
            if name == "select" {
                if !in_scope("select",SC_SELECT) { return false; }
                pop_until("select"); reset_mode(); return false;
            }
            if name == "input" || name == "keygen" || name == "textarea" {
                if !in_scope("select",SC_SELECT) { return false; }
                pop_until("select"); reset_mode(); return true;
            }
            if name == "script" || name == "template" { let handled = head_start(name); return false; }
            return false;
        }
        if name == "optgroup" {
            if is_html(cur(),"option") && stack.len > 2 && is_html(stack[stack.len-2],"optgroup") { let x = stack.pop(); }
            if is_html(cur(),"optgroup") { let x = stack.pop(); }
            return false;
        }
        if name == "option" { if is_html(cur(),"option") { let x = stack.pop(); } return false; }
        if name == "select" {
            if !in_scope("select",SC_SELECT) { return false; }
            pop_until("select"); reset_mode(); return false;
        }
        if name == "template" { template_end(); return false; }
        return false;
    }

    fn in_select_table() -> bool {
        if (tkind == T_START || tkind == T_END) && h5_in(tname(),"|caption|table|tbody|tfoot|thead|tr|td|th|") {
            if tkind == T_END && !in_scope(tname(),SC_TABLE) { return false; }
            pop_until("select"); reset_mode(); return true;
        }
        return in_select();
    }

    fn in_template() -> bool {
        if tkind == T_TEXT || tkind == T_COMMENT { return in_body(); }
        if tkind == T_EOF {
            if !template_open() { return false; }
            pop_until("template"); clear_to_marker(); let m = tmodes.pop(); reset_mode(); return true;
        }
        let name = tname();
        if tkind == T_START {
            if h5_in(name,"|base|basefont|bgsound|link|meta|noframes|script|style|template|title|") { let handled = head_start(name); return false; }
            var next = M_BODY;
            if h5_in(name,"|caption|colgroup|tbody|tfoot|thead|") { next = M_TABLE; }
            else if name == "col" { next = M_COLGROUP; }
            else if name == "tr" { next = M_TBODY; }
            else if name == "td" || name == "th" { next = M_ROW; }
            let m = tmodes.pop(); tmodes.push(next); mode = next; return true;
        }
        if name == "template" { template_end(); }
        return false;
    }

    fn in_mode() -> bool {
        if tkind == T_CDATA { tkind = T_TEXT; }
        if mode == M_BODY { return in_body(); }
        if mode == M_TEXT { return in_text(); }
        if mode == M_TABLE { return in_table(); }
        if mode == M_TABLE_TEXT { return in_table_text(); }
        if mode == M_CAPTION { return in_caption(); }
        if mode == M_COLGROUP { return in_colgroup(); }
        if mode == M_TBODY { return in_tbody(); }
        if mode == M_ROW { return in_row(); }
        if mode == M_CELL { return in_cell(); }
        if mode == M_SELECT { return in_select(); }
        if mode == M_SELECT_TABLE { return in_select_table(); }
        return in_template();
    }

    fn use_foreign() -> bool {
        if stack.len <= 1 || tkind == T_EOF { return false; }
        let a = cur();
        if nodes[a].ns == NS_HTML { return false; }
        if mathml_text_point(a) {
            if tkind == T_TEXT || tkind == T_CDATA { return false; }
            if tkind == T_START && tname() != "mglyph" && tname() != "malignmark" { return false; }
        }
        if nodes[a].ns == NS_MATH && nname(a) == "annotation-xml" && tkind == T_START && tname() == "svg" { return false; }
        if html_point(a) && (tkind == T_START || tkind == T_TEXT || tkind == T_CDATA) { return false; }
        return true;
    }

    fn in_foreign() -> bool {
        if tkind == T_TEXT { insert_chars(text(),true); return false; }
        if tkind == T_CDATA { insert_run(text(),H5_CDATA); return false; }
        if tkind == T_COMMENT { insert_comment(); return false; }
        let name = tname();
        if tkind == T_START {
            var breakout = h5_in(name,H5_BREAKOUT);
            if name == "font" { let c, hc = attr_token("color"); let f, hf = attr_token("face"); let s, hs = attr_token("size"); breakout = hc || hf || hs; }
            if breakout {
                while stack.len > 1 && !(mathml_text_point(cur()) || html_point(cur()) || nodes[cur()].ns == NS_HTML) { let x = stack.pop(); }
                return in_mode();
            }
            foreign_start(nodes[cur()].ns);
            return false;
        }
        if name == "br" || name == "p" {
            while stack.len > 1 && !(mathml_text_point(cur()) || html_point(cur()) || nodes[cur()].ns == NS_HTML) { let x = stack.pop(); }
            // Reprocessed by the insertion mode's rules, not dispatched again: at an HTML integration
            // point the dispatcher would send an end tag straight back here.
            return in_mode();
        }
        var k = stack.len - 1;
        while k > 0 {
            let e = stack[k];
            var same = nname(e).len == name.len;
            if same { for c, j in nname(e) { if h5_lower(c) != name[j] { same = false; break; } } }
            if same { while stack.len > k { let x = stack.pop(); } return false; }
            k -= 1;
            if nodes[stack[k]].ns == NS_HTML { return in_mode(); }
        }
        return false;
    }

    // --- The tokenizer ---
    fn foreign_now() -> bool { return stack.len > 1 && nodes[cur()].ns != NS_HTML; }
    fn at(p: i64, s: const u8[:]) -> bool { return p + s.len <= n && src[p..p+s.len] == s; }
    fn at_folded(p: i64, s: const u8[:]) -> bool {
        if p + s.len > n { return false; }
        for c, k in s { if h5_lower(src[p+k]) != c { return false; } }
        return true;
    }
    fn push_char(c: u8) { if c == 0 { tb.append("\xEF\xBF\xBD"); } else { tb.push(c); } }
    // A character reference at src[pos] == '&', its characters appended to tb.
    fn char_ref(attribute: bool) {
        let p = pos + 1;
        if p < n && src[p] == '#' {
            var q = p + 1; var hex = false;
            if q < n && (src[q] == 'x' || src[q] == 'X') { hex = true; q += 1; }
            let digits = q; var value: i64 = 0;
            while q < n {
                let c = src[q]; var d: i64 = -1;
                if c >= '0' && c <= '9' { d = (c - '0') as i64; }
                else if hex && c >= 'a' && c <= 'f' { d = (c - 'a') as i64 + 10; }
                else if hex && c >= 'A' && c <= 'F' { d = (c - 'A') as i64 + 10; }
                if d < 0 { break; }
                value = value * (if hex { 16 } else { 10 }) + d;
                if value > 0x110000 { value = 0x110000; }
                q += 1;
            }
            if q == digits { tb.append(src[pos..q]); pos = q; return; }
            if q < n && src[q] == ';' { q += 1; }
            h5_push_utf8(tb,h5_numeric(value)); pos = q; return;
        }
        var q = p; while q < n && h5_alnum(src[q]) { q += 1; }
        if q == p { tb.push('&'); pos += 1; return; }
        var entry: i64 = -1; var end = q;
        if q < n && src[q] == ';' {
            var name: u8[..40] = [];
            if q - p < 39 { name.append(src[p..q]); name.push(';'); entry = h5_entity(name[..]); end = q + 1; }
        }
        if entry < 0 {
            var len = min(q - p, 6);
            while len > 0 { entry = h5_entity(src[p..p+len]); if entry >= 0 { break; } len -= 1; }
            end = p + len;
        }
        if entry < 0 { tb.push('&'); pos += 1; return; }
        if attribute && src[end-1] != ';' && end < n && (src[end] == '=' || h5_alnum(src[end])) { tb.append(src[pos..end]); pos = end; return; }
        tb.append(h5_entity_value(entry)); pos = end;
    }
    // A tag from src[pos], its name's first letter; false when the input ends inside it.
    fn tag(start: bool) -> bool {
        tkind = if start { T_START } else { T_END };
        tname_at = tb.len;
        while pos < n { let c = src[pos]; if h5_space(c) || c == '/' || c == '>' { break; } push_char(h5_lower(c)); pos += 1; }
        tname_len = tb.len - tname_at;
        while true {
            while pos < n && h5_space(src[pos]) { pos += 1; }
            if pos >= n { return false; }
            var c = src[pos];
            if c == '/' {
                pos += 1;
                if pos < n && src[pos] == '>' { tself = true; pos += 1; return true; }
                continue;
            }
            if c == '>' { pos += 1; return true; }
            let name_at = tb.len;
            if c == '=' { tb.push('='); pos += 1; }
            while pos < n { c = src[pos]; if h5_space(c) || c == '/' || c == '>' || c == '=' { break; } push_char(h5_lower(c)); pos += 1; }
            let name_len = tb.len - name_at;
            while pos < n && h5_space(src[pos]) { pos += 1; }
            var value_at = tb.len; var done = false;
            if pos < n && src[pos] == '=' {
                pos += 1;
                while pos < n && h5_space(src[pos]) { pos += 1; }
                if pos >= n { return false; }
                c = src[pos];
                if c == '"' || c == '\'' {
                    pos += 1; value_at = tb.len;
                    while pos < n && src[pos] != c { if src[pos] == '&' { char_ref(true); } else { push_char(src[pos]); pos += 1; } }
                    if pos >= n { return false; }
                    pos += 1;
                } else if c == '>' { pos += 1; done = true; }
                else {
                    value_at = tb.len;
                    while pos < n { let v = src[pos]; if h5_space(v) || v == '>' { break; } if v == '&' { char_ref(true); } else { push_char(v); pos += 1; } }
                    if pos >= n { return false; }
                }
            }
            var duplicate = ta.len > LIMIT;   // past gumbo's limit the tag is refused anyway
            if !duplicate { for a in ta { if tb[a.name_at..a.name_at+a.name_len] == tb[name_at..name_at+name_len] { duplicate = true; break; } } }
            else { too_many = true; }
            if !duplicate { ta.push(H5Attr { name_at: name_at, name_len: name_len, value_at: value_at, value_len: tb.len - value_at }); }
            if done { return true; }
        }
        return false;
    }
    fn comment(start: i64) {
        tkind = T_COMMENT; pos = start;
        var state = 0;   // start, start dash, comment, <, <!, <!-, <!--, end dash, end, end bang
        while pos < n {
            let c = src[pos];
            if state == 0 { if c == '-' { state = 1; pos += 1; } else if c == '>' { pos += 1; return; } else { state = 2; } }
            else if state == 1 { if c == '-' { state = 8; pos += 1; } else if c == '>' { pos += 1; return; } else { tb.push('-'); state = 2; } }
            else if state == 2 {
                if c == '<' { tb.push('<'); state = 3; pos += 1; }
                else if c == '-' { state = 7; pos += 1; }
                else { push_char(c); pos += 1; }
            }
            else if state == 3 { if c == '!' { tb.push('!'); state = 4; pos += 1; } else if c == '<' { tb.push('<'); pos += 1; } else { state = 2; } }
            else if state == 4 { if c == '-' { state = 5; pos += 1; } else { state = 2; } }
            else if state == 5 { if c == '-' { state = 6; pos += 1; } else { state = 7; } }
            else if state == 6 { state = 8; }
            else if state == 7 { if c == '-' { state = 8; pos += 1; } else { tb.push('-'); state = 2; } }
            else if state == 8 {
                if c == '>' { pos += 1; return; }
                else if c == '!' { state = 9; pos += 1; }
                else if c == '-' { tb.push('-'); pos += 1; }
                else { tb.append("--"); state = 2; }
            }
            else { if c == '-' { tb.append("--!"); state = 7; pos += 1; } else if c == '>' { pos += 1; return; } else { tb.append("--!"); state = 2; } }
        }
    }
    fn bogus_comment(start: i64) {
        tkind = T_COMMENT; pos = start;
        while pos < n && src[pos] != '>' { push_char(src[pos]); pos += 1; }
        if pos < n { pos += 1; }
    }
    // Whether src[p..] is an appropriate end tag's start: "</", the open element's name, then a space, / or >.
    fn appropriate_end(p: i64) -> bool {
        if !at(p,"</") { return false; }
        let name = last_start[..];
        if !at_folded(p+2,name) { return false; }
        let q = p + 2 + name.len;
        return q < n && (h5_space(src[q]) || src[q] == '/' || src[q] == '>');
    }
    fn alpha_run(p: i64) -> i64 { var q = p; while q < n && h5_alpha(src[q]) { q += 1; } return q; }
    fn is_script_word(p: i64, q: i64) -> bool {
        if q - p != 6 || q >= n || !(h5_space(src[q]) || src[q] == '/' || src[q] == '>') { return false; }
        return at_folded(p,"script");
    }
    // RCDATA, RAWTEXT or script data up to the element's end tag.
    fn raw_text() {
        tkind = T_TEXT;
        var escape = 0;   // script data: 0, escaped, escaped dash, escaped dash dash, double escaped, its dash, its dash dash
        while pos < n {
            let c = src[pos];
            if c == '<' && escape < 4 && appropriate_end(pos) {
                if tb.len > 0 { return; }
                pos += 2;
                if !tag(false) { tkind = T_EOF; }
                tstate = TS_DATA; return;
            }
            if tstate == TS_SCRIPT {
                if c == '<' {
                    if escape == 0 {
                        if at(pos,"<!--") { tb.append("<!--"); pos += 4; escape = 3; continue; }
                    } else if escape < 4 {
                        escape = 1;
                        if pos + 1 < n && h5_alpha(src[pos+1]) {
                            let q = alpha_run(pos+1);
                            if is_script_word(pos+1,q) { escape = 4; }
                            tb.append(src[pos..q]); pos = q; continue;
                        }
                    } else {
                        escape = 4;
                        if pos + 1 < n && src[pos+1] == '/' {
                            let q = alpha_run(pos+2);
                            if is_script_word(pos+2,q) { escape = 1; }
                            tb.append(src[pos..q]); pos = q; continue;
                        }
                    }
                } else if c == '-' {
                    if escape == 1 || escape == 2 { escape += 1; } else if escape == 4 || escape == 5 { escape += 1; }
                } else if c == '>' {
                    if escape == 3 || escape == 6 { escape = 0; } else if escape == 2 { escape = 1; } else if escape == 5 { escape = 4; }
                } else {
                    if escape == 2 || escape == 3 { escape = 1; } else if escape == 5 || escape == 6 { escape = 4; }
                }
            }
            if c == '&' && tstate == TS_RCDATA { char_ref(false); continue; }
            push_char(c); pos += 1;
        }
    }
    fn next_token() {
        tb.clear(); ta.clear(); tstart = 0; tself = false; tkind = T_TEXT;
        if pos >= n { tkind = T_EOF; return; }
        if tstate == TS_PLAINTEXT { while pos < n { push_char(src[pos]); pos += 1; } return; }
        if tstate != TS_DATA { raw_text(); return; }
        while pos < n {
            let c = src[pos];
            if c == '&' { char_ref(false); continue; }
            if c != '<' { tb.push(c); pos += 1; continue; }
            if tb.len > 0 { return; }
            let p = pos + 1;
            if p >= n { tb.push('<'); pos = n; continue; }
            let d = src[p];
            if d == '!' {
                if at(p+1,"--") { comment(p+3); return; }
                if at_folded(p+1,"doctype") {
                    pos = p + 8; while pos < n && src[pos] != '>' { pos += 1; } if pos < n { pos += 1; }
                    continue;
                }
                if at(p+1,"[CDATA[") && foreign_now() {
                    let close = find(src[p+8..],"]]>");
                    if close < 0 { tb.append(src[p+8..]); pos = n; } else { tb.append(src[p+8..p+8+close]); pos = p + 8 + close + 3; }
                    tkind = T_CDATA; return;
                }
                bogus_comment(p+1); return;
            }
            if d == '/' {
                let q = p + 1;
                if q >= n { tb.append("</"); pos = n; continue; }
                if h5_alpha(src[q]) { pos = q; if tag(false) { return; } tb.clear(); ta.clear(); tkind = T_TEXT; continue; }
                if src[q] == '>' { pos = q + 1; continue; }
                bogus_comment(q); return;
            }
            if h5_alpha(d) { pos = p; if tag(true) { return; } tb.clear(); ta.clear(); tkind = T_TEXT; continue; }
            if d == '?' { bogus_comment(p); return; }
            tb.push('<'); pos += 1;
        }
        if tb.len == 0 { tkind = T_EOF; }
    }

    // --- Parse ---
    while true {
        next_token();
        if too_many || ta.len > LIMIT { return false; }
        if skip_lf {
            skip_lf = false;
            if tkind == T_TEXT && tb.len > 0 && tb[0] == '\n' { tstart = 1; if tb.len == 1 { continue; } }
        }
        // A token is reprocessed a few times at most; the bound only guards against a loop.
        var again = true; var turns = 0;
        while again && turns < 64 { again = if use_foreign() { in_foreign() } else { in_mode() }; turns += 1; }
        if stack.len - 1 > LIMIT { return false; }
        if tkind == T_EOF { break; }
    }

    // --- Canonicalize: attachments emptied, galleries' divs bare, raw markdown unwrapped ---
    let count = nodes.len;
    for i in count {
        // Nokogiri's CSS type selector matches the name in any namespace.
        if nodes[i].kind == H5_ELEMENT && nname(i) == "action-text-attachment" { while nodes[i].first >= 0 { detach(nodes[i].first); } }
    }
    fn gallery_attachment(i: i64) -> bool {
        if !is_html(i,"action-text-attachment") { return false; }
        let value, has = attr_value(i,"presentation");
        return has && value == "gallery";
    }
    for i in count {
        if !is_html(i,"div") || nodes[i].nattrs == 0 { continue; }
        var child = nodes[i].first; var attachments: i64 = 0; var all = true;
        while child >= 0 {
            if nodes[child].kind == H5_TEXT {
                for c in bytes[nodes[child].at..nodes[child].at+nodes[child].len] { if c != ' ' && c != '\n' { all = false; } }
            } else if gallery_attachment(child) { attachments += 1; }
            else { all = false; }
            child = nodes[child].next;
        }
        if all && attachments >= 2 { nodes[i].nattrs = 0; }
    }
    for i in count {
        if nodes[i].kind != H5_ELEMENT || nname(i) != "action-text-markdown" { continue; }
        let parent = nodes[i].parent;
        if parent < 0 { continue; }
        while nodes[i].first >= 0 { let child = nodes[i].first; detach(child); insert_before(parent,child,i); }
        detach(i);
    }

    // --- Serialize ---
    var node = nodes[0].first;
    while node >= 0 {
        let kind = nodes[node].kind;
        var descend = false;
        if kind == H5_TEXT {
            let data = bytes[nodes[node].at..nodes[node].at+nodes[node].len];
            let parent = nodes[node].parent;
            if parent > 0 && nodes[parent].ns == NS_HTML && h5_in(nname(parent),H5_RAW) { out.append(data); } else { h5_text(out,data); }
        } else if kind == H5_CDATA {
            out.append("<![CDATA["); out.append(bytes[nodes[node].at..nodes[node].at+nodes[node].len]); out.append("]]>");
        } else if kind == H5_COMMENT {
            out.append("<!--"); out.append(bytes[nodes[node].at..nodes[node].at+nodes[node].len]); out.append("-->");
        } else {
            out.push('<'); out.append(nname(node));
            for k in nodes[node].nattrs {
                let a = attrs[nodes[node].attrs+k];
                out.push(' '); out.append(bytes[a.name_at..a.name_at+a.name_len]); out.append("=\"");
                h5_attribute(out,bytes[a.value_at..a.value_at+a.value_len]); out.push('"');
            }
            out.push('>');
            if !(nodes[node].ns == NS_HTML && h5_in(nname(node),H5_VOID)) {
                if nodes[node].first >= 0 { descend = true; } else { out.append("</"); out.append(nname(node)); out.push('>'); }
            }
        }
        if descend { node = nodes[node].first; continue; }
        // Up to the next sibling, closing each element left.
        while node > 0 && nodes[node].next < 0 {
            node = nodes[node].parent;
            if node <= 0 { break; }
            out.append("</"); out.append(nname(node)); out.push('>');
        }
        if node <= 0 { break; }
        node = nodes[node].next;
    }
    return true;
}

fn h5_ascii_lower_eq(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return false; }
    for c, k in a { if h5_lower(c) != b[k] { return false; } }
    return true;
}
