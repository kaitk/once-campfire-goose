namespace campfire;
import std;
import os;
import sqlite;

fn sql_text(value) -> u8[] { return str(value); }

// A column of a row from sql_rows, "" past its end.
fn cell(row: const u8[][:], n: i64) -> const u8[:] {
    for value, i in row { if i == n { return value; } }
    return "";
}

fn sql_rows(db, query: const u8[:], args: u8[][]) -> u8[][][>..] {
    var q = sqlite::Stmt {};
    var result: u8[][][>..] = [];
    let failed = sqlite::run() {
        q = sqlite::prepare(db, query);
        for arg, i in args { sqlite::bind_text(q, i + 1, arg); }
        while sqlite::step(q) {
            var row: u8[][>..] = [];
            for i in sqlite::column_count(q) {
                var text: u8[>..] = [];
                sqlite::column_text(q, i, text);
                row.push(copy(text));
            }
            result.push(copy(row));
        }
    };
    sqlite::finalize(q);
    for error in failed { sqlite::fail(error.code, error.message); }
    return result;
}

fn sql_number(db, query: const u8[:], args: u8[][]) -> i64 {
    let rows = sql_rows(db, query, copy(args));
    for row in rows {
        for cell in row {
            let value, valid = parse_int(cell);
            return if valid { value } else { 0 };
        }
    }
    return 0;
}

fn sql_value(db, query: const u8[:], args: u8[][]) -> u8[] {
    let rows = sql_rows(db,query,copy(args));
    for row in rows { for cell in row { return copy(cell); } }
    return [];
}

// Rails' db/migrate, oldest first. A database must have run the first MIGRATIONS_90B3300, which
// Campfire at 90b3300 has; Goose runs the rest, which Rails main added, as db:prepare would.
let MIGRATIONS: const u8[:][18] = ["20231215043540", "20231220143106", "20240110071740", "20240115124901",
    "20240130003150", "20240130213001", "20240131105830", "20240209110503", "20250825100957", "20250825100958",
    "20250825100959", "20251126092013", "20251126115722", "20251126130131", "20251212154340",
    "20261004225000", "20261005022000", "20261007190000"];
let MIGRATIONS_90B3300: i64 = 15;
// The SHA1 of db/schema.rb, which db:schema:load records: Rails main's, and 90b3300's.
let SCHEMA_SHA1 = "aff2a42b1a9c498adc4eddf775976f2f09ecdedd";
let SCHEMA_SHA1_90B3300 = "f75da8dad38bfb179ffd757bd7a7c2b3f818bc29";

// Room::MessagesCount's triggers (app/models/room/messages_count.rb), as its heredocs write them:
// sqlite_master keeps the text.
let MESSAGES_COUNT_TRIGGERS: const u8[:][3] = [
    "CREATE TRIGGER messages_ai_rooms_messages_count AFTER INSERT ON messages\nBEGIN\n  UPDATE rooms SET messages_count = messages_count + 1 WHERE id = NEW.room_id;\nEND",
    "CREATE TRIGGER messages_ad_rooms_messages_count AFTER DELETE ON messages\nBEGIN\n  UPDATE rooms SET messages_count = messages_count - 1 WHERE id = OLD.room_id;\nEND",
    "CREATE TRIGGER messages_au_rooms_messages_count AFTER UPDATE OF room_id ON messages\nWHEN OLD.room_id IS NOT NEW.room_id\nBEGIN\n  UPDATE rooms SET messages_count = messages_count - 1 WHERE id = OLD.room_id;\n  UPDATE rooms SET messages_count = messages_count + 1 WHERE id = NEW.room_id;\nEND"];

fn has_migration(db, version: const u8[:]) -> bool {
    return sql_number(db, "SELECT count(*) FROM schema_migrations WHERE version=?", [sql_text(version)]) > 0;
}

fn record_migration(db, version: const u8[:]) {
    sql_rows(db, "INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)", [sql_text(version)]);
}

// ActiveRecord::InternalMetadata#[]=: a changed value keeps its created_at.
fn set_internal_metadata(db, key: const u8[:], value: const u8[:]) {
    var now: u8[>..] = []; campfire_sql_now(now);
    sql_rows(db, "INSERT INTO ar_internal_metadata(\"key\",\"value\",created_at,updated_at) VALUES(?1,?2,?3,?3) ON CONFLICT(\"key\") DO UPDATE SET \"value\"=excluded.\"value\",updated_at=excluded.updated_at WHERE \"value\" IS NOT excluded.\"value\"",
        [sql_text(key), sql_text(value), sql_text(now)]);
}

