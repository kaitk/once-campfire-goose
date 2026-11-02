# Campfire in Goose

A [Campfire](https://github.com/basecamp/once-campfire) server written in
[Goose](https://github.com/aardappel/goose), benchmarked against the Jai implementation
([once-campfire-jai](https://github.com/lucasmeijer/once-campfire-jai)) with a shared load
generator and validators. The implemented HTTP routes pass the shared response contracts and
persisted-write audits. Rendering matches 27 differential cases against the pinned Rust and Jai
references. Fresh setup, invitations, live messaging, edits, profile/account forms, rooms, bots,
session transfers, QR codes and direct-ping creation are implemented, and the unmodified shared
Chromium smoke test covers these flows. Full application compatibility is still in progress; see
[browser coverage and delivery semantics](docs/browser-parity.md).

This repository, [kaitk/once-campfire-goose](https://github.com/kaitk/once-campfire-goose), is
where development continues. It started as a fork of
[aardappel/once-campfire-goose](https://github.com/aardappel/once-campfire-goose), and the
application source was extracted from `aardappel/goose` revision `9bbf9446` (`bench/campfire`).

## Results

Serving cached room pages, Goose runs **1.2× faster than Jai** (391k against 317k requests/s,
and 379k against 310k in an independent run) and **6.9× faster than Rust** (192k against 28k).
It handles posts 1.4–1.5× faster than Jai and 2.0× faster than Rust. All are medians of
rotated rounds with the shared load generator and route contracts, every response validated,
against the published Rust and Jai images
([Jai and reads](docs/publication-queue-sizes.md), [Rust](docs/benchmarks.md)). The load
generator was near saturation on reads, so these are lower bounds for Goose and Jai.

Live delivery over WebSockets ("fan-out", complete messages per second, each received by every
reader), on a Ryzen 7 5800X3D (WSL2, Docker), Jai measured in every round, every sample
validated. 64 readers use the shared verifier (`benchmark_shared.py`); 2,000 and 10,000 clients
use Jai's own `bench/scenarios/fanout`:

| | Goose | Jai | Goose / Jai |
|---|---:|---:|---:|
| fan-out to 64 readers | 4,170 msg/s | 2,942 msg/s | **1.37–1.45×** |
| CPU per message, 64 readers | 0.60 ms | 0.96 ms | 0.62× |
| 2,000 clients, saturated | 286 msg/s | 470 msg/s | 0.61× |
| 10,000 clients, saturated | 69 msg/s | 89 msg/s | 0.78× |
| saturated delivery p99, 2,000 / 10,000 | 67 / 248 ms | 4.8 / 15.1 s | **0.01–0.02×** |
| peak anonymous memory, 2,000 / 10,000 | 16 / 38 MiB | 305 / 651 MiB | **0.05–0.06×** |

Paced delivery latency is on par with Jai's.

An independent run on a second desktop reproduced these: 1.46× Jai at 64 readers (4,667 against
3,198 msg/s), 0.56× and 0.59× at 2,000 and 10,000 clients, saturated p99 of 80–635 ms against
5.8–7.3 s, and 16–39 MiB against 327–509 MiB.

Jai still leads saturated throughput at 2,000 and more readers. It lets each reader's outbox grow
to 4,096 frames and writes ~29 frames per `writev`, against Goose's ~6 per `sendmsg`; that queue is
where its multi-second p99 and memory come from. Goose bounds delivery with a window of eight
publications. The [fan-out delivery report](docs/fanout-delivery.md) gives each change's measured
effect, Jai's design, and every experiment that was tried and dropped.

These are workload-specific application results, not a general language-speed claim.

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

## Pinned dependencies

`dependencies.json` pins the Goose compiler and each package at an immutable revision. HTTP is
goose-http's experiment branch `campfire-fanout` at `ab762b12`, tagged `v0.5.11-campfire.3`:
v0.5.11 plus refcounted shared blobs that workers send zero-copy (`sendmsg` on epoll and both
rings; TLS and Windows copy), generation-checked blob handles, a fix that keeps an upgraded
exchange's mailbox key live through TIMEOUT, a worker address with local wakes delivered right
after the loop takes its mail, and an epoll loop that skips the recv after a wake when the
socket is known to be empty. These are planned for a goose-http release; until then the tag
keeps the pin reproducible. It builds on upstream's
[drain notifications](https://github.com/kaitk/goose-http/pull/2), which the application uses
to bound WebSocket output when readers stall. HTTP/3 is disabled in this application.
See the [dependency history](patches/README.md) and [reproducer](docs/websocket-backpressure.md).

## Delivery settings

Publications are acknowledged once queued (after the database commit, once the broker holds the
publication), as Jai does; `CAMPFIRE_PUBLICATION_ACK=drained` waits for every reader's socket
instead. `CAMPFIRE_PUBLICATION_WINDOW` (a power of two from 8 through 512, default 8) sets the
active publications; delivery permits equal the window plus 56. `CAMPFIRE_CABLE_BATCH` (default
256 KiB) and `CAMPFIRE_CABLE_PASS_READERS` (default 16) set the bytes per reader write and the
readers a worker writes per loop pass. `CAMPFIRE_CABLE_PACE_MS` enables experimental write
pacing, off by default.

## Verification and history

`test_server.py`, native unit tests, and the differential rendering tests are preserved from
the experiment, and `docker build --target test` runs the full suite. Earlier work, each with its
own samples and versions:

- [Fan-out delivery](docs/fanout-delivery.md) (2026-10-28 to 11-02): the current results above.
- [Publication queue sizes](docs/publication-queue-sizes.md) (2026-10-26) and
  [queued acknowledgements](docs/queued-acknowledgements.md): before the fan-out work, Jai was
  1.42× faster at 64 readers.
- [Read cache](docs/read-cache.md), [backend selection](docs/backend-selection.md) (epoll is the
  default; native io_uring is about 3% ahead on fan-out with ~20% more memory).
- Retired: [shared worker dispatch](docs/worker-dispatch.md), and the
  [send-copy experiment](docs/send-copy.md) ([review](docs/send-copy-pr.md)), which lost 13–28%
  server-bound throughput.
- The original [experiment report](docs/experiment.md).

Application code retains the Apache 2.0 license. Templates/frontend assets retain their upstream
MIT license and embedded notices; see [THIRD_PARTY.md](THIRD_PARTY.md).
