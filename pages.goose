namespace campfire;

import std;
import sqlite;
import assets;
import html;
import avatars;
import http;
import view_types;
import view_data;
import view_helpers;
import views_generated;

fn page_start(out: u8[>..]&, title: const u8[:]) {
    out.append("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>");
    escape(out, title);
    out.append("</title><link rel=\"stylesheet\" href=\"/assets/campfire.css\"></head><body><nav><a href=\"/users/me/sidebar\">Rooms</a><form action=\"/searches\"><input name=\"q\" aria-label=\"Search messages\" placeholder=\"Search messages\"><button>Search</button></form></nav>");
}

fn text_column(q: sqlite::Stmt, column: i64) -> u8[>..] {
    var text: u8[>..] = [];
    sqlite::column_text(q, column, text);
    return text;
}

fn sidebar(db: sqlite::Db, user: i64, key: const u8[:], ctx: ViewContext, bytes: u8[>..]&, out: u8[>..]&) {
    var q=sqlite::Stmt {}; var members=sqlite::Stmt {}; var placeholders=sqlite::Stmt {};
    var shared: RoomView[>..]=[]; var directs: DirectView[>..]=[]; var people: UserView[>..]=[]; var candidates: UserView[>..]=[];
    let failed=sqlite::run() {
        q=sqlite::prepare(db,"SELECT r.id,r.name,r.type,r.updated_at,m.unread_at FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? AND m.involvement<>'invisible' ORDER BY CASE WHEN r.type='Rooms::Direct' THEN r.updated_at END DESC,LOWER(r.name)"); sqlite::bind_i64(q,1,user);
        members=sqlite::prepare(db,"SELECT u.id,u.name,u.bio,u.updated_at,u.role FROM users u JOIN memberships m ON m.user_id=u.id WHERE m.room_id=? AND u.id<>?");
        while sqlite::step(q) {
            let room=room_view(q,bytes);
            if room.direct {
                var direct=DirectView { .. }; direct.room_id=room.id; direct.updated_at_epoch=view_keep(bytes,str(room.updated_ms));
                direct.classes=if sqlite::is_null(q,4) { "direct" } else { "direct unread" };
                sqlite::reset(members); sqlite::bind_i64(members,1,room.id); sqlite::bind_i64(members,2,user);
                let start=people.len; while sqlite::step(members) { people.push(user_view(members,0,key,bytes)); }
                if people.len==start { people.push(ctx.user); } direct.members=people[start..];
                var initials: u8[>..]=[];
                for i in direct.members.len {
                    if i>0 { initials.append(if direct.members.len==2 { "+" } else if i==direct.members.len-1 { ", and " } else { ", " }); }
                    var words=0; for word in split(direct.members[i].name," ") { if word.len>0 && words<3 { initials.append(capitalized(word[..1])); words+=1; } }
                }
                direct.initials=view_keep(bytes,initials); directs.push(direct);
            } else {
                room.classes=if sqlite::is_null(q,4) { "align-center gap room btn txt-nowrap" } else { "align-center gap room btn txt-nowrap unread" }; shared.push(room);
            }
        }
        placeholders=sqlite::prepare(db,"WITH excluded AS (SELECT DISTINCT m.user_id FROM memberships m WHERE m.room_id IN (SELECT r.id FROM rooms r JOIN memberships own ON own.room_id=r.id WHERE own.user_id=? AND r.type='Rooms::Direct')) SELECT u.id,u.name,u.bio,u.updated_at,u.role FROM users u WHERE u.status=0 AND u.id<>? AND u.id NOT IN excluded ORDER BY u.created_at LIMIT MAX(0,19-(SELECT COUNT(*) FROM excluded))");
        sqlite::bind_i64(placeholders,1,user); sqlite::bind_i64(placeholders,2,user); while sqlite::step(placeholders) { candidates.push(user_view(placeholders,0,key,bytes)); }
        ctx.other_memberships=shared; ctx.direct_memberships=directs; ctx.placeholders=candidates; render_sidebar_html(out,ctx);
    };
    sqlite::finalize(placeholders); sqlite::finalize(members); sqlite::finalize(q); for e in failed { sqlite::fail(e.code,e.message); }
}