// Room::MessagesCount.ensure!, which Rails main runs after loading the schema, after migrating and at
// boot: with the column but not every trigger, drop the three, count each room's messages and create them.
fn ensure_messages_count(db) {
    if sql_number(db, "SELECT count(*) FROM pragma_table_info('rooms') WHERE name='messages_count'", []) == 0 { return; }
    if sql_number(db, "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name IN ('messages_ai_rooms_messages_count','messages_ad_rooms_messages_count','messages_au_rooms_messages_count')", []) == 3 { return; }
    sqlite::exec(db, "DROP TRIGGER IF EXISTS messages_ai_rooms_messages_count; DROP TRIGGER IF EXISTS messages_ad_rooms_messages_count; DROP TRIGGER IF EXISTS messages_au_rooms_messages_count");
    sqlite::exec(db, "UPDATE rooms SET messages_count = (SELECT COUNT(*) FROM messages WHERE messages.room_id = rooms.id)");
    for trigger in MESSAGES_COUNT_TRIGGERS { sqlite::exec(db, trigger); }
}

// The migrations Rails main added to 90b3300's.
fn migrate(db, version: const u8[:]) {
    if version == "20261004225000" {
        sqlite::exec(db, "CREATE INDEX IF NOT EXISTS \"index_messages_on_room_id_and_created_at\" ON \"messages\" (\"room_id\", \"created_at\")");
    } else if version == "20261005022000" {
        sqlite::exec(db, "CREATE INDEX IF NOT EXISTS \"index_messages_on_room_id_and_updated_at\" ON \"messages\" (\"room_id\", \"updated_at\")");
    } else if version == "20261007190000" {
        sqlite::exec(db, "ALTER TABLE \"rooms\" ADD \"messages_count\" integer DEFAULT 0 NOT NULL");
        ensure_messages_count(db);
    }
}

// bin/rails db:prepare, then Room::MessagesCount.ensure!, in one write transaction: an empty database
// gets Rails main's schema, recorded as db:schema:load records it, so the Rails image boots it as up to
// date; a 90b3300 database runs Rails main's migrations. A database from before 90b3300 is refused:
// boot the Rails image on it once. One without schema_migrations is no Rails one (a test's partial
// schema), and is left as it is.
fn initialize_database(path: const u8[:]) {
    var db = sqlite::Db {};
    let failed = sqlite::run() {
        db = sqlite::open(path, sqlite::READ_WRITE | sqlite::CREATE);
        sqlite::busy_timeout(db, 5000);
        sqlite::exec(db, "PRAGMA journal_mode=WAL; BEGIN IMMEDIATE");
        if sql_number(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", []) == 0 {
            var schema: u8[>..] = [];
            guard read_file("data/schema.sql", schema) else { sqlite::fail("Missing data/schema.sql"); }
            sqlite::exec(db, schema);
            // ActiveRecord's assume_migrated_upto_version: the schema's version, then every migration.
            record_migration(db, MIGRATIONS[MIGRATIONS.len - 1]);
            for version in MIGRATIONS { record_migration(db, version); }
            set_internal_metadata(db, "environment", "production");
            set_internal_metadata(db, "schema_sha1", SCHEMA_SHA1);
        } else if sql_number(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_migrations'", []) > 0 {
            // An earlier Goose loaded 90b3300's schema and recorded no migrations: record them as Rails
            // 8.1 did, newest first.
            if sql_number(db, "SELECT count(*) FROM schema_migrations", []) == 0 {
                for i in MIGRATIONS_90B3300 { record_migration(db, MIGRATIONS[MIGRATIONS_90B3300 - 1 - i]); }
                set_internal_metadata(db, "environment", "production");
                set_internal_metadata(db, "schema_sha1", SCHEMA_SHA1_90B3300);
                write_stderr("Database: recorded 90b3300's migrations, which this database's schema has\n");
            }
            var pending: u8[>..] = [];
            for version, i in MIGRATIONS {
                if i < MIGRATIONS_90B3300 && !has_migration(db, version) { pending.append(str(if pending.len > 0 { ", " } else { "" }, version)); }
            }
            guard pending.len == 0 else { sqlite::fail(str("pending migrations from before 90b3300 (boot the Rails image on this database once): ", pending)); }
            for version, i in MIGRATIONS {
                if i >= MIGRATIONS_90B3300 && !has_migration(db, version) {
                    migrate(db, version);
                    record_migration(db, version);
                    write_stderr(str("Database: migrated ", version, "\n"));
                }
            }
        }
        ensure_messages_count(db);
        sqlite::exec(db, "COMMIT");
    };
    let cleanup = sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db, "ROLLBACK"); } };
    sqlite::close(db);
    for error in failed { abort(str("Database initialization: ", error.message)); }
}
