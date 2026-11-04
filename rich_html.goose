namespace campfire;
import std;
import html;

struct RichAttr { name: const u8[:], value: const u8[:] }
struct RichTag { name: const u8[:] = "", end: i64 = 0, closing: bool = false }

fn rich_tag(source: const u8[:], start: i64, attrs: RichAttr[>..]&) -> RichTag {
    var tag=RichTag { end:start+1, .. }; var i=start+1;
    if i<source.len && source[i]=='/' { tag.closing=true; i+=1; }
    let first=i; while i<source.len && html_word(source[i]) { i+=1; }
    tag.name=source[first..i];
    while i<source.len {
        while i<source.len && (html_space(source[i]) || source[i]=='/') { i+=1; }
        if i==source.len { break; }
        if source[i]=='>' { tag.end=i+1; return tag; }
        let begin=i;
        while i<source.len && !html_space(source[i]) && source[i]!='=' && source[i]!='>' && source[i]!='/' { i+=1; }
        if i==begin { i+=1; continue; }
        let name=source[begin..i];
        while i<source.len && html_space(source[i]) { i+=1; }
        var value: const u8[:]=source[..0];
        if i<source.len && source[i]=='=' {
            i+=1; while i<source.len && html_space(source[i]) { i+=1; }
            var quote: u8=0;
            if i<source.len && (source[i]=='\'' || source[i]=='"') { quote=source[i]; i+=1; }
            let value_start=i;
            while i<source.len && (if quote!=0 { source[i]!=quote } else { !html_space(source[i]) && source[i]!='>' }) { i+=1; }
            value=source[value_start..i]; if quote!=0 && i<source.len { i+=1; }
        }
        attrs.push(RichAttr { name:name,value:value });
    }
    tag.end=source.len; return tag;
}

fn rich_attribute(attrs: const RichAttr[:], name: const u8[:]) -> const u8[:] {
    for a in attrs { if a.name==name { return a.value; } } return "";
}

fn html_decode(source: const u8[:]) -> u8[>..] {
    var out: u8[>..]=[]; var i: i64=0;
    while i<source.len {
        if source[i]=='&' {
            let end=find(source[i..min(source.len,i+17)],";");
            if end>0 && end<=16 {
                let entity=source[i+1..i+end]; var c: i64=-1;
                if entity=="amp" { c=38; } else if entity=="lt" { c=60; } else if entity=="gt" { c=62; }
                else if entity=="quot" { c=34; } else if entity=="apos" { c=39; } else if entity=="nbsp" { c=160; }
                else if starts_with(entity,"#") {
                    let hex=entity.len>2 && (entity[1]=='x' || entity[1]=='X'); c=0;
                    for digit in entity[if hex {2} else {1}..] {
                        let v=if digit>='0' && digit<='9' { digit-'0' } else if hex && digit>='a' && digit<='f' { digit-'a'+10 } else if hex && digit>='A' && digit<='F' { digit-'A'+10 } else { 255 };
                        if v==255 { c=-1; break; } c=c*(if hex {16} else {10})+v;
                    }
                }
                if c>0 && c<=0x10ffff && !(c>=0xd800 && c<=0xdfff) {
                    if c<128 { out.push(c as u8); }
                    else if c<2048 { out.push((192 | (c >> 6)) as u8); out.push((128 | (c & 63)) as u8); }
                    else if c<65536 { out.push((224 | (c >> 12)) as u8); out.push((128 | ((c >> 6) & 63)) as u8); out.push((128 | (c & 63)) as u8); }
                    else { out.push((240 | (c >> 18)) as u8); out.push((128 | ((c >> 12) & 63)) as u8); out.push((128 | ((c >> 6) & 63)) as u8); out.push((128 | (c & 63)) as u8); }
                    i+=end+1; continue;
                }
            }
        }
        out.push(source[i]); i+=1;
    } return out;
}

// MessagesHelper#auto_link_text for one text node: unless it has a ":", an "@" or a "www.", its text
// escaped; otherwise rails_autolink's auto_link(text, html: { target: "_blank" }) of the text as
// Nokogiri writes it (&, < and > escaped), URLs then email addresses.
fn rich_text_segment(out: u8[>..]&, source: const u8[:], autolink: bool) {
    let decoded=html_decode(source);
    guard autolink && linkable_text(decoded) else { escape(out,decoded); return; }
    var text: u8[>..]=[];
    for c in decoded { if c=='&' { text.append("&amp;"); } else if c=='<' { text.append("&lt;"); } else if c=='>' { text.append("&gt;"); } else { text.push(c); } }
    out.append(auto_link_emails(auto_link_urls(text)));
}

