namespace campfire;
import std;
import sqlite;
import http;
import base64;
import json;
import hash;
import avatars;
import signed_id;
import html;
import emoji;
import view_types;
import view_helpers;
import view_assets_generated;
import rich_html;
import view_sounds;
import view_attachments;
import https;

extern fn campfire_epoch_ms(text: const u8[:]) -> i64;

fn view_keep(bytes: u8[>..]&, text: const u8[:]) -> const u8[:] {
    let start=bytes.len; bytes.append(text); return bytes[start..];
}

fn view_text(q: sqlite::Stmt, column: i64) -> u8[>..] {
    var text: u8[>..] = []; sqlite::column_text(q,column,text); return text;
}
fn version_number(time: const u8[:]) -> u8[>..] {
    var out: u8[>..] = []; for c in time[..min(19,time.len)] { if c >= '0' && c <= '9' { out.push(c); } } return out;
}
fn time_iso(time: const u8[:]) -> u8[>..] {
    var out: u8[>..] = []; out.append(time[..min(19,time.len)]); if out.len > 10 { out[10]='T'; } out.push('Z'); return out;
}
fn user_view(q: sqlite::Stmt, start: i64, key: const u8[:], bytes: u8[>..]&) -> UserView {
    var user=UserView { .. }; user.id=sqlite::column_i64(q,start); user.name=view_keep(bytes,view_text(q,start+1));
    let bio=view_text(q,start+2); user.title=view_keep(bytes,str(user.name,if bio.len > 0 && user.name.len > 0 { " – " } else { "" },bio));
    user.path=view_keep(bytes,str("/users/",user.id));
    user.avatar_url=view_keep(bytes,str(avatar_path(user.id,key),"?v=",version_number(view_text(q,start+3))));
    user.administrator=sqlite::column_i64(q,start+4)==1;
    let space=find(user.name," "); user.first_name=user.name[..if space < 0 { user.name.len } else { space }];
    return user;
}
fn load_user(db: sqlite::Db, id: i64, key: const u8[:], bytes: u8[>..]&) -> UserView {
    var q=sqlite::Stmt {}; var out=UserView { .. };
    let failed=sqlite::run() { q=sqlite::prepare(db,"SELECT id,name,bio,updated_at,role FROM users WHERE id=?"); sqlite::bind_i64(q,1,id); if sqlite::step(q) { out=user_view(q,0,key,bytes); } };
    sqlite::finalize(q); for e in failed { sqlite::fail(e.code,e.message); } return out;
}
fn signed_stream(name: const u8[:], key: const u8[:]) -> u8[>..] {
    var value: u8[>..] = []; json::format_string(value,name);
    var out: u8[>..] = []; base64::encode(out,value); let mac=hash::hmac_sha256(key,out); out.append("--");
    let digits="0123456789abcdef"; for c in mac { out.push(digits[c >> 4]); out.push(digits[c & 15]); } return out;
}
fn gid_param(record_kind: const u8[:], id: i64) -> u8[>..] {
    var out: u8[>..] = []; base64_url(out,str("gid://campfire/",record_kind,"/",id)); return out;
}
fn room_view(q: sqlite::Stmt, bytes: u8[>..]&) -> RoomView {
    var out=RoomView { .. }; out.id=sqlite::column_i64(q,0); out.name=view_keep(bytes,view_text(q,1)); out.display_name=out.name;
    let record_kind=view_text(q,2); out.direct=record_kind=="Rooms::Direct";
    out.kind=if record_kind=="Rooms::Open" { "rooms_open" } else if record_kind=="Rooms::Closed" { "rooms_closed" } else { "rooms_direct" };
    out.param_key=out.kind; out.dom_id=view_keep(bytes,str(out.kind,"_",out.id));
    out.noun=if out.direct { "Ping" } else { "room" };
    out.edit_path=view_keep(bytes,str("/rooms/",if record_kind=="Rooms::Open" { "opens" } else if out.direct { "directs" } else { "closeds" },"/",out.id,"/edit"));
    out.updated_ms=campfire_epoch_ms(view_text(q,3)); return out;
}

