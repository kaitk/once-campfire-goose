// The jobs that finish a room's deletion and a ban, after the Rails reference at a05ee908:
// Room::DestroyJob and RemoveBannedContentJob. The request commits what takes access away (the room
// closed and its memberships deleted; the user banned and signed out) and queues the rest for a
// cleanup thread that runs no event loop, which deletes the messages a small batch per write
// transaction, so other writes get through in between, and their files after each. A crash midway
// leaves the rest, as a lost job leaves it in Rails.
namespace campfire;

import std;
import sqlite;
import http;
import database;
import messages;
import storage;
import cable;
import checkpoints;
import route_support;
import shutdown;

// A room to finish deleting (id), with its former members' ids, comma-separated, or a banned user
// whose messages to remove (id).
struct CleanupJob { kind: i64 = 0, id: i64 = 0, members: u8[] = [] }
let CLEANUP_ROOM: i64 = 1;
let CLEANUP_BANNED: i64 = 2;
let CLEANUP_QUEUE: i64 = 1024;
// The messages each write transaction deletes.
let CLEANUP_BATCH: i64 = 50;

struct CleanupSettings { storage: u8[..1024] = [] }

// perform_later, once the request's transaction committed. A full queue makes the request wait for room,
// as a job is never skipped.
fn destroy_room_later(room: i64, members: const u8[:]) {
    while !queue_job(JOBS_CLEANUP, CleanupJob { kind: CLEANUP_ROOM, id: room, members: str(members) }) { sleep_ms(10); }
}

fn remove_banned_content_later(user: i64) {
    while !queue_job(JOBS_CLEANUP, CleanupJob { kind: CLEANUP_BANNED, id: user }) { sleep_ms(10); }
}

// Restarts the cleanup thread if it aborted, so one bad job can't stop the rest.
thread_fn cleanup_supervisor(database: u8[], settings: CleanupSettings) {
    loop {
        let worker = thread_spawn_contained(cleanup_worker, copy(database), settings);
        var message: u8[>..] = [];
        if thread_wait(worker, message) { return; }
        // The job it aborted in is done with.
        job_finished(JOBS_CLEANUP);
        write_stderr(str("Cleanup thread restarts after: ", message, "\n"));
        sleep_ms(100);
    }
}

thread_fn cleanup_worker(database: u8[], settings: CleanupSettings) {
    var db = sqlite::Db {};
    let failed = sqlite::run() {
        db = sqlite::open(database, sqlite::READ_WRITE);
        sqlite::busy_timeout(db, 5000);
        sqlite::exec(db, "PRAGMA synchronous=NORMAL; PRAGMA cache_size=200;");
        let wal = campfire_track_wal(db.id); if wal != 0 { sqlite::fail(wal, "Cannot install WAL observer"); }
    };
    if failed.len > 0 {
        for e in failed { write_stderr(str("Cleanup thread cannot open the database: ", e.message, "\n")); }
        return;
    }
    loop {
        let job = qget<CleanupJob>();
        job_started(JOBS_CLEANUP);
        if job.kind == CLEANUP_ROOM { destroy_room(db, settings.storage, job.id, job.members); }
        else if job.kind == CLEANUP_BANNED { remove_banned_content(db, settings.storage, job.id); }
        job_finished(JOBS_CLEANUP);
    }
}

// Message#destroy for the messages ids lists (comma-separated integers): the attachment and rich-text
// embeds purged as `dependent: :destroy` purges them, the boosts, the search entry, the rich text and the
// row. The purged blobs' keys go to keys, for their files to be deleted once this commits.
fn destroy_messages(db, ids: const u8[:], keys: u8[][>..]&) {
    let list = str("(", ids, ")");
    purge_attachments(db, str("(record_type='Message' AND name='attachment' AND record_id IN ", list, ") OR (record_type='ActionText::RichText' AND record_id IN (SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id IN ", list, "))"), [], keys);
    sql_rows(db, str("DELETE FROM boosts WHERE message_id IN ", list), []);
    sql_rows(db, str("DELETE FROM message_search_index WHERE rowid IN ", list), []);
    sql_rows(db, str("DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id IN ", list), []);
    sql_rows(db, str("DELETE FROM messages WHERE id IN ", list), []);
}

