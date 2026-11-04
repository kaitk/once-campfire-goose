# Read-cache validation

Each HTTP worker owns its page cache. Entries store the authenticated user ID, exact request
target and complete header bytes, followed by the one body the entry can send. Comparing the
two request slices directly avoids allocating a formatted key on a hit. Different headers may
cause extra misses; they cannot accidentally select another request's cached response.
Entries also retain their negotiated compression type: identical header bytes have the
same negotiation result. So a gzip entry keeps only the gzip body and the identity length,
and every other entry only the plain body, which deflate and zstd compress on each hit.
HEAD always suppresses the body and uses its identity length, including when a HEAD request
populated the cache before a GET.

Cached pages use gzip level 6. For the measured room, this produces 20,877 bytes instead of
level 1's 28,522. A ten-iteration encoding probe measured approximately 0.82 ms versus
0.67 ms per encoding; these are isolated encoder timings, not whole-page latency. Level 9
saved only another 928 bytes while taking approximately 1.59 ms. Message POST compression
uses the existing HTTP compression path.

The gzip body comes from `compress::compress`, whose per-worker encoder is reset in place and
codes as a new one would. A new `compress::Encoder` is built through several whole copies of
its 450 KB, each on a data stack of its own, whose pages stay resident. Building one per miss,
as the cache did, and keeping both bodies cost about 4 MiB per worker after the four harness
read routes: `RssAnon` was 39.4 MiB at four workers and 64 connections, against 23.2 MiB
now and 23.0 MiB with the cache off.

The same copies are made once in each worker when `compress` first builds its one-shot gzip
encoder (and its zstd encoder, about 950 KB, for a client that prefers zstd): four dead copies
of 450 KB per worker. The worker calls `trim_memory` once after either is built, at the end of
that request, which returns their pages; that needs the compiler at `acf44851`, which adds it.
After the same load, `RssAnon` is 14.0 MiB.

The ordinary path opens a SQLite read transaction, reads `PRAGMA data_version`, and performs
authentication, authorization and rendering against that snapshot. A changed version clears
both page and authentication caches. Mutating HTTP requests clear the worker cache as well.

On Linux, the pinned SQLite shim can certify that a previously completed read transaction's
database state is still current. It reads both copies of SQLite 3.54.1's `WalIndexHdr` through
the connection's VFS shared-memory mapping, with SQLite's read order and memory barrier.
The copies must match, have the expected format and initialization flag, and pass the native
header checksum. The complete 48-byte header is compared, including both salts and the frame
number, so WAL restarts and writes from other processes invalidate the certificate.

A certificate is installed only when the header is unchanged before and after the complete
ordinary read path. It expires at the next wall-clock second. A fast hit also requires the
same authenticated cookie, an unexpired signed-cookie timestamp, and an exact cached request.
Changed, unavailable or inconsistent WAL state goes through SQL again. Unknown WAL layouts
disable this path. The certificate never authorizes a newly seen request or extends a cookie's
expiry. SQLite's locking and write durability settings are unchanged.

The clock adapter caches only the formatted calendar prefix within each second, per thread.
Every call still samples the clock and formats its current fractional time. Signed-cookie
expiry therefore retains millisecond precision, including within a single cached second.

The design follows SQLite's `walIndexTryHdr` protocol; Jai's published
[WAL generation check](https://github.com/lucasmeijer/once-campfire-jai/blob/2ecd487/src/framework/db/database.jai)
also demonstrates using that protocol for response replay. This implementation retains the
existing Goose HTTP response path and uses a small C adapter for SQLite's opaque VFS handles.

With `CAMPFIRE_CACHE_DIAGNOSTICS=1`, `X-Campfire-Snapshot: wal` identifies a certified hit;
`transaction` identifies the ordinary path. The HTTP regression suite verifies the fast path
actually executes, then exercises cookie expiry, external edits and revocation, uncommitted
and rolled-back writes, and a truncated/restarted WAL.
