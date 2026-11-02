# Campfire in Goose

A [Campfire](https://github.com/basecamp/once-campfire) server written in
[Goose](https://github.com/aardappel/goose), benchmarked against the Jai implementation
([once-campfire-jai](https://github.com/lucasmeijer/once-campfire-jai)) with a shared load
generator and validators. The implemented HTTP routes pass the shared response contracts and
persisted-write audits. Rendering matches 27 differential cases against the pinned Rust and Jai
references. Fresh setup, invitations, live messaging, edits, boosts, file uploads with libvips image variants, profile/account forms, open and closed
rooms, room involvement and deletion, user pages, the bot API and webhooks, mentions, account
administration, session transfers, QR codes and direct-ping creation are implemented, and the unmodified shared
Chromium smoke test covers these flows. Full application compatibility is still in progress; see
[browser coverage and delivery semantics](docs/browser-parity.md).

This repository, [kaitk/once-campfire-goose](https://github.com/kaitk/once-campfire-goose), is
where development continues. It started as a fork of
[aardappel/once-campfire-goose](https://github.com/aardappel/once-campfire-goose), and the
application source was extracted from `aardappel/goose` revision `9bbf9446` (`bench/campfire`).

## Results

Goose against the [Jai implementation](https://github.com/lucasmeijer/once-campfire-jai) and the
[Rust implementation](https://github.com/basecamp/once-campfire-rust), in their published
images, with the shared load generator and route contracts: every response validated, every
acknowledged write audited, rotated rounds, medians. Live updates are on a Ryzen 7 5800X3D
(WSL2, Docker) with Jai measured in every round: 64 readers with the shared verifier
(`benchmark_shared.py`), 2,000 and 10,000 clients with Jai's own `bench/scenarios/fanout`. Details, ranges and every experiment
are in the [fan-out delivery report](docs/fanout-delivery.md), along with
[a run on a second machine](docs/fanout-delivery.md#second-machine).

### Workloads that reflect production

| | **Goose** | Jai | Goose vs Jai |
|---|---:|---:|---:|
| Post a message, posts/sec | **6,174** | 4,408 | **1.40×** |
| Live updates to 64 readers, posting flat out: messages/sec to every reader | **4,170** | 2,942 | **1.37–1.45×** |
| The same: server CPU per message | **0.60 ms** | 0.96 ms | 0.62× |
| Live updates to 2,000 clients at a steady pace: delivery p50 / p99 | 10.2 / 17.4 ms | 11.3 / 16.2 ms | on par |
| 2,000 clients, posting flat out: delivery p99 | **67 ms** | 4.8 s | 72× lower |
| 10,000 clients, posting flat out: delivery p99 | **248 ms** | 15.1 s | 61× lower |
| 2,000 clients, posting flat out: peak memory | **16 MiB** | 305 MiB | 19× less |
| 10,000 clients, posting flat out: peak memory | **38 MiB** | 651 MiB | 17× less |

Posts are 2.0× the Rust implementation's (8,081 against 4,045 posts/sec, October 23 session).
Memory is anonymous memory.

### Page workloads (benchmaxxed)

As [the Jai README](https://github.com/lucasmeijer/once-campfire-jai#measurements) puts it, these
repeat one URL for one signed-in session, so a cache of finished pages answers nearly every
request. Requests/sec:

| | **Goose** | Jai | Rust | Goose vs Jai | Goose vs Rust |
|---|---:|---:|---:|---:|---:|
| Room page (October 26) | **391,419** | 316,581 | | **1.24×** | |
| Room page (October 23) | **192,362** | 186,750 | 27,944 | 1.03× | **6.88×** |
| Messages page (October 23) | **196,989** | 191,307 | 27,588 | 1.03× | **7.14×** |
| Sidebar (October 23) | **201,558** | 193,742 | 30,102 | 1.04× | **6.70×** |
| Search (October 23) | **196,635** | 194,062 | 30,202 | 1.01× | **6.51×** |

The October 23 session gave the load generator four cores, which Goose and Jai both saturated, so
its Goose/Jai ratio understates the gap; the October 26 session gave it eight
([October 23](docs/benchmarks.md), [October 26](docs/publication-queue-sizes.md)).

### Where Jai leads

Posting flat out to thousands of clients, Jai delivers more messages per second. It lets each
client's outbox grow to 4,096 messages and writes ~29 frames per `writev`, against Goose's ~6 per
`sendmsg`; that queue is where its multi-second p99 and memory above come from. Goose bounds
delivery with a window of eight publications.

| | Goose | **Jai** | Goose vs Jai |
|---|---:|---:|---:|
| 2,000 clients, posting flat out: messages/sec to every client | 286 | **470** | 0.61× |
| 10,000 clients, posting flat out: the same | 69 | **89** | 0.78× |
| 2,000 clients, posting flat out: POST latency p50 | 13.9 ms | **3.7 ms** | 3.8× |
| 2,000 clients, posting flat out: server CPU per delivery | 6.6 µs | **4.2 µs** | 1.58× |

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
libssl-dev, libcrypt-dev, libqrencode-dev, libglib2.0-dev and libvips 8.16 (the Dockerfile's
`vips` stage builds it) installed, run `sh build_linux.sh`.
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
`CAMPFIRE_CABLE_SESSION_CHECK_MS` (100–3600000, default 60000) sets how often an open cable
connection looks its session up again, as Rails does each minute.
`CAMPFIRE_HTTP_BACKEND` defaults to `epoll`, the direct Linux loop usable in ordinary Docker.
`auto` probes for native io_uring and selects epoll when unavailable. `uring` requires native
io_uring and refuses emulation; `emulated` explicitly selects the ring emulation for comparisons.
The selected backend is logged at startup. For `uring` on Linux 6.1 or later, generate and pass the optional
[container seccomp profile](docs/send-copy-pr.md#local-native-io_uring-setup).
TLS should terminate at a reverse proxy; application deployment compatibility is still in progress.
Uploads (message attachments, avatars, the logo) may be up to `CAMPFIRE_UPLOAD_MAX_BYTES`
(default 100 MiB); other request bodies are limited to 1 MiB. Image variants are made by
`CAMPFIRE_MEDIA_THREADS` (1–64, default 2) threads off the HTTP workers; see
[uploads](docs/browser-parity.md#uploads-and-active-storage).
Bot webhooks are delivered by `CAMPFIRE_WEBHOOK_THREADS` (1–64, default 2) threads off the
request path; see [webhook delivery](docs/browser-parity.md#bot-webhooks).

## Pinned dependencies

Image analysis and variants use libvips 8.16.1, the Rails image's version, built from its
release tarball (SHA-256 pinned in the Dockerfile) with only the PNG, JPEG, GIF, WebP, TIFF and
HEIC/AVIF loaders and savers, EXIF and ICC support. The runtime image installs the codec
libraries it links (libjpeg-turbo, libspng, libpng, libwebp, libtiff, libheif with its libde265
and aom decoders, libexif, lcms2, cgif, libimagequant, highway, GLib and expat): about 20 MB,
where Ubuntu's `libvips42t64` would bring ImageMagick, Poppler and OpenEXR (over 100 MB).
ffmpeg is not installed, so videos get no previews.

Bot webhooks use goose-http's blocking client (`http.client`), which needs
[goose-tls](https://github.com/kaitk/goose-tls) `v0.0.6` (`b7cc745a`) for HTTPS URLs; it links
OpenSSL 3, so the runtime image installs `libssl3t64`. No HTTP worker uses TLS.

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