fn direct_room_name(db: sqlite::Db, room: i64, exclude_user: i64) -> u8[>..] {
    var q=sqlite::Stmt {}; var names: u8[][>..]=[]; var out: u8[>..]=[];
    let failed=sqlite::run() {
        q=sqlite::prepare(db,"SELECT u.name FROM users u JOIN memberships m ON m.user_id=u.id WHERE m.room_id=? AND u.id<>?");
        sqlite::bind_i64(q,1,room); sqlite::bind_i64(q,2,exclude_user);
        while sqlite::step(q) { names.push(view_text(q,0)); }
        var i: i64=0; for name in names {
            if i>0 { out.append(if names.len==2 { " and " } else if i==names.len-1 { ", and " } else { ", " }); }
            out.append(name); i+=1;
        }
    };
    sqlite::finalize(q); for e in failed { sqlite::fail(e.code,e.message); } return out;
}
// Users::PushSubscriptionsHelper#push_subscription_session_marker: the SHA-256, in hex, of
// "push-subscription-session-#{session.id}-#{session.created_at.to_f}", for a session created
// epoch seconds and fraction (its stored decimals) after the epoch. Float#to_s writes the shortest
// decimal that reads back as the same double: for a time this side of 2^52 seconds with at most
// six decimals, those decimals without trailing zeros, or ".0".
fn push_subscription_session_marker(id: i64, epoch: i64, fraction: const u8[:]) -> u8[>..] {
    var digits = fraction;
    while digits.len > 0 && digits[digits.len - 1] == '0' { digits = digits[..digits.len - 1]; }
    let text = str("push-subscription-session-", id, "-", epoch, ".", if digits.len > 0 { digits } else { "0" });
    let digest = hash::sha256(text);
    var out: u8[>..] = []; let hex = "0123456789abcdef";
    for c in digest { out.push(hex[c >> 4]); out.push(hex[c & 15]); }
    return out;
}

// The marker of the session that authenticated the worker's request (Current.session), "" for none.
struct SessionMarker { value: u8[..64] = [] }
var session_marker = SessionMarker { .. };

fn set_session_marker(value: const u8[:]) { session_marker.value = if value.len == 64 { value } else { value[..0] }; }
fn current_session_marker() -> const u8[:] { return session_marker.value[..]; }

