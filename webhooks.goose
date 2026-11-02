// Bot::WebhookJob and Webhook#deliver (app/jobs/bot/webhook_job.rb, app/models/webhook.rb): a
// bot's webhook gets the message as JSON, and a text answer becomes the bot's reply in the room.
// Message posts enqueue WebhookJobs (messages.goose); delivery threads that run no event loop
// take them, so a slow or failing endpoint never holds an HTTP worker or an acknowledgement.
namespace campfire;

import std;
import sqlite;
import http;
import http.client;
import hash;
import database;
import messages;
import sessions;
import checkpoints;
import cable;
import html;
import rich_html;
import view_types;
import view_data;

// Webhook::ENDPOINT_TIMEOUT: the connect's limit, and each read's.
let WEBHOOK_TIMEOUT_MS: i64 = 7000;
// The largest webhook answer read. Rails reads any size; replies here are text messages.
let WEBHOOK_MAX_BODY: i64 = 1 << 20;

struct WebhookKeys { avatar: u8[64] = [0; 64], storage: u8[64] = [0; 64], sgid: u8[64] = [0; 64] }

// Restarts a delivery thread that aborted, so one bad delivery can't stop the rest.
thread_fn webhook_supervisor(database: u8[], keys: WebhookKeys) {
    loop {
        let worker=thread_spawn_contained(webhook_worker,copy(database),keys);
        var message: u8[>..]=[];
        if thread_wait(worker,message) { return; }
        write_stderr(str("Bot webhook delivery restarts after: ",message,"\n"));
        sleep_ms(100);
    }
}

thread_fn webhook_worker(database: u8[], keys: WebhookKeys) {
    var db=sqlite::Db {};
    var writer=WriterStatements { .. };
    let failed=sqlite::run() {
        db=sqlite::open(database,sqlite::READ_WRITE);
        sqlite::busy_timeout(db,5000);
        sqlite::exec(db,"PRAGMA synchronous=NORMAL; PRAGMA cache_size=200;");
        prepare_writer(db,writer);
        let wal=campfire_track_wal(db.id); if wal!=0 { sqlite::fail(wal,"Cannot install WAL observer"); }
    };
    if failed.len>0 {
        for e in failed { write_stderr(str("Bot webhook delivery cannot open the database: ",e.message,"\n")); }
        return;
    }
    writer.sgid_key=keys.sgid;
    var session=http::session(WEBHOOK_TIMEOUT_MS);
    session.max_body=WEBHOOK_MAX_BODY;
    loop {
        let job=qget<WebhookJob>();
        deliver_webhook(db,writer,session,job,keys);
    }
}

// Bot::WebhookJob#perform: bot.deliver_webhook(message), i.e. webhook.deliver(message).
fn deliver_webhook(db: sqlite::Db, writer: const WriterStatements&, session: http::Session&, job: WebhookJob, keys: const WebhookKeys&) {
    var url: u8[>..]=[]; var payload: u8[>..]=[];
    var room: i64=0;
    let failed=sqlite::run() { room=webhook_payload(db,job,keys.sgid,url,payload); };
    for e in failed { write_stderr(str("Bot webhook for bot ",job.bot,", message ",job.message,": ",e.message,"\n")); return; }
    guard room>0 else { write_stderr(str("Bot webhook for bot ",job.bot,", message ",job.message,": no webhook or message\n")); return; }

    let response, err = http::post(session, url) { req => http::body(req, "application/json", payload); };
    // Net::HTTP's connection lasts the one request.
    http::hangup(session);
    if err.code!=0 {
        // Net::OpenTimeout and Net::ReadTimeout are answered in the room; anything else fails the job.
        if err.code==http::ETIMEDOUT && err.call!="send" {
            reply_to(db,writer,keys,job.bot,room,str("Failed to respond within ",WEBHOOK_TIMEOUT_MS/1000," seconds"));
        } else {
            write_stderr(str("Bot webhook for bot ",job.bot,", message ",job.message," failed: ",err.call," error ",err.code,"\n"));
        }
        return;
    }
    let media=media_type(response);
    guard response.status==200 && media.len>0 else { return; }
    if media=="text/html" || media=="text/plain" {
        // extract_text_from: the body as UTF-8, the reply's rich text.
        var text: u8[>..]=[]; utf8_lossy(text,response.body);
        if text.len>0 { reply_to(db,writer,keys,job.bot,room,text); }
    } else {
        write_stderr(str("Bot webhook for bot ",job.bot,", message ",job.message,": ",media," replies (attachments) are not supported\n"));
    }
}

// Net::HTTPHeader#content_type: the media type, lowercased, without parameters; "" for none.
fn media_type(response: const http::ClientResponse&) -> u8[>..] {
    let field, has = http::header(response, "Content-Type");
    var out: u8[>..]=[];
    guard has else { return out; }
    let semicolon=find(field,";");
    let whole=if semicolon<0 { field } else { field[..semicolon] };
    let slash=find(whole,"/");
    if slash<0 { out.append(trim(whole)); }
    else {
        let rest=whole[slash+1..]; let next=find(rest,"/");
        out.append(trim(whole[..slash])); out.push('/'); out.append(trim(if next<0 { rest } else { rest[..next] }));
    }
    to_lower(out);
    return out;
}

