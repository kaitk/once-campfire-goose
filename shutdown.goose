// The background jobs a shutdown waits for (bot webhooks and Web Push, a room's deletion and a ban's
// removals, media processing): each is counted from its queueing until a thread has performed it.
namespace campfire;

import std;

extern fn campfire_jobs_add(kind: i64, pending: i64, running: i64);
extern fn campfire_jobs_count(kind: i64, running: bool) -> i64;

// The kinds of job a shutdown waits for; JOBS_ALL counts them together.
let JOBS_DELIVERY: i64 = 0;
let JOBS_CLEANUP: i64 = 1;
let JOBS_MEDIA: i64 = 2;
let JOBS_ALL: i64 = -1;

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