fn load_view_context(db: sqlite::Db, id: i64, key: const u8[:], stream_key: const u8[:], vapid: const u8[:], req: const http::Request&, bytes: u8[>..]&, storage_key: const u8[:]) -> ViewContext {
    var ctx=ViewContext { .. }; ctx.user=load_user(db,id,key,bytes); ctx.title="Campfire";
    ctx.storage_key=view_keep(bytes,storage_key); ctx.stylesheet_tags=VIEW_STYLESHEET_TAGS; ctx.importmap_tags=VIEW_IMPORTMAP_TAGS; ctx.vapid_public_key=view_keep(bytes,vapid);
    ctx.base_url=view_keep(bytes,base_url(req)); ctx.session_marker=view_keep(bytes,current_session_marker());
    ctx.rooms_stream=view_keep(bytes,signed_stream("rooms",stream_key)); ctx.user_rooms_stream=view_keep(bytes,signed_stream(str(gid_param("User",id),":rooms"),stream_key));
    var q=sqlite::Stmt {};
    let failed=sqlite::run() {
        q=sqlite::prepare(db,"SELECT a.name,a.join_code,a.custom_styles,a.updated_at,a.settings,EXISTS(SELECT 1 FROM active_storage_attachments b WHERE b.record_type='Account' AND b.record_id=a.id AND b.name='logo') FROM accounts a LIMIT 1");
        if sqlite::step(q) {
            ctx.account.name=view_keep(bytes,view_text(q,0)); ctx.join_code=view_keep(bytes,view_text(q,1)); ctx.custom_styles=view_keep(bytes,view_text(q,2)); ctx.has_custom_styles=sqlite::column_type(q,2)!=sqlite::NULL;
            ctx.account.logo_url=view_keep(bytes,str("/account/logo?v=",version_number(view_text(q,3)))); ctx.account.has_logo=sqlite::column_i64(q,5)!=0;
            let settings_text=view_text(q,4); var nodes: json::Node[>..]=[]; var strings: u8[>..]=[]; let settings, error=json::parse(settings_text,nodes,strings);
            let restricted, valid=json::as_bool(json::member(settings,"restrict_room_creation_to_administrators")); ctx.can_create_rooms=ctx.user.administrator || !restricted;
        }
    };
    sqlite::finalize(q); for e in failed { sqlite::fail(e.code,e.message); }
    let agent, has_agent=http::field_of(req,"User-Agent");
    ctx.platform.android=find(agent,"Android")>=0; ctx.platform.ios=find(agent,"iPhone")>=0 || find(agent,"iPad")>=0;
    ctx.platform.windows=find(agent,"Windows")>=0; ctx.platform.edge=find(agent,"Edg/")>=0;
    ctx.platform.firefox=find(agent,"Firefox/")>=0; ctx.platform.chrome=!ctx.platform.edge && (find(agent,"Chrome/")>=0 || find(agent,"CriOS/")>=0);
    ctx.platform.safari=!ctx.platform.chrome && !ctx.platform.edge && find(agent,"Safari/")>=0;
    ctx.platform.desktop=!ctx.platform.android && !ctx.platform.ios && (ctx.platform.windows || find(agent,"Macintosh")>=0 || find(agent,"Linux")>=0);
    ctx.platform.browser=if ctx.platform.edge { "Edge" } else if ctx.platform.firefox { "Firefox" } else if ctx.platform.chrome { "Chrome" } else if ctx.platform.safari { "Safari" } else { "Mozilla" };
    ctx.platform.operating_system=if ctx.platform.windows { "Windows" } else if ctx.platform.ios { "iOS" } else if ctx.platform.android { "Android" } else if find(agent,"Macintosh")>=0 { "macOS" } else { "" };
    return ctx;
}

fn load_boosts(db: sqlite::Db, id: i64, key: const u8[:], bytes: u8[>..]&) -> BoostView[>..] {
    var out: BoostView[>..]=[]; var q=sqlite::Stmt {};
    let failed=sqlite::run() {
        q=sqlite::prepare(db,"SELECT b.id,b.content,u.id,u.name,u.bio,u.updated_at,u.role FROM boosts b JOIN users u ON u.id=b.booster_id WHERE b.message_id=? ORDER BY b.created_at"); sqlite::bind_i64(q,1,id);
        while sqlite::step(q) {
            var boost=BoostView { .. }; boost.id=sqlite::column_i64(q,0); boost.dom_id=view_keep(bytes,str("boost_",boost.id)); boost.path=view_keep(bytes,str("/messages/",id,"/boosts/",boost.id));
            boost.content=view_keep(bytes,view_text(q,1)); boost.booster=user_view(q,2,key,bytes); boost.all_emoji=all_emoji(boost.content); out.push(boost);
        }
    };
    sqlite::finalize(q); for e in failed { sqlite::fail(e.code,e.message); } return out;
}