// Webhook#payload into payload, in its hash order, and the webhook URL; the message's room, or 0
// when the bot has no webhook or the message is gone.
fn webhook_payload(db: sqlite::Db, job: WebhookJob, sgid_key: const u8[:], url: u8[>..]&, payload: u8[>..]&) -> i64 {
    var q=sqlite::Stmt {};
    var found=false;
    var bot_name: u8[>..]=[]; var bot_token: u8[>..]=[];
    var room: i64=0; var creator: i64=0; var creator_name: u8[>..]=[]; var room_name: u8[>..]=[]; var room_named=false;
    var body: u8[>..]=[]; var has_body=false;
    let failed=sqlite::run() {
        q=sqlite::prepare(db,"SELECT w.url,u.name,u.bot_token FROM users u JOIN webhooks w ON w.user_id=u.id WHERE u.id=? ORDER BY w.id LIMIT 1");
        sqlite::bind_i64(q,1,job.bot);
        if sqlite::step(q) {
            sqlite::column_text(q,0,url); sqlite::column_text(q,1,bot_name); sqlite::column_text(q,2,bot_token);
            sqlite::finalize(q); q=sqlite::Stmt {};
            q=sqlite::prepare(db,"SELECT m.room_id,m.creator_id,c.name,r.name,t.body FROM messages m JOIN users c ON c.id=m.creator_id JOIN rooms r ON r.id=m.room_id LEFT JOIN action_text_rich_texts t ON t.record_type='Message' AND t.record_id=m.id AND t.name='body' WHERE m.id=?");
            sqlite::bind_i64(q,1,job.message);
            if sqlite::step(q) {
                room=sqlite::column_i64(q,0); creator=sqlite::column_i64(q,1); sqlite::column_text(q,2,creator_name);
                room_named=!sqlite::is_null(q,3); sqlite::column_text(q,3,room_name);
                has_body=!sqlite::is_null(q,4); sqlite::column_text(q,4,body);
                found=true;
            }
        }
    };
    sqlite::finalize(q);
    for e in failed { sqlite::fail(e.code,e.message); }
    guard found else { return 0; }

    var mentions: i64[>..]=[];
    let text=if find(body,"<action-text-attachment")>=0 { mention_plain(db,body,sgid_key,mentions) } else { rich_plain(body) };
    // without_recipient_mentions: the bot's own @Name removed, then surrounding whitespace.
    var plain: u8[>..]=[]; format_replaced(plain,text,str("@",bot_name),"");

    let out .= payload;
    format(out,"{\"user\":{\"id\":",creator,",\"name\":"); json_rails(out,creator_name);
    format(out,"},\"room\":{\"id\":",room,",\"name\":");
    if room_named { json_rails(out,room_name); } else { out.append("null"); }
    out.append(",\"path\":"); json_rails(out,str("/rooms/",room,"/",job.bot,"-",bot_token,"/messages"));
    format(out,"},\"message\":{\"id\":",job.message,",\"body\":{\"html\":");
    if has_body { json_rails(out,body); } else { out.append("null"); }
    out.append(",\"plain\":"); json_rails(out,trim_unicode(plain));
    out.append("},\"path\":"); json_rails(out,str("/rooms/",room,"/@",job.message)); out.append("}}");
    return room;
}

// receive_text_reply_to: room.messages.create!(body: text, creator: bot).broadcast_create, through
// the commit and publication every message takes. It holds a publication permit before writing.
fn reply_to(db: sqlite::Db, writer: const WriterStatements&, keys: const WebhookKeys&, bot: i64, room: i64, text: const u8[:]) {
    let permit, admitted = qget<CablePermit>(60000);
    guard admitted else { write_stderr(str("Bot ",bot," reply to room ",room," skipped: live delivery is busy\n")); return; }
    var status: i32=0; var html: u8[>..]=[];
    let failed=sqlite::run() {
        var rich: u8[>..]=[]; var mentions: i64[>..]=[];
        let plain=message_body(db,text,keys.sgid,rich,mentions);
        var bytes: u8[>..]=[]; var ctx=ViewContext { storage_key: keys.storage[..], .. }; ctx.user=load_user(db,bot,keys.avatar,bytes);
        var now: u8[>..]=[]; campfire_sql_now(now);
        let created, message, direct = create_message(db,writer,bot,room,random_uuid(),rich,plain,now,keys.avatar,ctx,bytes,0,html);
        status=created;
    };
    for e in failed { write_stderr(str("Bot ",bot," reply to room ",room," failed: ",e.message,"\n")); }
    if failed.len>0 || status!=200 {
        if failed.len==0 { write_stderr(str("Bot ",bot," reply to room ",room," failed: status ",status,"\n")); }
        qput(CablePermit { .. });
        return;
    }
    // No HTTP request waits for this publication's acknowledgement.
    publish(room,http::MailAddress { .. },html);
}