// Room::DestroyJob: reset_remote_connections_of the former members, as the job does after the request's
// sidebar removal went out, then destroy_one_message_at_a_time (here a batch at a time) and the room.
fn destroy_room(db: sqlite::Db, storage: const u8[:], room: i64, members: const u8[:]) {
    var changes: i64[>..] = [];
    for part in split(members, ',') {
        let member, valid = parse_int(part);
        if valid && member > 0 { changes.push(ACCESS_RESET); changes.push(member); changes.push(0); }
    }
    var done = false;
    while !done {
        var keys: u8[][>..] = [];
        // The resets are logged with the first batch's commit.
        let failed = write_access_transaction(db, changes) {
            var ids: u8[>..] = [];
            for row in sql_rows(db, "SELECT id FROM messages WHERE room_id=? ORDER BY id LIMIT ?", [sql_text(room), sql_text(CLEANUP_BATCH)]) {
                if ids.len > 0 { ids.push(','); }
                ids.append(cell(row, 0));
            }
            if ids.len > 0 { destroy_messages(db, ids, keys); }
            else {
                // Room#destroy, with whatever memberships it still has.
                sql_rows(db, "DELETE FROM memberships WHERE room_id=?", [sql_text(room)]);
                sql_rows(db, "DELETE FROM rooms WHERE id=?", [sql_text(room)]);
                done = true;
            }
        };
        changes.clear();
        if failed.len > 0 {
            for e in failed { write_stderr(str("Deleting room ", room, " failed: ", e.message, "\n")); }
            return;
        }
        delete_blob_files(storage, keys);
    }
}

// RemoveBannedContentJob: User::Bannable#remove_banned_content, each of the user's messages destroyed and
// its removal broadcast to its room's stream (message_<id>, as dom_id gives it); here a batch per write
// transaction, with one publication per room of each batch.
fn remove_banned_content(db: sqlite::Db, storage: const u8[:], user: i64) {
    loop {
        var keys: u8[][>..] = [];
        // The batch's messages and their rooms, in id order.
        var messages: i64[>..] = []; var rooms: i64[>..] = [];
        var now: u8[>..] = []; campfire_sql_now(now);
        let failed = write_transaction(db) {
            var ids: u8[>..] = [];
            for row in sql_rows(db, "SELECT id,room_id FROM messages WHERE creator_id=? ORDER BY id LIMIT ?", [sql_text(user), sql_text(CLEANUP_BATCH)]) {
                if ids.len > 0 { ids.push(','); }
                ids.append(cell(row, 0));
                let message, valid = parse_int(cell(row, 0)); let room, known = parse_int(cell(row, 1));
                messages.push(message); rooms.push(room);
            }
            if ids.len > 0 {
                // belongs_to :room, touch: true
                sql_rows(db, str("UPDATE rooms SET updated_at=? WHERE id IN (SELECT room_id FROM messages WHERE id IN (", ids, "))"), [sql_text(now)]);
                destroy_messages(db, ids, keys);
            }
        };
        if failed.len > 0 {
            for e in failed { write_stderr(str("Removing banned user ", user, "'s messages failed: ", e.message, "\n")); }
            return;
        }
        delete_blob_files(storage, keys);
        for room, i in rooms {
            // Each room once, at its first message.
            var first = true; for j in i { if rooms[j] == room { first = false; } }
            if !first { continue; }
            var stream: u8[>..] = [];
            for message, j in messages { if rooms[j] == room { format(stream, "<turbo-stream action=\"remove\" target=\"message_", message, "\"></turbo-stream>"); } }
            let permit, admitted = qget<CablePermit>(60000);
            if admitted { publish(room, http::MailAddress { .. }, stream); }
            else { write_stderr(str("Banned user ", user, "'s removals in room ", room, " skipped: live delivery is busy\n")); }
        }
        if messages.len < CLEANUP_BATCH { return; }
    }
}