fn mention_id(sgid: const u8[:]) -> i64 {
    // Campfire permits expired/legacy SGIDs for displaying User mentions only.
    // These display identifiers never authorize a request or a database write.
    let separator=find(sgid,"--"); if separator<0 { return 0; }
    var raw: u8[>..]=[]; if !base64_url_decode(raw,sgid[..separator]) { return 0; }
    var nodes: json::Node[>..]=[]; var strings: u8[>..]=[];
    let root,error=json::parse(raw,nodes,strings); let rails=json::member(root,"_rails");
    let data,has_data=json::as_string(json::member(rails,"data"));
    var gid: u8[>..]=[];
    if has_data { gid.append(data); } else {
        let message,has_message=json::as_string(json::member(rails,"message"));
        if !has_message || !base64_url_decode(gid,message) { return 0; }
    }
    let prefix="gid://campfire/User/"; let at=find(gid,prefix); if at<0 { return 0; }
    let start=at+prefix.len; var end=start; while end<gid.len && gid[end]>='0' && gid[end]<='9' { end+=1; }
    let id,valid=parse_int(gid[start..end]); return if valid { id } else { 0 };
}

fn expanded_rich_text(db: sqlite::Db, source: const u8[:], key: const u8[:]) -> u8[>..] {
    var out: u8[>..]=[]; var i: i64=0; var begin: i64=0;
    while i<source.len {
        if source[i]!='<' { i+=1; continue; }
        var attrs: RichAttr[>..]=[]; let tag=rich_tag(source,i,attrs);
        if tag.name!="action-text-attachment" || tag.closing { i=tag.end; continue; }
        let content_type=html_decode(rich_attribute(attrs,"content-type"));
        out.append(source[begin..i]);
        if find(content_type,OPENGRAPH_EMBED_TYPE)>=0 { let embed=og_embed_from_node(attrs,""); og_embed_html(out,embed); }
        else if content_type=="application/vnd.campfire.mention" {
            var bytes: u8[>..]=[]; let user=load_user(db,mention_id(rich_attribute(attrs,"sgid")),key,bytes);
            if user.id>0 {
                out.append("<span class=\"mention\"><a class=\"btn avatar\" title=\""); escape(out,user.title);
                out.append("\" href=\""); escape(out,user.path); out.append("\"><img src=\""); escape(out,user.avatar_url);
                out.append("\" width=\"48\" height=\"48\"></a> "); escape(out,user.name); out.append("</span>");
            }
        }
        let end=find(source[tag.end..],"</action-text-attachment>");
        i=if end<0 { tag.end } else { tag.end+end+25 }; begin=i;
    }
    out.append(source[begin..]); return out;
}

// ContentFilters::RemoveSoloUnfurledLinkText: a message that is only the link it previews shows the
// preview alone. A Trix body's divs each become the preview; a Lexxy body loses its paragraphs
// without an attachment.
fn solo_unfurled_link(source: const u8[:], plain: const u8[:]) -> u8[>..] {
    var embeds: i64=0; var from: i64=0; var to: i64=0; var href: u8[>..]=[]; var i: i64=0;
    while i<source.len {
        if source[i]!='<' { i+=1; continue; }
        var attrs: RichAttr[>..]=[]; let tag=rich_tag(source,i,attrs);
        if !tag.closing && tag.name=="action-text-attachment" && html_decode(rich_attribute(attrs,"content-type"))==OPENGRAPH_EMBED_TYPE {
            embeds+=1; let end=find(source[tag.end..],"</action-text-attachment>");
            from=i; to=if end<0 { tag.end } else { tag.end+end+25 };
            let embed=og_embed_from_node(attrs,""); href.clear(); href.append(embed.href);
        }
        i=tag.end;
    }
    if embeds!=1 || href.len==0 || tweet_normalized(href)!=tweet_normalized(plain) { return str(source); }
    var out: u8[>..]=[]; i=0; var begin: i64=0; let trix=find(source,"<div")>=0;
    while i<source.len {
        if source[i]!='<' { i+=1; continue; }
        var attrs: RichAttr[>..]=[]; let tag=rich_tag(source,i,attrs);
        let name=if trix { "div" } else { "p" };
        if tag.closing || tag.name!=name { i=tag.end; continue; }
        let close=find(source[tag.end..],str("</",name,">"));
        if close<0 { i=tag.end; continue; }
        let inner=source[tag.end..tag.end+close]; let after=tag.end+close+name.len+3;
        out.append(source[begin..i]);
        if trix { out.append(source[i..tag.end]); out.append(source[from..to]); out.append(str("</",name,">")); }
        else if find(inner,"<action-text-attachment")>=0 { out.append(source[i..after]); }
        i=after; begin=after;
    }
    out.append(source[begin..]); return out;
}