// Random.uuid, as a message's default client_message_id.
fn random_uuid() -> u8[>..] {
    var b: u8[16]=[0;16]; hash::random_bytes(b);
    b[6]=(b[6] & 0x0f) | 0x40; b[8]=(b[8] & 0x3f) | 0x80;
    var out: u8[>..]=[]; let digits="0123456789abcdef";
    for c, i in b {
        if i==4 || i==6 || i==8 || i==10 { out.push('-'); }
        out.push(digits[c >> 4]); out.push(digits[c & 15]);
    }
    return out;
}

// bytes as UTF-8, each invalid sequence replaced by U+FFFD.
fn utf8_lossy(out: u8[>..]&, bytes: const u8[:]) {
    var i: i64=0;
    while i<bytes.len {
        let c=bytes[i];
        var n: i64=0; var low: u8=0x80; var high: u8=0xBF;
        if c<0x80 { out.push(c); i+=1; continue; }
        else if c>=0xC2 && c<=0xDF { n=1; }
        else if c==0xE0 { n=2; low=0xA0; }
        else if c>=0xE1 && c<=0xEC || c==0xEE || c==0xEF { n=2; }
        else if c==0xED { n=2; high=0x9F; }
        else if c==0xF0 { n=3; low=0x90; }
        else if c>=0xF1 && c<=0xF3 { n=3; }
        else if c==0xF4 { n=3; high=0x8F; }
        var valid=n>0; var j: i64=1;
        while valid && j<=n {
            if i+j>=bytes.len { valid=false; }
            else {
                let d=bytes[i+j];
                if j==1 { valid=d>=low && d<=high; } else { valid=d>=0x80 && d<=0xBF; }
            }
            if valid { j+=1; }
        }
        if valid { out.append(bytes[i..i+n+1]); i+=n+1; }
        else { out.append("\xEF\xBF\xBD"); i+=if j>1 { j } else { 1 }; }
    }
}

// The length of the Unicode White_Space character at i, or 0.
fn space_at(s: const u8[:], i: i64) -> i64 {
    let c=s[i];
    if c>=0x09 && c<=0x0D || c==0x20 { return 1; }
    if c==0xC2 && i+1<s.len && (s[i+1]==0x85 || s[i+1]==0xA0) { return 2; }
    if i+2>=s.len { return 0; }
    let b1=s[i+1]; let b2=s[i+2];
    if c==0xE1 && b1==0x9A && b2==0x80 { return 3; }
    if c==0xE2 && b1==0x80 && (b2>=0x80 && b2<=0x8A || b2==0xA8 || b2==0xA9 || b2==0xAF) { return 3; }
    if c==0xE2 && b1==0x81 && b2==0x9F { return 3; }
    if c==0xE3 && b1==0x80 && b2==0x80 { return 3; }
    return 0;
}

// s without leading and trailing \p{Space}.
fn trim_unicode(s: const u8[:]) -> const u8[:] {
    var start: i64=0; var end=s.len;
    while start<end { let n=space_at(s,start); if n==0 { break; } start+=n; }
    while end>start {
        var i=end-1;
        while i>start && (s[i] & 0xC0)==0x80 { i-=1; }
        if space_at(s,i)!=end-i { break; }
        end=i;
    }
    return s[start..end];
}

// A JSON string as ActiveSupport's to_json writes it: <, >, &, U+2028 and U+2029 escaped too.
fn json_rails(out: u8[>..]&, raw: const u8[:]) {
    var s: u8[>..]=[]; utf8_lossy(s,raw);
    let hex="0123456789abcdef";
    out.push('"');
    var i: i64=0;
    while i<s.len {
        let c=s[i];
        if c=='"' { out.append("\\\""); }
        else if c=='\\' { out.append("\\\\"); }
        else if c=='\n' { out.append("\\n"); }
        else if c=='\r' { out.append("\\r"); }
        else if c=='\t' { out.append("\\t"); }
        else if c==8 { out.append("\\b"); }
        else if c==12 { out.append("\\f"); }
        else if c<0x20 { out.append("\\u00"); out.push(hex[c >> 4]); out.push(hex[c & 15]); }
        else if c=='<' { out.append("\\u003c"); }
        else if c=='>' { out.append("\\u003e"); }
        else if c=='&' { out.append("\\u0026"); }
        else if c==0xE2 && i+2<s.len && s[i+1]==0x80 && (s[i+2]==0xA8 || s[i+2]==0xA9) {
            out.append(if s[i+2]==0xA8 { "\\u2028" } else { "\\u2029" }); i+=2;
        }
        else { out.push(c); }
        i+=1;
    }
    out.push('"');
}
