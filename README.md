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

### Shared harness (November 5)

basecamp's [once-campfire-verification](https://github.com/basecamp/once-campfire-verification),
with Goose added as an optional app and Jai from its open pull request
([#11](https://github.com/basecamp/once-campfire-verification/pull/11)): `bin/benchmark --apps
rails,rust,jai,goose`, 3 rotated rounds, 16 clients, the apps on 4 CPUs and the load generator on
another 4. Goose `9f52b4d`, Rails `a05ee908`, Rust `6dae2fd` and Jai `2ecd487`, on a Ryzen 7
5800X3D under WSL2 (not bare-metal Linux). Every response matched its route contract and every
acknowledged post was audited against the database. Requests/sec, medians:

| | Rails | Rust | Jai | **Goose** | Goose vs Rust | Goose vs Jai |
|---|---:|---:|---:|---:|---:|---:|
| Post a message | 280 | 2,674 | 3,703 | **4,664** | **1.74×** | **1.26×** |
| Room page | 2,245 | 19,066 | 162,054 | 167,417 | 8.78× | 1.03× |
| Messages page | 2,114 | 18,087 | 171,954 | 169,891 | 9.39× | 0.99× |
| Sidebar | 2,279 | 20,805 | 175,792 | 166,607 | 8.01× | 0.95× |
| Search | 2,257 | 20,878 | 169,112 | 173,233 | 8.30× | 1.02× |
| Anonymous memory while posting (separate run) | 889 MiB | 90.0 MiB | 77.4 MiB | **16.1 MiB** | **5.6× less** | **4.8× less** |

Posting is bound by the servers and is the row that reflects production. The page rows repeat one
URL for one session, which a cache of finished pages answers; there the load generator saturated
its 4 CPUs for Goose and Jai, and with 12 CPUs for it Goose read 1.02–1.08× as fast as Jai. The
[run's report](docs/harness-2026-11-05.md) has the ranges, p99s, the mixed-write run, the other
routes, memory per process and per container, the inputs and the JSON.

### Live updates to many clients (October 28–29)

The harness doesn't measure delivery to many connected clients, so these come from Jai's own
`bench/scenarios/fanout` and the shared verifier's 64-reader run, Goose `210a469` against Jai in
every round, on a Ryzen 7 5800X3D under WSL2. They predate the live unread, read and typing
notices (November 2), which cost 7% of fan-out at 1,000 readers.

| | **Goose** | Jai | Goose vs Jai |
|---|---:|---:|---:|
| 64 readers, posting flat out: messages/sec to every reader | **4,170** | 2,942 | **1.37–1.45×** |
| 2,000 clients at a steady pace: delivery p50 / p99 | 10.2 / 17.4 ms | 11.3 / 16.2 ms | on par |
| 2,000 clients, posting flat out: delivery p99 | **67 ms** | 4.8 s | 72× lower |
| 2,000 clients, posting flat out: messages/sec to every client | 286 | **470** | 0.61× |
| 2,000 clients, posting flat out: peak memory | **16 MiB** | 305 MiB | 19× less |

Jai delivers more per second to thousands of clients by letting each client's outbox grow to
4,096 messages, which is where its multi-second p99 and memory come from; Goose bounds delivery
with a window of eight publications. The [fan-out delivery report](docs/fanout-delivery.md) has
10,000 clients, CPU per message, POST latency, a second machine and every experiment. Earlier
sessions against Jai and Rust are in [Verification and history](#verification-and-history).

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
- Sessions against Jai and Rust on a Ryzen 9 9950X3D: [October 23](docs/benchmarks.md) (posts
  2.0× Rust's; pages with a saturated load generator) and
  [October 26](docs/publication-queue-sizes.md) (posts 1.40× Jai's).
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
