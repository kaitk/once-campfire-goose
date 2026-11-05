// Graceful shutdown, as the Rust and Jai ports stop. The first SIGTERM (what docker stop sends) or
// SIGINT stops the HTTP loops: they close their listeners, so new connections are refused, and let
// the requests in flight finish. Every cable connection closes with Action Cable's server_restart,
// so its client reconnects to the next server rather than holding the loops open. The jobs queued
// (bot webhooks and Web Push, a room's deletion and a ban's removals, media processing) and those
// they queue in turn run meanwhile and after, all until the deadline, CAMPFIRE_SHUTDOWN_GRACE_MS
// after the signal. What is left then is lost and logged with a count, and the process exits 0. A
// second signal ends it at once (platform.c). Unfurl threads only answer requests, so they aren't
// waited for.
namespace campfire;

import std;
import http;
import cable;

extern fn campfire_stop_signals() -> i32;
extern fn campfire_stop_wait();
extern fn campfire_stopping() -> bool;
extern fn campfire_jobs_add(kind: i64, pending: i64, running: i64);
extern fn campfire_jobs_count(kind: i64, running: bool) -> i64;

// The kinds of job a shutdown waits for; JOBS_ALL counts them together.
let JOBS_DELIVERY: i64 = 0;
let JOBS_CLEANUP: i64 = 1;
let JOBS_MEDIA: i64 = 2;
let JOBS_ALL: i64 = -1;
// docker stop sends SIGKILL 10 seconds after SIGTERM: this leaves 2 of them for the last checkpoint
// and the exit.
let SHUTDOWN_GRACE_MS: i64 = 8000;

// The shutdown thread's report of the signal, and main's that the HTTP loops have returned.
struct ShutdownStarted { at: i64 = 0 }
struct LoopsEnded { at: i64 = 0 }

// perform_later: queues job, counted as pending until a thread has performed it. False, counting
// nothing, when its queue is full.
fn queue_job<T>(kind: i64, job: T) -> bool {
    campfire_jobs_add(kind, 1, 0);
    if qput(job) { return true; }
    campfire_jobs_add(kind, -1, 0);
    return false;
}

// A job thread took a job of kind, and finished it (or aborted in it).
fn job_started(kind: i64) { campfire_jobs_add(kind, 0, 1); }
fn job_finished(kind: i64) { campfire_jobs_add(kind, -1, -1); }

// Waits for the first signal, then stops the HTTP loops and closes the cable connections. The stop
// is repeated until main reports that the loops have returned, since a loop that starts after a stop
// (one signalled during boot) doesn't see it.
thread_fn shutdown_watcher(grace_ms: i64) {
    campfire_stop_wait();
    let at = campfire_clock_ms();
    qput(ShutdownStarted { at: at });
    write_stderr(str("Shutting down: requests in flight and ", campfire_jobs_count(JOBS_ALL, false),
        " queued or running jobs have ", grace_ms, " ms to finish\n"));
    campfire_access_note(ACCESS_RESTART, 0, 0);
    cable_command(CABLE_ACCESS, http::MailAddress { .. });
    loop {
        http::stop();
        let ended, done = qget<LoopsEnded>(100);
        if done { return; }
    }
}

// After the HTTP loops have returned: waits for the jobs, and those they queue, until grace_ms after
// the signal. True when none is left; otherwise logs what is lost.
fn finish_jobs(grace_ms: i64) -> bool {
    qput(LoopsEnded { at: campfire_clock_ms() });
    let started, signalled = qget<ShutdownStarted>(0);
    let deadline = (if signalled { started.at } else { campfire_clock_ms() }) + grace_ms;
    while campfire_jobs_count(JOBS_ALL, false) > 0 && campfire_clock_ms() < deadline { sleep_ms(10); }
    guard campfire_jobs_count(JOBS_ALL, false) > 0 else {
        write_stderr("Shutdown: every job finished\n");
        return true;
    }
    var report: u8[>..] = [];
    var queued: i64 = 0; var running: i64 = 0;
    for kind in 3 {
        let r = campfire_jobs_count(kind, true);
        let q = campfire_jobs_count(kind, false) - r;
        queued += q; running += r;
        format(report, if kind > 0 { ", " } else { "" }, if kind == JOBS_DELIVERY { "deliveries " } else if kind == JOBS_CLEANUP { "cleanups " } else { "media " }, q, "+", r);
    }
    write_stderr(str("Shutdown: ", queued, " queued and ", running, " running jobs are lost at the ",
        grace_ms, " ms deadline (queued+running: ", report, ")\n"));
    return false;
}
