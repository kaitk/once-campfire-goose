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
        }
        sqlite::exec(db, "COMMIT");
    };
    let cleanup = sqlite::run() { if sqlite::in_transaction(db) { sqlite::exec(db, "ROLLBACK"); } };
    sqlite::close(db);
    for error in failed { abort(str("Database initialization: ", error.message)); }
}
