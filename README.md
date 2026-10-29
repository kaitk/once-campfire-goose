# Campfire in Goose

An experimental Campfire implementation in [Goose](https://github.com/aardappel/goose).
The implemented HTTP routes pass the shared response contracts and persisted-write audits.
Rendering matches 27 differential cases against the pinned Rust and Jai references.
Fresh setup, invitations, live messaging, edits, profile/account forms, rooms, bots, session
transfers, QR codes and direct-ping creation are implemented. The unmodified shared Chromium
smoke test covers these flows. Full application compatibility is still in progress; see
[browser coverage and delivery semantics](docs/browser-parity.md).

## Build and test

Docker builds the public Goose compiler and packages at the immutable revisions in
`dependencies.json`. The 315 frontend files are vendored and SHA-256 checked against
`views/assets.json`; building never starts a reference server or needs a fixture database.

```sh
docker build --target test -t once-campfire-goose:test .
docker build --build-arg GIT_REVISION="$(git rev-parse HEAD)" -t once-campfire-goose:app .
python3 test_image.py once-campfire-goose:app
python3 test_browser.py once-campfire-goose:app
```

For a Linux development build with Clang, CMake, Ninja, Python 3, Git, liburing-dev,
libssl-dev, libcrypt-dev and libqrencode-dev installed, run `sh build_linux.sh`.
Build products and dependency checkouts stay under ignored `build/`.

## Run against disposable Campfire storage

```sh
docker run --rm -p 3000:3000 --env-file campfire.env \
  -v /absolute/path/to/storage:/rails/storage once-campfire-goose:app
```

The environment file supplies `SECRET_KEY_BASE` matching that database's Rails signing secret.
The database is `/rails/storage/db/production.sqlite3`; blob files are in `/rails/storage/files`.
Storage must be writable by UID 1000. An empty database is initialized from the pinned schema;
visit `/first_run` to create the account and administrator. Existing Campfire databases are preserved.
`HTTP_PORT` defaults to 3000 in the image, `CAMPFIRE_HTTP_THREADS` to 4, and `CAMPFIRE_CACHE=0`
disables response caching. `DATABASE_PATH` and `STORAGE_PATH` override storage locations.
`CAMPFIRE_HTTP_MAX_CONNS` (64–65536, default 1024) sets each worker's connection limit and
waiting cable exchanges; raise it for rooms with more than about 4,000 open WebSockets.
`CAMPFIRE_HTTP_BACKEND` defaults to `epoll`, the direct Linux loop usable in ordinary Docker.
`auto` probes for native io_uring and selects epoll when unavailable. `uring` requires native
io_uring and refuses emulation; `emulated` explicitly selects the ring emulation for comparisons.
The selected backend is logged at startup. For `uring` on Linux 6.1 or later, generate and pass the optional
[container seccomp profile](docs/send-copy-pr.md#local-native-io_uring-setup).
TLS should terminate at a reverse proxy; application deployment compatibility is still in progress.

## Pinned HTTP dependency

The build pins upstream goose-http including the merged
[drain notification PR #2](https://github.com/kaitk/goose-http/pull/2).
The application uses these credits to bound WebSocket output when readers stall.
The dependency is unpatched. The shared-worker dispatch experiment was retired after
the matched comparison found no reliable fan-out improvement. The send-copy experiment in
[PR #3](https://github.com/kaitk/goose-http/pull/3) was retired after review found a
13-28% server-bound throughput loss. The current pin includes upstream's native-ring
allocation fix, lazy WebSocket reservations, precise timers, and goose-compress v0.1.4.
HTTP/3 is disabled in this application.

The pin is goose-http's experiment branch `post-priority` at `c58a340a`, tagged
`v0.5.11-campfire.3-rf` (`v0.5.11-campfire.3` plus an opt-in requests-first loop pass): v0.5.11 plus refcounted shared blobs that workers send zero-copy
(`sendmsg` on epoll and both rings; TLS and Windows copy), generation-checked blob handles,
a fix that keeps an upgraded exchange's mailbox key live through TIMEOUT, a worker address
with local wakes delivered right after the loop takes its mail, and an epoll loop that skips the recv after a wake when the socket is
known to be empty. These are
planned for a goose-http release; until then the tag keeps the pin reproducible.
See the [dependency history](patches/README.md) and [reproducer](docs/websocket-backpressure.md).

## Verification and provenance

`test_server.py`, native unit tests, and the differential rendering tests are preserved from
the experiment. Historical results and limitations are in [docs/experiment.md](docs/experiment.md).
The [current queue-capacity comparison](docs/publication-queue-sizes.md) uses packaged images,
the unchanged shared load generator and validators, audited writes, and 15 guarded rounds
against current Jai. It records throughput, latency, memory, exact versions and every sample.
See [cache validation](docs/read-cache.md) for the read path and the historical
[backend comparison](docs/backend-selection.md) for epoll versus ring modes.

**Fan-out delivery (2026-10-28):** the changes are coalesced frames, shared bodies,
zero-copy sends, a work-list broker and per-worker delivery. Against current Jai, measured
with the shared verifier on a Ryzen 7 PRO 6850U:

- **64 readers:** fan-out reaches 1.34× Jai's at queued-8 and 1.04× with the default. CPU per
  message is 0.63–0.68× Jai's, and delivery p99 is at or below Jai's.
- **Jai's 2,000- and 10,000-client scenario:**
  - Paced delivery latency is slightly better than Jai's.
  - Memory is 0.07–0.23× Jai's.
  - Saturated delivery rate is still 0.40–0.50× Jai's.

The [fan-out delivery report](docs/fanout-delivery.md) has each change's effect and the
experiments that were tried and dropped. The comparison below predates these changes.

On 2026-10-26 PDT, queued windows of 8, 32, 128 and 512 reach median complete fan-out
rates of 2,031, 2,266, 2,434 and 2,322 messages/s to all 64 readers. Jai reaches 3,448.
The 128-entry window gains 19.9% over queued-eight; Jai remains 1.42× faster. The cost
is saturated delivery p99 of 66.43 ms, versus 13.10 at eight and 2.71 for Jai. Increasing
to 512 adds latency (192.64 ms) without further measured throughput benefit.

At 128, Goose reaches 391.4k cached room reads/s and 6.14k posts/s without subscribers,
versus Jai's 316.6k and 4.41k. Anonymous memory after fan-out is 28.11 MiB versus 83.70
for Jai. Large-message stalled-reader RSS rises from 33.49 MiB at eight to 56.36 at 128
and 134.55 at 512; these pressure-test samples describe a different workload.

All larger sizes remain opt-in: set `CAMPFIRE_PUBLICATION_ACK=queued` and
`CAMPFIRE_PUBLICATION_WINDOW` to a power of two from 8 through 512. Total retained
delivery permits equal the window plus 56 and are released only after final drain.
The default remains final-drain acknowledgement with eight active publications and
64 permits. The [earlier policy-only comparison](docs/queued-acknowledgements.md)
records the separate 24.2% gain from queued acknowledgements at the original bounds.
The report preserves an unreproduced native io_uring pressure-setup failure alongside
passing reruns; all performance measurements use epoll.

The [shared worker-dispatch experiment](docs/worker-dispatch.md) showed no reliable
gain and remains retired. The application uses unpatched upstream goose-http.
Rendering parity, bounded admission and both acknowledgement-policy tests pass.
These are workload-specific application results, not a general language-speed claim.

The [send-copy measurements](docs/send-copy.md) and
[upstream review](docs/send-copy-pr.md) remain as historical evidence for the retired
experiment. Their rates use a different kernel and workload and do not measure
the current application.

Application source was extracted from `aardappel/goose` revision
`9bbf9446` (`bench/campfire`) onto the experimental branch. The Goose compiler remains a separate dependency.
Application code retains the Apache 2.0 license. Templates/frontend assets retain their upstream
MIT license and embedded notices; see [THIRD_PARTY.md](THIRD_PARTY.md).