// MessagesHelper::LINKABLE_TEXT, /:|@|www\./i
fn linkable_text(text: const u8[:]) -> bool {
    for c, i in text {
        if c==':' || c=='@' { return true; }
        if (c=='w' || c=='W') && i+4<=text.len && html_lower(text[i..i+4])=="www." { return true; }
    }
    return false;
}

let AUTO_LINK_SCHEMES = ["ed2k","ftp","http","https","irc","mailto","news","gopher","nntp","telnet","webcal","xmpp","callto","feed","svn","urn","aim","rsync","tag","ssh","sftp","rtsp","afs","file"];

fn ascii_word(c: u8) -> bool { return (c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='_'; }

// The length of AUTO_LINK_RE's opening at text[i..] (a scheme's "scheme://", or "www." and a word
// character), and whether it has a scheme; 0 for none.
fn auto_link_opening(text: const u8[:], i: i64) -> i64, bool {
    for scheme in AUTO_LINK_SCHEMES {
        let n=scheme.len;
        if i+n+3<=text.len && html_lower(text[i..i+n])==scheme && text[i+n..i+n+3]=="://" { return n+3, true; }
    }
    if i+5<=text.len && html_lower(text[i..i+4])=="www." && ascii_word(text[i+4]) { return 5, false; }
    return 0, false;
}

// [^\s< "]: Ruby's \s, a "<", a no-break space (C2 A0) or a quote ends a URL.
fn auto_link_stop(text: const u8[:], i: i64) -> bool {
    let c=text[i];
    return c==' ' || c=='\t' || c=='\n' || c=='\r' || c==12 || c==11 || c=='<' || c=='"' || (c==0xC2 && i+1<text.len && text[i+1]==0xA0);
}

// The character ending text: its first byte's index, and whether it's in [\p{Word}/\-=;] (a character
// outside ASCII counts as a word character unless it is punctuation or a symbol of Latin-1, General
// Punctuation or CJK Symbols and Punctuation).
fn auto_link_last(text: const u8[:]) -> i64, bool {
    var at=text.len-1;
    while at>0 && (text[at] & 0xC0)==0x80 { at-=1; }
    let c=text[at];
    if c<0x80 { return at, ascii_word(c) || c=='/' || c=='-' || c=='=' || c==';'; }
    let rest=text[at..];
    if rest.len==2 && rest[0]==0xC2 { let b=rest[1]; return at, b==0xAA || b==0xB2 || b==0xB3 || b==0xB5 || b==0xB9 || b==0xBA || b>=0xBC; }
    if rest.len==3 && rest[0]==0xE2 && (rest[1]==0x80 || rest[1]==0x81) { return at, false; }
    if rest.len==3 && rest[0]==0xE3 && rest[1]==0x80 { return at, false; }
    return at, true;
}

fn count_byte(text: const u8[:], c: u8) -> i64 { var n: i64=0; for x in text { if x==c { n+=1; } } return n; }

// auto_link_urls on Nokogiri-escaped text: each URL a target="_blank" link (http:// added to a
// www. one), its trailing punctuation (but a closing bracket it opened) and &gt; left outside.
fn auto_link_urls(text: const u8[:]) -> u8[>..] {
    var out: u8[>..]=[]; var i: i64=0; var begin: i64=0;
    while i<text.len {
        let opening, scheme=auto_link_opening(text,i);
        if opening==0 { i+=1; continue; }
        var end=i+opening;
        while end<text.len && !auto_link_stop(text,end) { end+=1; }
        if end==i+opening { i+=1; continue; }
        // The trailing punctuation, then a trailing &gt;, go after the link, in that order.
        var hend=end;
        while hend>i {
            let at, word=auto_link_last(text[i..hend]);
            if word { break; }
            let c=text[i+at]; let popped=hend; hend=i+at;
            let bracket: u8=if c==']' { '[' } else if c==')' { '(' } else if c=='}' { '{' } else { 0 };
            if bracket!=0 && count_byte(text[i..hend],bracket)>count_byte(text[i..hend],c) { hend=popped; break; }
        }
        let pend=hend; var gt=false;
        if hend-i>=4 && text[hend-4..hend]=="&gt;" { hend-=4; gt=true; }
        let href=text[i..hend];
        out.append(text[begin..i]);
        out.append("<a target=\"_blank\" href=\""); if !scheme { out.append("http://"); } out.append(href); out.append("\">"); out.append(href); out.append("</a>");
        out.append(text[pend..end]); if gt { out.append("&gt;"); }
        i=end; begin=end;
    }
    out.append(text[begin..]); return out;
}

// AUTO_EMAIL_LOCAL_RE
fn email_local(c: u8) -> bool {
    return ascii_word(c) || c=='.' || c=='!' || c=='#' || c=='$' || c=='%' || c=='&' || c=='\'' || c=='*' || c=='/' || c=='=' || c=='?' ||
        c=='^' || c=='`' || c=='{' || c=='|' || c=='}' || c=='~' || c=='+' || c=='-';
}

// auto_linked?(left, right): within a tag, or after an <a ...> not yet closed.
fn auto_linked(left: const u8[:], right: const u8[:]) -> bool {
    let open=rfind(left,"<");
    if open>=0 && find(left[open..],">")<0 && find(right,">")>=0 { return true; }
    let lower=html_lower(left); var at=lower.len-1; var link: i64=-1;
    while at>=0 { if lower[at]=='<' && starts_with(lower[at..],"<a") && (at+2>=lower.len || !ascii_word(lower[at+2])) && find(lower[at..],">")>=0 { link=at; break; } at-=1; }
    if link<0 { return false; }
    let after=lower[link..]; let close=find(after,">");
    return find(after[close+1..],"</a>")<0;
}

// auto_link_email_addresses: each AUTO_EMAIL_RE match not already linked, as mail_to(email, target: "_blank").
fn auto_link_emails(text: const u8[:]) -> u8[>..] {
    var out: u8[>..]=[]; var i: i64=0; var begin: i64=0;
    while i<text.len {
        let c=text[i];
        let first=ascii_word(c) || c=='.' || c=='!' || c=='#' || c=='$' || c=='%' || c=='+' || c=='-';
        if !first || (i>0 && email_local(text[i-1])) { i+=1; continue; }
        var at=i+1; while at<text.len && email_local(text[at]) { at+=1; }
        if at>=text.len || text[at]!='@' { i+=1; continue; }
        var end=at+1; while end<text.len && (ascii_word(text[end]) || text[end]=='-') { end+=1; }
        if end==at+1 { i+=1; continue; }
        var groups: i64=0;
        while end+1<text.len && text[end]=='.' && (ascii_word(text[end+1]) || text[end+1]=='-') {
            end+=1; while end<text.len && (ascii_word(text[end]) || text[end]=='-') { end+=1; } groups+=1;
        }
        if groups==0 { i+=1; continue; }
        if auto_linked(text[..i],text[end..]) { i=end; continue; }
        out.append(text[begin..i]);
        out.append("<a target=\"_blank\" href=\"mailto:"); out.append(text[i..end]); out.append("\">"); out.append(text[i..end]); out.append("</a>");
        i=end; begin=end;
    }
    out.append(text[begin..]); return out;
}

fn rich_plain(source: const u8[:]) -> u8[>..] {
    var text: u8[>..] = []; var i: i64 = 0;
    while i < source.len {
        if source[i] == '<' {
            var attrs: RichAttr[>..] = []; let tag = rich_tag(source,i,attrs); i = tag.end;
            if tag.name == "br" || tag.closing && (tag.name == "p" || tag.name == "div" || tag.name == "li") { text.push('\n'); }
        } else { text.push(source[i]); i++; }
    }
    let decoded = html_decode(text); var end = decoded.len;
    while end > 0 && decoded[end-1] == '\n' { end--; }
    return str(decoded[..end]);
}

let MENTION_TYPE = "application/vnd.campfire.mention";

// keep_mentions keeps each mention attachment, minified to its sgid and content type as Action Text stores it,
// and each link preview (an opengraph embed), rebuilt from its checked details (og_embed_html) against host.
// script_text keeps a script's or style's content as text, as Action Text's sanitizer does when it
// renders a body (RichText#to_s).
fn rich_sanitize(out: u8[>..]&, source: const u8[:], autolink: bool=true, keep_mentions: bool=false, host: const u8[:]="", script_text: bool=false) {
    let allowed="|a|abbr|acronym|address|b|big|blockquote|br|cite|code|dd|del|dfn|div|dl|dt|em|h1|h2|h3|h4|h5|h6|hr|i|img|ins|kbd|li|mark|ol|p|pre|samp|small|span|strong|sub|sup|time|tt|ul|var|s|u|table|thead|tbody|tfoot|tr|th|td|";
    let attributes="|abbr|alt|cite|class|datetime|height|href|lang|src|title|width|xml:lang|data-language|";
    var stack: u8[..32][128]=["";128]; var depth: i64=0; var i: i64=0; var link_depth: i64=0;
    // The presentation is parsed as HTML5, which drops a newline just after <pre>, then written with
    // preserve_newline, which writes one back when another newline follows.
    var after_pre=false;
    while i<source.len {
        if source[i]!='<' {
            var end=i+1; while end<source.len && source[end]!='<' { end+=1; }
            var text=source[i..end];
            if after_pre && autolink && !script_text && text[0]=='\n' && !(text.len>1 && text[1]=='\n') { text=text[1..]; }
            after_pre=false;
            rich_text_segment(out,text,autolink && link_depth==0); i=end; continue;
        }
        after_pre=false;
        var attrs: RichAttr[>..]=[]; let tag=rich_tag(source,i,attrs); i=tag.end; let name=html_lower(tag.name);
        if name=="script" || name=="style" || name=="iframe" || name=="svg" || name=="math" {
            if !tag.closing {
                let end=find(source[i..],str("</",name)); if end<0 { return; }
                if script_text && (name=="script" || name=="style") { escape(out,source[i..i+end]); }
                let closing=find(source[i+end..],">"); i=if closing<0 {source.len} else {i+end+closing+1};
            } continue;
        }
        if keep_mentions && !tag.closing && name=="action-text-attachment" && html_decode(rich_attribute(attrs,"content-type"))==MENTION_TYPE {
            let sgid=html_decode(rich_attribute(attrs,"sgid"));
            if sgid.len>0 { out.append("<action-text-attachment sgid=\""); escape(out,sgid); format(out,"\" content-type=\"",MENTION_TYPE,"\"></action-text-attachment>"); }
            let end=find(source[i..],"</action-text-attachment>"); if end>=0 { i+=end+25; }
            continue;
        }
        if keep_mentions && !tag.closing && name=="action-text-attachment" && find(html_decode(rich_attribute(attrs,"content-type")),OPENGRAPH_EMBED_TYPE)>=0 {
            let embed=og_embed_from_node(attrs,host);
            var content: u8[>..]=[]; og_embed_markup(content,embed);
            format(out,"<action-text-attachment content-type=\"",OPENGRAPH_EMBED_TYPE,"\" content=\""); escape(out,content); out.append("\"></action-text-attachment>");
            let end=find(source[i..],"</action-text-attachment>"); if end>=0 { i+=end+25; }
            continue;
        }
        if find(allowed,str("|",name,"|"))<0 || name.len==0 { continue; }
        if tag.closing {
            var at=depth-1; while at>=0 && stack[at]!=name { at-=1; }
            if at>=0 { while depth>at { depth-=1; if stack[depth]=="a" { link_depth-=1; } format(out,"</",stack[depth],">"); } } continue;
        }
        if depth==stack.len { continue; }
        format(out,"<",name);
        for a in attrs {
            let attr=html_lower(a.name); if find(attributes,str("|",attr,"|"))<0 { continue; }
            let value=html_decode(a.value);
            if (attr=="href" || attr=="src" || attr=="cite") && !safe_link(value) { continue; }
            format(out," ",attr,"=\""); escape(out,value); out.push('"');
        }
        out.push('>');
        if name!="br" && name!="hr" && name!="img" { stack[depth]=name; depth+=1; if name=="a" { link_depth+=1; } }
        after_pre=name=="pre";
    }
    while depth>0 { depth-=1; format(out,"</",stack[depth],">"); }
}

// --- Link previews: ActionText::Attachment::OpengraphEmbed (lib/rails_ext/actiontext_opengraph_embeds.rb) ---------

let OPENGRAPH_EMBED_TYPE = "application/vnd.actiontext.opengraph-embed";

struct OgEmbed {
    href: u8[] = [],
    url: u8[] = [],
    filename: u8[] = [],
    has_filename: bool = false,
    description: u8[] = [],
}

// `web_url`: an absolute http(s) URL, as URI.parse takes it, on a named host other than host (the
// request's, without its port; empty when rendering, where only the name is checked).
fn og_web_url(value: const u8[:], host: const u8[:]) -> bool {
    if trim(value).len == 0 { return false; }
    for c in value { if c <= 32 || c >= 127 || c == '"' || c == '<' || c == '>' || c == '\\' || c == '^' || c == '`' || c == '{' || c == '|' || c == '}' { return false; } }
    let lower = html_lower(value);
    let scheme = if starts_with(lower,"http://") { 7 } else if starts_with(lower,"https://") { 8 } else { 0 };
    if scheme == 0 { return false; }
    var end = scheme; while end < value.len && value[end] != '/' && value[end] != '?' && value[end] != '#' { end += 1; }
    var authority = lower[scheme..end];
    let at = rfind(authority,"@"); if at >= 0 { authority = authority[at+1..]; }
    if starts_with(authority,"[") { return false; }
    let colon = find(authority,":");
    let name = if colon >= 0 { authority[..colon] } else { authority };
    if colon >= 0 { for c in authority[colon+1..] { if c < '0' || c > '9' { return false; } } }
    // named_host?: a dotted name whose last label is a word, never a number or 0x...
    if name.len == 0 || find(name,"%") >= 0 || find(name,".") < 0 { return false; }
    let last = name[rfind(name,".")+1..];
    var letter = false; for c in last { if c >= 'a' && c <= 'z' { letter = true; } }
    if !letter || starts_with(last,"0x") { return false; }
    let canonical = if ends_with(name,".") { name[..name.len-1] } else { name };
    let host_lower = html_lower(host); let port = find(host_lower,":");
    var host_end = if port >= 0 { port } else { host_lower.len };
    if host_end > 0 && host_lower[host_end-1] == '.' { host_end -= 1; }
    return canonical != host_lower[..host_end];
}

// The text of an element's content (Nokogiri's text), entities decoded.
fn og_text(source: const u8[:]) -> u8[>..] {
    var text: u8[>..] = []; var i: i64 = 0;
    while i < source.len {
        if source[i] == '<' { var attrs: RichAttr[>..] = []; let tag = rich_tag(source,i,attrs); i = tag.end; }
        else { text.push(source[i]); i += 1; }
    }
    return html_decode(text);
}

// Ruby's String#strip: ASCII whitespace and NUL at either end.
fn og_strip(text: const u8[:]) -> u8[>..] {
    var start: i64 = 0; var end = text.len;
    while start < end && (html_space(text[start]) || text[start] == 0 || text[start] == 11) { start += 1; }
    while end > start && (html_space(text[end-1]) || text[end-1] == 0 || text[end-1] == 11) { end -= 1; }
    return str(text[start..end]);
}

fn og_has_class(attrs: const RichAttr[:], name: const u8[:]) -> bool {
    let classes = html_decode(rich_attribute(attrs,"class"));
    for word in split(classes,' ') { if word == name { return true; } }
    return false;
}

// The first element whose class includes name (at_css): its tag name, attributes' start, and its
// content up to the matching end tag (to the end when it's left open).
fn og_element(source: const u8[:], name: const u8[:]) -> const u8[:], const u8[:], bool {
    var i: i64 = 0;
    while i < source.len {
        if source[i] != '<' { i += 1; continue; }
        var attrs: RichAttr[>..] = []; let tag = rich_tag(source,i,attrs);
        if !tag.closing && tag.name.len > 0 && og_has_class(attrs,name) {
            let element = html_lower(tag.name); var depth: i64 = 1; var j = tag.end;
            while j < source.len {
                if source[j] != '<' { j += 1; continue; }
                var inner: RichAttr[>..] = []; let t = rich_tag(source,j,inner);
                if html_lower(t.name) == element { if t.closing { depth -= 1; if depth == 0 { return source[i..tag.end], source[tag.end..j], true; } } else { depth += 1; } }
                j = t.end;
            }
            return source[i..tag.end], source[tag.end..], true;
        }
        i = tag.end;
    }
    return source[..0], source[..0], false;
}

// The first `name` element in source: its attributes and content (to its end tag, or the end).
fn og_first(source: const u8[:], name: const u8[:], attrs: RichAttr[>..]&) -> const u8[:], bool {
    var i: i64 = 0;
    while i < source.len {
        if source[i] != '<' { i += 1; continue; }
        attrs.clear(); let tag = rich_tag(source,i,attrs);
        if !tag.closing && html_lower(tag.name) == name {
            let end = find(html_lower(source[tag.end..]),str("</",name));
            return if end < 0 { source[tag.end..] } else { source[tag.end..tag.end+end] }, true;
        }
        i = tag.end;
    }
    attrs.clear(); return source[..0], false;
}

// `from_node`: a Trix embed's details from its node's attributes, a Lexxy one's from its content.
fn og_embed_from_node(attrs: const RichAttr[:], host: const u8[:]) -> OgEmbed {
    var href: u8[>..] = []; var url: u8[>..] = []; var filename: u8[>..] = []; var has_filename = false; var description: u8[>..] = [];
    let trix_filename = html_decode(rich_attribute(attrs,"filename"));
    if trim(trix_filename).len > 0 {
        let link = html_decode(rich_attribute(attrs,"href")); let image = html_decode(rich_attribute(attrs,"url"));
        if og_web_url(link,host) { href.append(link); }
        if og_web_url(image,host) { url.append(image); }
        filename.append(trix_filename); has_filename = true;
        description.append(html_decode(rich_attribute(attrs,"caption")));
    } else {
        let content = html_decode(rich_attribute(attrs,"content"));
        let title_tag, title, has_title = og_element(content,"og-embed__title");
        if has_title {
            var link: RichAttr[>..] = []; let text, linked = og_first(title,"a",link);
            if linked { let target = html_decode(rich_attribute(link,"href")); if og_web_url(target,host) { href.append(target); } }
            filename.append(og_strip(og_text(if linked { text } else { title }))); has_filename = true;
        }
        let image_tag, image, has_image = og_element(content,"og-embed__image");
        if has_image {
            var img: RichAttr[>..] = []; let ignored, found = og_first(image,"img",img);
            if found { let src = html_decode(rich_attribute(img,"src")); if og_web_url(src,host) { url.append(src); } }
        }
        let description_tag, text, has_description = og_element(content,"og-embed__description");
        if has_description { description.append(og_strip(og_text(text))); }
    }
    return OgEmbed { href: href, url: url, filename: filename, has_filename: has_filename, description: description };
}

// The embed as the stored content of its attachment: the markup the composer inserts, from its checked details.
fn og_embed_markup(out: u8[>..]&, embed: const OgEmbed&) {
    out.append("<actiontext-opengraph-embed><div class=\"og-embed\"><div class=\"og-embed__content\">");
    if embed.has_filename {
        out.append("<div class=\"og-embed__title\">");
        if embed.href.len > 0 { out.append("<a href=\""); escape(out,embed.href); out.append("\">"); escape(out,embed.filename); out.append("</a>"); }
        else { escape(out,embed.filename); }
        out.append("</div>");
    }
    out.append("<div class=\"og-embed__description\">"); escape(out,embed.description); out.append("</div></div>");
    if embed.url.len > 0 { out.append("<div class=\"og-embed__image\"><img src=\""); escape(out,embed.url); out.append("\"></div>"); }
    out.append("</div></actiontext-opengraph-embed>");
}

// `truncate(text, length: n, omission: "…")`, in characters.
fn og_truncate(text: const u8[:], length: i64) -> u8[>..] {
    var starts: i64[>..] = []; var i: i64 = 0;
    while i < text.len { if (text[i] & 0xC0) != 0x80 { starts.push(i); } i += 1; }
    if starts.len <= length { return str(text); }
    return str(text[..starts[length-1]],"…");
}

// action_text/attachables/_opengraph_embed.html.erb. sanitized: as Action Text's sanitizer leaves a content
// attachment, without the custom element (what it holds stays) or the link's rel and target.
fn og_embed_html(out: u8[>..]&, embed: const OgEmbed&, sanitized: bool = false) {
    out.append("<figure class=\"attachment attachment--content attachment--og\">\n  ");
    if !sanitized { out.append("<actiontext-opengraph-embed>"); }
    out.append("\n    <div class=\"og-embed gap ");
    if starts_with(embed.url,"https://pbs.twimg.com/profile_images") { out.append("og-embed--twitter-avatar"); }
    out.append("\">\n      <div class=\"og-embed__content\">\n        <div class=\"og-embed__title\">\n          ");
    // link_to_if: a link named after the title (the URL when there is none), else the title alone.
    let title = if embed.has_filename { og_truncate(embed.filename,280) } else { str(embed.href) };
    if embed.href.len > 0 { out.append(if sanitized { "<a href=\"" } else { "<a rel=\"noreferrer\" target=\"_blank\" href=\"" }); escape(out,embed.href); out.append("\">"); escape(out,title); out.append("</a>"); }
    else { escape(out,title); }
    out.append("\n        </div>\n        <div class=\"og-embed__description\">"); escape(out,og_truncate(embed.description,560));
    out.append("</div>\n      </div>\n");
    if embed.url.len > 0 { out.append("        <div class=\"og-embed__image\">\n          <img src=\""); escape(out,embed.url); out.append("\" class=\"image center\" alt=\"\">\n        </div>\n"); }
    out.append("    </div>\n  "); if !sanitized { out.append("</actiontext-opengraph-embed>"); } out.append("\n</figure>");
}

// ContentFilters::SanitizeTags: every element outside ALLOWED_TAGS goes, with its content, as Rails
// removes the parsed node. An element left open ends where its parent does, or at the end.
fn sanitize_tags(source: const u8[:]) -> u8[>..] {
    let allowed="|a|abbr|acronym|address|b|big|blockquote|br|cite|code|dd|del|dfn|div|dl|dt|em|h1|h2|h3|h4|h5|h6|hr|i|ins|kbd|li|ol|p|pre|samp|small|span|strong|sub|sup|time|tt|ul|var|s|u|mark|table|thead|tbody|tfoot|tr|th|td|action-text-attachment|figure|figcaption|";
    let void="|area|base|basefont|bgsound|col|embed|img|image|input|keygen|link|meta|param|source|track|wbr|frame|";
    let raw="|script|style|textarea|title|xmp|iframe|noembed|noframes|noscript|plaintext|";
    var out: u8[>..]=[]; var open: u8[..32][128]=["";128]; var depth: i64=0; var i: i64=0; var begin: i64=0;
    while i<source.len {
        if source[i]!='<' { i+=1; continue; }
        if i+1>=source.len || !(html_word(source[i+1]) || source[i+1]=='/') { i+=1; continue; }
        var attrs: RichAttr[>..]=[]; let tag=rich_tag(source,i,attrs); let name=html_lower(tag.name);
        if name.len==0 { i=tag.end; continue; }
        let known=find(allowed,str("|",name,"|"))>=0;
        if known {
            if tag.closing { var at=depth-1; while at>=0 && open[at]!=name { at-=1; } if at>=0 { depth=at; } }
            else if name!="br" && name!="hr" && depth<open.len && name.len<=32 { open[depth]=name; depth+=1; }
            i=tag.end; continue;
        }
        out.append(source[begin..i]);
        var next=tag.end;
        if !tag.closing && find(void,str("|",name,"|"))<0 {
            if find(raw,str("|",name,"|"))>=0 {
                let end=find(html_lower(source[tag.end..]),str("</",name));
                if end<0 { next=source.len; } else { let close=find(source[tag.end+end..],">"); next=if close<0 { source.len } else { tag.end+end+close+1 }; }
            } else {
                var depth: i64=1; var j=tag.end; next=source.len;
                while j<source.len {
                    if source[j]!='<' { j+=1; continue; }
                    var inner: RichAttr[>..]=[]; let t=rich_tag(source,j,inner); let inner_name=html_lower(t.name);
                    if t.closing && inner_name.len>0 {
                        var parent=false; for k in depth { if open[k]==inner_name { parent=true; } }
                        if parent { next=j; break; }
                    }
                    if inner_name==name { if t.closing { depth-=1; if depth==0 { next=t.end; break; } } else { depth+=1; } }
                    j=t.end;
                }
            }
        }
        i=next; begin=next;
    }
    out.append(source[begin..]); return out;
}
