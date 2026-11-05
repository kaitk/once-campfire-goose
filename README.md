# Campfire in Goose

A [Campfire](https://github.com/basecamp/once-campfire) server written in
[Goose](https://github.com/aardappel/goose), benchmarked against the Jai implementation
([once-campfire-jai](https://github.com/lucasmeijer/once-campfire-jai)) with a shared load
generator and validators. The implemented HTTP routes pass the shared response contracts and
persisted-write audits. The application follows Campfire's Rails code at `a05ee908` (Rails
main of November 2, 2026) route by route: sign-in,
setup and joining, live messaging, edits and deletion, boosts, link previews, uploads with image
variants and video previews, open and closed rooms and Pings, search and permalinks, profiles,
account administration and bots, the bot API and webhooks, Web Push, QR codes, session
transfers, built-in TLS with ACME certificates, and what Rails' middleware answers: error pages,
ETags and conditional requests, the Content-Security-Policy, static files and Active Storage's
proxies. Each area is compared with that revision's Rails reference image response by response,
and the unmodified shared Chromium smoke test passes; the results, why the target is Rails main
rather than the harness's `90b3300`, and the remaining differences are in
[Rails parity, browser coverage and live delivery](docs/browser-parity.md).

This repository, [kaitk/once-campfire-goose](https://github.com/kaitk/once-campfire-goose), is
where development continues. It started as a fork of
[aardappel/once-campfire-goose](https://github.com/aardappel/once-campfire-goose), and the
application source was extracted from `aardappel/goose` revision `9bbf9446` (`bench/campfire`).

## Results

Two sets of measurements. Their numbers don't compare with each other.

- **The shared harness, November 5, at `9f52b4d`**: basecamp's
  [once-campfire-verification](https://github.com/basecamp/once-campfire-verification) against
  Rails, Rust and Jai, on a Ryzen 7 5800X3D under WSL2.
- **Sessions against Jai and Rust on two Ryzen desktops, October 23–29**, including live
  updates to many clients, which the harness doesn't measure. These predate uploads, bot
  webhooks, Web Push and the live unread, read and typing notices, which landed on November 2,
  and they have not been re-measured since. The notices alone cost 7% of fan-out at 1,000
  readers on an M1 ([live notices](docs/fanout-delivery.md#live-notices)).

### Shared harness on a Ryzen 7 5800X3D (November 5)

`bin/benchmark --apps rails,rust,jai,goose`, with Goose added to the harness as an optional app
and Jai from its open pull request
([#11](https://github.com/basecamp/once-campfire-verification/pull/11)): 3 rotated rounds, 16
clients, the apps on 4 CPUs (2 cores) and the load generator on another 4. Goose `9f52b4d`, Rails
`a05ee908` built locally, and the published images of Rust (`main`, `6dae2fd`) and Jai
(`2ecd487`). The host is a Ryzen 7 5800X3D under WSL2 on Windows 11, not bare-metal Linux. Neither
run had an error or a response that failed its route contract, and every acknowledged post was
audited against the database. Requests/sec, medians:

| | Rails | Rust | Jai | **Goose** | Goose vs Rust | Goose vs Jai |
|---|---:|---:|---:|---:|---:|---:|
| Post a message | 280 | 2,674 | 3,703 | **4,664** | **1.74×** | **1.26×** |
| Room page | 2,245 | 19,066 | 162,054 | 167,417 | 8.78× | 1.03× |
| Messages page | 2,114 | 18,087 | 171,954 | 169,891 | 9.39× | 0.99× |
| Sidebar | 2,279 | 20,805 | 175,792 | 166,607 | 8.01× | 0.95× |
| Search | 2,257 | 20,878 | 169,112 | 173,233 | 8.30× | 1.02× |
| Room page, one writer posting 10 messages/s (separate run) | 737 | 17,426 | 154,989 | 161,445 | 9.26× | 1.04× |
| Peak memory of the app's process, MiB | | 113.8 | 98.1 | **34.5** | **3.3× less** | **2.8× less** |

On the page routes the load generator used 385% of its 400% CPU for both Goose and Jai, so
those Goose vs Jai ratios are the client's ceiling, not a comparison of the servers, and Goose vs
Rust there is a lower bound. Posting is bound by the servers (the load generator used 44% for
Goose and 55% for Jai), and it is the row that reflects production; the page rows are benchmaxxed
([below](#page-workloads-benchmaxxed)). Rust and Jai reach their memory peaks while posting;
Rails runs several processes and isn't in the memory row. The harness's file routes, which its
summary leaves out, are where Goose's server is the limit: it serves the avatar and the
stylesheet well below Jai. The [run's report](docs/harness-2026-11-05.md) has the ranges, p99s,
the other routes, memory, the inputs and the host.

### Earlier sessions on Ryzen desktops (October 23–29)

Goose against the [Jai implementation](https://github.com/lucasmeijer/once-campfire-jai) and the
[Rust implementation](https://github.com/basecamp/once-campfire-rust), in their published
images, with the shared load generator and route contracts: every response validated, every
acknowledged write audited, rotated rounds, medians. Posts and pages are from a Ryzen 9
9950X3D on October 23 and 26 (at `af65824` and `373e348`). Live updates are from a Ryzen 7
5800X3D on October 28–29 (at `210a469`), with Jai measured in every round: 64 readers with the
shared verifier (`benchmark_shared.py`), 2,000 and 10,000 clients with Jai's own
`bench/scenarios/fanout`. Both ran under WSL2 with Docker. Details, ranges and every experiment
are in the [fan-out delivery report](docs/fanout-delivery.md), along with
[a run on a second machine](docs/fanout-delivery.md#second-machine).

#### Workloads that reflect production

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

Posts are from the October 26 session at `373e348`. They were 2.0× the Rust implementation's
(8,081 against 4,045 posts/sec) in the October 23 session at `af65824`.
Memory is anonymous memory.

#### Page workloads (benchmaxxed)

As [the Jai README](https://github.com/lucasmeijer/once-campfire-jai#measurements) puts it, these
repeat one URL for one signed-in session, so a cache of finished pages answers nearly every
request. Requests/sec, at `373e348` (October 26) and `af65824` (October 23):

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

#### Where Jai leads

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
`dependencies.json`. The 313 frontend files are vendored and SHA-256 checked against
`views/assets.json`; building never starts a reference server or needs a fixture database.

```sh
docker build --target test -t once-campfire-goose:test .
docker build --build-arg GIT_REVISION="$(git rev-parse HEAD)" -t once-campfire-goose:app .
python3 test_image.py once-campfire-goose:app
python3 test_browser.py once-campfire-goose:app
```

For a Linux development build with Clang, CMake, Ninja, Python 3, Git, liburing-dev,
libssl-dev, libcrypt-dev, libglib2.0-dev and libvips 8.16 (the Dockerfile's
`vips` stage builds it) installed, run `sh build_linux.sh`.
Build products and dependency checkouts stay under ignored `build/`.

Each push to `main` also publishes a linux/amd64 and linux/arm64 image to GHCR:
`ghcr.io/kaitk/once-campfire-goose:latest`, or `:sha-` and the 7-character revision. Use it in
place of `once-campfire-goose:app` below, or as `GOOSE_IMAGE` in the shared harness.

## Run against disposable Campfire storage

```sh
docker run --rm -p 8080:80 -e DISABLE_SSL=true --env-file campfire.env \
  -v /absolute/path/to/storage:/rails/storage once-campfire-goose:app
```

To serve the internet directly, as the Rails image does, give it a domain instead: it gets and
renews Let's Encrypt certificates itself and serves HTTPS on 443, redirecting port 80.

```sh
docker run -d -p 80:80 -p 443:443 -e TLS_DOMAIN=chat.example.com --env-file campfire.env \
  -v campfire:/rails/storage once-campfire-goose:app
```

The environment file supplies `SECRET_KEY_BASE` matching that database's Rails signing secret.
The database is `/rails/storage/db/production.sqlite3`; blob files are in `/rails/storage/files`.
Storage must be writable by UID 1000. An empty database is initialized from Rails main's schema;
visit `/first_run` to create the account and administrator. An existing Campfire database from
`90b3300` is migrated to Rails main's schema at boot (two message indexes, and
`rooms.messages_count` with its triggers), as Rails' `db:prepare` migrates it; one older than
that is refused until the Rails image has migrated it
([database schema](docs/browser-parity.md#database-schema)).
As in Rails' production settings, URLs, cookies and HSTS assume HTTPS unless `DISABLE_SSL` is
set. `HTTP_PORT` defaults to 80 and `HTTPS_PORT` to 443; with `TLS_DOMAIN` (comma-separated
names), certificates come from `ACME_DIRECTORY` (Let's Encrypt by default; `EAB_KID` and
`EAB_HMAC_KEY` for external account binding) and are kept in `/rails/storage/thruster`, as
Thruster keeps them, so an install moved from the Rails image keeps its certificates. Each of
these may also be given with a `THRUSTER_` prefix, which wins. `FORWARD_HEADERS` keeps a proxy's
`X-Forwarded-*` headers. `DISABLE_CONTENT_SECURITY_POLICY=true` drops the
Content-Security-Policy header and its meta tag, as in Rails. `CAMPFIRE_HTTP_THREADS` defaults
to 4, and `CAMPFIRE_CACHE=0` disables response caching. `DATABASE_PATH` and `STORAGE_PATH` override storage locations.
`CAMPFIRE_HTTP_MAX_CONNS` (64–65536, default 1024) sets each worker's connection limit and
waiting cable exchanges; raise it for rooms with more than about 4,000 open WebSockets.
`CAMPFIRE_CABLE_SESSION_CHECK_MS` (100–3600000, default 60000) sets how often an open cable
connection looks its session up again, as Rails does each minute.
`CAMPFIRE_HTTP_BACKEND` defaults to `epoll`, the direct Linux loop usable in ordinary Docker.
`auto` probes for native io_uring and selects epoll when unavailable. `uring` requires native
io_uring and refuses emulation; `emulated` explicitly selects the ring emulation for comparisons.
The selected backend is logged at startup. For `uring` on Linux 6.1 or later, generate and pass the optional
[container seccomp profile](docs/send-copy-pr.md#local-native-io_uring-setup).
Uploads (message attachments, avatars, the logo) may be up to `CAMPFIRE_UPLOAD_MAX_BYTES`
(default 100 MiB); other request bodies are limited to 1 MiB. Image variants, video and audio
analysis and video previews are made by `CAMPFIRE_MEDIA_THREADS` (1–64, default 2) threads off
the HTTP workers; see
[uploads](docs/browser-parity.md#uploads-and-active-storage).
Bot webhooks and Web Push notifications are delivered by `CAMPFIRE_DELIVERY_THREADS` (1–64,
default 4; `CAMPFIRE_WEBHOOK_THREADS` is its earlier name) threads off the request path; see
[webhook delivery](docs/browser-parity.md#bot-webhooks). Web Push is on when
`VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY` make a P-256 key pair; see
[Web Push](docs/browser-parity.md#web-push).
On SIGTERM (`docker stop`'s) or SIGINT the server stops taking connections, closes its cable
connections so their clients reconnect, and lets requests in flight and queued jobs finish for
`CAMPFIRE_SHUTDOWN_GRACE_MS` (0–600000, default 8000) before it exits; a second signal exits at
once. See [jobs](docs/browser-parity.md#deliberate-differences).

## Pinned dependencies

Image analysis and variants use libvips 8.16.1, the Rails image's version, built from its
release tarball (SHA-256 pinned in the Dockerfile) with only the PNG, JPEG, GIF, WebP, TIFF and
HEIC/AVIF loaders and savers, EXIF and ICC support. The runtime image installs the codec
libraries it links (libjpeg-turbo, libspng, libpng, libwebp, libtiff, libheif with its libde265
and aom decoders, libexif, lcms2, cgif, libimagequant, highway, GLib and expat): about 20 MB,
where Ubuntu's `libvips42t64` would bring ImageMagick, Poppler and OpenEXR (over 100 MB).
ffmpeg and ffprobe are built from the Rails image's Debian source package
(`7:7.1.5-0+deb13u1`, pinned by its `.dsc` checksum) with only what analysis and previews need,
as the Rust and Jai ports trim them; Ubuntu's own would add about 400 MB.

TLS is [goose-tls](https://github.com/kaitk/goose-tls) `v0.0.6` (`b7cc745a`): the server's
TLS 1.3 in Goose over OpenSSL 3's libcrypto, and libssl for the clients that bot webhooks, Web
Push and link previews use. Certificates come from
[goose-acme](https://github.com/kaitk/goose-acme) `v0.0.5` (`504b9354`), whose `acme.serve`
runs the ACME flow on a lane and hands each HTTP worker its certificates by mail. Web Push's
encryption, VAPID signatures and address guard (`push_crypto.c`) use the same libcrypto.

`dependencies.json` pins the Goose compiler and each package at an immutable revision. HTTP is
goose-http `v0.5.18` (`86fdeec3`) from its main branch, which carries the work this
application's fan-out needs: refcounted shared blobs that workers send zero-copy, worker
addresses with local wakes, and
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
- Earlier shared-harness runs, Goose against Rust only, on an M1 Pro:
  [November 2](docs/harness-2026-11-02.md) and [November 3](docs/harness-2026-11-03.md).
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
