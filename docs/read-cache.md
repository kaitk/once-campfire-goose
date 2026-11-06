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
with one body per entry and the worker's encoder, and 23.0 MiB with the cache off.

The same copies are made once in each worker when `compress` first builds its one-shot gzip
encoder (and its zstd encoder, about 950 KB, for a client that prefers zstd): four dead copies
of 450 KB per worker. The worker calls `trim_memory` once after either is built, at the end of
that request, which returns their pages; `trim_memory` came with the compiler at `acf44851`,
which `dependencies.json` pins. After the same load, `RssAnon` is 14.0 MiB.

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

## Avatars and assets

An avatar's response is kept whole in the same page cache: everything after the fields
`http::start` writes (the status line and the common fields, whose Date is the hit's own), the
middlewares' fields and the body included. It is kept for an HTTP/1.1 keep-alive GET answered at
once with a 200 or 304, without a resumed session's cookie, and up to 64 KiB, and answers the same
user's request with the same target and header bytes only. Like a page, it is dropped when the
database changes, by a write in another process included, so a new avatar, its variant, a
rename or a deletion is seen at once; an avatar token with an expiry, a variant still being made
and the queue-full fallback are not kept. A hit costs what a page hit does, on the certified fast
path or after routing on the ordinary one, and skips the token's HMAC, the five-table query, the
ETag's SHA-256 and the file's open and read. Entries count against the page cache's limits.

ActionDispatch::Static answers before the read transaction, which it never needed. Each worker
keeps a digested asset of up to 64 KiB, with its gzip at the compression level the response uses,
on first request, within `CAMPFIRE_ASSET_CACHE` bytes (512 KiB by default; 0 keeps none); an asset
past either is read and compressed each time, as before. A digested asset's name is its digest, so
what is kept is never read again; public/ files are always read. The responses are unchanged:
Last-Modified is the kept file's modification time, and Range, If-Modified-Since, HEAD, deflate and
zstd are answered from the kept bytes as from the file's.

On the M1 (arm64 Docker, app on four cores, 16 clients, fresh seed copies, three alternating
rounds, medians), server CPU per request fell from 54.5 to 13.5 µs for the harness's avatar and
from 34.2 to 13.3 µs for its stylesheet, against 17.9 µs for a cached room page; throughput rose
from 57,332 to 119,348 and from 90,324 to 120,991 requests per second, the stylesheet then at the
load generator's limit on that machine. `RssAnon` after the harness's routes was unchanged at
14.3 MiB. After every asset was fetched eight times with gzip over 16 connections it was 26.8 MiB
against 25.9 MiB.