// normalize_tweet_url: a tweet's host as twitter.com, without its query.
fn tweet_normalized(url: const u8[:]) -> u8[>..] {
    if find(url,"x.com")<0 && find(url,"twitter.com")<0 { return str(url); }
    var out: u8[>..]=[]; let scheme=find(url,"://");
    if scheme<0 { return str(url); }
    var host_end=scheme+3; while host_end<url.len && url[host_end]!='/' && url[host_end]!='?' && url[host_end]!='#' { host_end+=1; }
    let host=html_lower(url[scheme+3..host_end]);
    out.append(url[..scheme+3]); out.append(if host=="x.com" { "twitter.com" } else { url[scheme+3..host_end] });
    let rest=url[host_end..]; let q=find(rest,"?");
    if q<0 { out.append(rest); } else { out.append(rest[..q]); let hash=find(rest[q..],"#"); if hash>=0 { out.append(rest[q+hash..]); } }
    return out;
}

fn text_presentation(db: sqlite::Db, rich: const u8[:], plain: const u8[:], key: const u8[:]) -> u8[>..] {
    var out: u8[>..]=[];
    if starts_with(plain,"/play ") {
        let name=plain[6..]; let content=sound_content(name);
        if content.len>0 {
            out.append("<div class=\"sound\" data-controller=\"sound\" data-action=\"messages:play-&gt;sound#play\" data-sound-url-value=\"");
            escape(out,asset_path(str(name,".mp3"))); out.append("\"><button class=\"btn btn--plain\" data-action=\"sound#play\">🔊</button>");
            out.append(content); out.append("</div>"); return out;
        }
    }
    out.append("<div class=\"lexxy-content\">\n  "); rich_sanitize(out,expanded_rich_text(db,solo_unfurled_link(sanitize_tags(rich),plain),key)); out.append("\n</div>\n"); return out;
}

fn message_view(db: sqlite::Db, q: sqlite::Stmt, key: const u8[:], storage_key: const u8[:], bytes: u8[>..]&, boosts: BoostView[>..]&) -> MessageView {
    var out=MessageView { .. }; out.id=sqlite::column_i64(q,0); out.dom_id=view_keep(bytes,str("message_",view_text(q,1)));
    out.room_id=sqlite::column_i64(q,8); out.room_name=view_keep(bytes,view_text(q,9));
    out.creator=load_user(db,sqlite::column_i64(q,5),key,bytes);
    if out.creator.id==0 { out.unrenderable=true; return out; }
    if view_text(q,10)=="Rooms::Direct" { out.room_name=view_keep(bytes,direct_room_name(db,out.room_id,0)); }
    out.created_ms=campfire_epoch_ms(view_text(q,6)); out.updated_ms=campfire_epoch_ms(view_text(q,7)); out.created_iso=view_keep(bytes,time_iso(view_text(q,6)));
    out.at_path=view_keep(bytes,str("/rooms/",out.room_id,"/@",out.id)); out.edit_path=view_keep(bytes,str("/rooms/",out.room_id,"/messages/",out.id,"/edit"));
    out.boosts_path=view_keep(bytes,str("/messages/",out.id,"/boosts")); out.new_boost_path=view_keep(bytes,str(out.boosts_path,"/new"));
    let start=boosts.len; boosts.append(load_boosts(db,out.id,key,bytes)); out.boosts=boosts[start..]; out.all_emoji=all_emoji(view_text(q,3));
    if attachment_presentation(db,out.id,storage_key,bytes,out) { return out; }
    out.presentation=view_keep(bytes,text_presentation(db,view_text(q,4),view_text(q,3),key)); return out;
}
