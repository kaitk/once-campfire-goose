# Earlier Rust/Jai comparison

The [send-copy report](send-copy.md) supersedes these results with the merged HTTP
dependency, the local send optimization, and completed baseline and mixed benchmarks.
This page retains the earlier measurements and shared reproduction instructions.
The retired send-copy candidate, review outcome and native-ring setup are covered in the
[review follow-up](send-copy-pr.md).

Measured on 2026-10-23 UTC using the packaged Goose application and current published
Rust and Jai images. The older Jai `e56ba63` comparison in [the experiment log](experiment.md)
is historical and does not establish a 2x lead over current Jai.

## Results

Goose's observed medians are 1-4% above current Jai on the four cached-read routes
and 55% above it on posts. The read ranges overlap, so they do not establish a large
or consistent read-throughput advantage. Against Rust, room reads are 6.88x and posts
2.00x. The controlled before/after experiment below shows reduced server CPU cost,
but the primary benchmark does not establish that these changes widened the Jai gap.

Valid requests/second, median of three rounds; parentheses show the lowest and highest
round, not a confidence interval. Baseline measurement and audits ran from 01:44:31
to 01:52:47 UTC. These nine runs finished before an unrelated Windows build began.
The subsequent mixed-workload samples overlapped compilation and are excluded.
A mixed-only retry also overlapped another build; refreshed mixed results remain pending.

| Route | Goose | Rust | Jai |
|---|---:|---:|---:|
| Room | 192,362 (190,631-205,325) | 27,944 (27,821-28,165) | 186,750 (178,442-188,209) |
| Older messages | 196,989 (182,211-205,508) | 27,588 (27,405-27,693) | 191,307 (184,165-192,094) |
| Sidebar | 201,558 (166,934-203,032) | 30,102 (29,538-30,587) | 193,742 (188,090-197,829) |
| Search | 196,635 (185,472-210,914) | 30,202 (29,981-30,447) | 194,062 (176,240-197,935) |
| Post message | 8,081 (7,939-8,375) | 4,045 (3,990-4,070) | 5,211 (5,128-5,352) |

Median anonymous-memory samples after each route, in MiB:

| Sample | Goose | Rust | Jai |
|---|---:|---:|---:|
| Room reads | 23.45 | 22.38 | 45.96 |
| Message posts | 27.20 | 92.52 | 109.63 |

Goose is close to Rust's memory use on room reads and substantially lower after writes.
The median of the per-round POST p99 latencies is 6.42 ms for Goose, 8.95 ms for Rust,
and 7.67 ms for Jai. Room-read p99 is approximately 0.194, 1.201, and 0.188 ms,
respectively; higher Goose throughput does not imply lower latency on every route.

The generator uses about 3.71 CPU cores for Goose room reads and 3.74 for Jai, out of
four allocated client cores; the servers use about 1.72 and 1.95 cores. This indicates
limited generator headroom, so these results should not be extrapolated to maximum
server throughput. Rust uses about 3.32 server cores and 1.14 generator cores there.

All timed responses passed their route contracts, with zero errors or invalid responses.
The completed audit totals are:

| Application | Valid timed baseline responses | Audited acknowledged writes, including warmup |
|---|---:|---:|
| Goose | 18,897,958 | 240,109 |
| Rust | 2,877,004 | 116,304 |
| Jai | 18,278,658 | 156,864 |

## Profile-guided optimization

The original production binary was profiled with `perf record -e cycles:u -F 499`
and DWARF call chains, using the unchanged shared load generator and route contracts.
The read profile attributed 22% of sampled cycles to copying, including roughly 18%
in cached-response and send-buffer copies. UTC conversion, timestamp formatting and
repeated compression negotiation were other visible costs. The write profile showed
substantial gzip work and 3.35% in the broker's JSON string formatting.

Application revision `af65824` makes three changes:

- Cache the calendar portion of timestamp formatting per thread and second, retaining
  a fresh clock sample and its exact milliseconds or microseconds on every call.
- Store the negotiated compression type in page-cache entries. Exact header bytes
  remain part of the key; HEAD still uses the identity body's length and sends no body.
- Encode broadcast JSON only when a publication has matching subscribers. The broker
  still performs its ordinary enrollment, completion and acknowledgement processing.

Tests cover timestamp fractions, backward clock jumps, date boundaries, leap-day expiry
and independent threads, plus alternating encodings and HEAD-before-GET cache fills.
Authentication, WAL certification, SQL transactions and live-delivery rules are unchanged.

A separate before/after comparison alternated the preserved `2399a6bd` image and the
new image three times, using 600,000 validated room reads per sample, 16 connections,
the same four server and four client cores, and fresh seed copies. After warmup,
`perf stat -e instructions:u,cycles:u,task-clock -p 1 -- sleep 10` counted all server
threads; the fixed request batch ran entirely inside that interval. Thus task-clock
includes the surrounding idle time. All 3.6 million measured responses passed. No
Windows compiler process was detected during these samples.

| Median metric | Before | After | Change |
|---|---:|---:|---:|
| User-mode instructions / response | 13,678 | 7,833 | -42.7% |
| User-mode cycles / response | 12,174 | 9,492 | -22.0% |
| Total server CPU microseconds / response | 9.28 | 8.63 | -6.9% |
| Valid responses / second | 200,097 | 211,435 | +5.7% |

Before throughput ranged from 197,779 to 200,783; after ranged from 209,142 to 215,770.
These are controlled Goose-versus-Goose results, not a replacement for the Rust/Jai
comparison or evidence of a 43% throughput increase. Absolute rates from different
sessions are not used to attribute code gains.

An isolated 2,000-iteration compression probe of a rendered POST response supported
retaining gzip level 1: 2,112 bytes / 20.9 microseconds, versus level 3's 2,055 bytes /
24.4 microseconds and level 6's 1,998 bytes / 30.4 microseconds. This is encoder cost,
not end-to-end POST latency. The existing reset API also clears the large encoder arrays,
so allocation reuse alone does not remove that work.

The next investigations are avoiding a response-buffer copy in goose-http while preserving
partial-write ownership and drain semantics, and separating generator limits from server
capacity with independent client processes. The latter check and refreshed mixed-workload
measurements need a quiet host; no results are claimed for either. No competing processes
were interrupted. The remaining uncontended read ranges still show substantial variation.

## What was validated

The measured production image passes the unchanged shared Chromium smoke suite, including
setup, two-tab live messaging, duplicate suppression, stored-markup safety, editing, search,
profile/account forms, rooms, bots, QR codes, session transfers, invitations, and direct pings.
It also passes 27 differential rendering cases against each reference and verifies all
315 static asset hashes and MIME types. Native tests cover both HTTP backends, cache on/off,
cookie expiry, external session/room revocation, rollback, WAL restart, concurrent writes,
fragmented WebSocket delivery, and disconnect cleanup.

Each benchmark instance first passes all eight shared HTTP contracts, including real avatar
decoding and a persisted POST. Every timed response must be HTTP 200 and satisfy the shared
route contract. Every acknowledged write, including warmup writes, is audited for its
database row, rich-text body, and FTS entry. An invalid response or unverified write fails
the run. The source seed and Goose executable checksums are checked again at completion.

These checks establish the listed flows, not complete Campfire compatibility. Upload
creation, boost mutation, push/webhook delivery, full typing/read events, and active
WebSocket revocation remain among the [documented gaps](browser-parity.md).

## Method and limits

- AMD Ryzen 9 9950X3D, x86-64 Docker on WSL2 Linux `5.15.167.4`, glibc 2.39.
- Four physical server cores (`0,2,4,6`), four separate client cores (`8,10,12,14`),
  2 GiB server memory limit. Goose uses four HTTP workers and the automatic backend.
- Three rounds rotate application order: Goose/Rust/Jai, Rust/Jai/Goose, Jai/Goose/Rust.
  Each route has two seconds of warmup at four clients, then eight seconds at 16 clients.
  Requests accept gzip. No compiler builds run during measurement.
- Every application/profile/round starts with its own database copied from the same
  Rails-generated fixture on native Linux storage. Timed POSTs are plain-text messages.
  Fixture push/webhook endpoints point to loopback port 9, with no external delivery.
- The mixed profile reads Watercooler while posting to HQ at ten messages/second. It
  measures cache invalidation under writes to another room, not same-room delivery latency.
- Repeated requests use the same authenticated session and target, strongly favoring
  response caches. This is a fixed-load HTTP comparison, not a maximum-capacity estimate,
  a concurrent-user count, or a language-wide performance verdict.
- No WebSocket subscribers are connected during throughput measurement. Browser and
  bounded-delivery tests run separately; the numbers do not measure fan-out throughput
  or the cost of all production side effects.
- Memory is the cgroup anonymous-memory sample after each route, not peak memory or
  total RSS. It excludes file-backed cache. Write samples follow the same timed workload,
  not an equal number of stored messages.

`benchmark_shared.py` orchestrates production images using the unchanged shared load
generator, response validator, contracts, and write auditor. Raw receipts, fixtures,
credentials, and browser artifacts remain ignored; this report publishes concise tables.

## Why this differs from the earlier experiment

Current Jai's first complete comparison led Goose on cached reads: 188,601 versus 161,314
room requests/second. That justified more work. Goose now avoids formatted cache-key
allocations and certifies cached snapshots through SQLite's WAL header protocol, while
retaining the ordinary transaction/authentication path whenever the certificate is absent
or changes. Cache tests include external revocation and WAL restart. See
[read-cache validation](read-cache.md) for the protocol and the small C adapter it requires.

Cached gzip bodies use level 6: the isolated room encoding shrank from 28,522 to 20,877 bytes.
The additional encoding time was about 0.15 ms per cache fill in that probe. POST compression
is unchanged. A short automatic-versus-direct-epoll comparison showed no meaningful winner,
so automatic selection remains the default. An exploratory run with eight client cores
changed generator behavior; it is excluded from this report's four-client-core comparison.

The build measured here applied an
[HTTP patch](https://github.com/kaitk/once-campfire-goose/blob/af65824e896a496b4b685d7a692e298a7abc1106/patches/README.md)
that added bounded producer flow control and included the reviewed epoll fairness fix; both
were later merged upstream, and the application now applies no patches
([dependency patches](../patches/README.md)). The patch's separate plain-HTTP
instruction-count check measured less than 0.02% overhead on both tested loop paths. Native
io_uring, macOS and Windows drain integration were left to upstream release checks.

## Immutable inputs

| Input | Revision |
|---|---|
| Goose application | `af65824e896a496b4b685d7a692e298a7abc1106` |
| Goose compiler | `d9573d8139de395cd4549b876c176c25eb878fc1` |
| Rust application | `6dae2fd3c1a2dce61ca11beb731bcce2b42b67ad` |
| Jai published image tag | `2ecd487` |
| Shared verifier | `ec02debb3e44f40b8778a6a42db3c4515b2f9eaf` |
| Rails fixture source | `90b330024dec3e757c79b6a7e6568f93da8e3148` |

Rust's image revision matches current source main. Jai's current source main is
`b0952a20541fadda3ac0eb7991e9d75acca25799`; its changes after the published `2ecd487`
are documentation only. Jai's image does not carry a revision label, so its association
with that tag comes from the published image and [upstream submission](https://github.com/basecamp/once-campfire-verification/pull/11).
The digest below is the exact artifact measured. Source references were rechecked on 2026-10-23 UTC.

| Artifact | SHA-256 |
|---|---|
| Goose local image ID | `81c9d6cfa78a20df7b0bcec8327bcd4c70fcf6d4faf4a17b3fb9e6a2b4841a45` |
| Goose executable | `4272e14810ef82104b617acc90fb6e41dca9487312820c26c6dcf6d0d4b104a3` |
| A/B before Goose image ID | `7d279f50d36a1719b088f33edcc80b13abec04ad6736f38a3fbd79253189083c` |
| A/B before Goose executable | `27dddc1ea704c640ae0e0d8daaafd1d60699e1a6ae3ef14f6ecce3da90061af0` |
| Rust GHCR image digest | `98ba156f688c3fe856afd71655f613a6620bc03754f456ed2ef08fb2e5527e6e` |
| Jai GHCR image digest | `bbbe5c642001c653906dbe4d6f6d584090b82b352724c77d5f134a081506829e` |
| Shared load generator | `f4e5801a7b5ff6ba1a1b8919a007f7d409e79c2f88433299c944c424aa24aecb` |
| Shared validator | `554f9415178dc067c120ce0f9363ddec93007815334305f72d02290e9ff93c3b` |
| Shared contracts | `9bb1afd6ba16b49cdfcc84d32a3701abb10435721d018b07897a4840c2751755` |
| Shared write auditor | `a1cdf6cf005bf20714ccb7fe14e9cb48b0ae0aa05baed1a48f8bc26b17c91387` |
| Seed database | `378b2275a197092b31aec7295b0a5c2fbfc24af94d3001ddd095c3b08832c251` |

Package revisions, the patch checksum and resulting tree, and the SQLite source were pinned in
that revision's
[`dependencies.json`](https://github.com/kaitk/once-campfire-goose/blob/af65824e896a496b4b685d7a692e298a7abc1106/dependencies.json). The browser's Playwright image is pinned
in `test_browser.py`. Source and verifier checkouts were clean when measurement started.

## Reproduce on Linux

The app builds with Docker. The measurement host also needs Python 3.11+, Ruby, SQLite CLI,
FFmpeg, Git, `taskset`, and the shared verifier's Rust toolchain (1.98.1 in its README).
Use native Linux storage for the fixture and runtime copies. From this repository:

```sh
git clone https://github.com/basecamp/once-campfire-verification.git build/verification
git -C build/verification checkout ec02debb3e44f40b8778a6a42db3c4515b2f9eaf
cargo build --release --locked --manifest-path build/verification/loadgen/Cargo.toml
build/verification/bin/seed --output /tmp/campfire-shared-seed

docker pull ghcr.io/basecamp/once-campfire-rust@sha256:98ba156f688c3fe856afd71655f613a6620bc03754f456ed2ef08fb2e5527e6e
docker pull ghcr.io/lucasmeijer/once-campfire-jai@sha256:bbbe5c642001c653906dbe4d6f6d584090b82b352724c77d5f134a081506829e
docker build --build-arg GIT_REVISION="$(git rev-parse HEAD)" -t once-campfire-goose:app .
python3 test_image.py once-campfire-goose:app
python3 test_browser.py once-campfire-goose:app --verification "$PWD/build/verification"
python3 test_rendering.py --seed /tmp/campfire-shared-seed --runtime-root /tmp/campfire-bench \
  --output build/render-rust --reference rust --extended
python3 test_rendering.py --seed /tmp/campfire-shared-seed --runtime-root /tmp/campfire-bench \
  --output build/render-jai --reference jai --extended

python3 benchmark_shared.py --verification "$PWD/build/verification" \
  --seed /tmp/campfire-shared-seed --runtime-root /tmp/campfire-bench \
  --output build/comparison --client-cores 4 --goose-backend auto \
  --rust-image ghcr.io/basecamp/once-campfire-rust@sha256:98ba156f688c3fe856afd71655f613a6620bc03754f456ed2ef08fb2e5527e6e \
  --jai-image ghcr.io/lucasmeijer/once-campfire-jai@sha256:bbbe5c642001c653906dbe4d6f6d584090b82b352724c77d5f134a081506829e
```

The fixture builder generates fresh disposable credentials, so a new seed has a different
database hash. The runner records it. Use a new output directory for each run and keep the
tracked source clean. `test_rendering.py` uses the reference digests in
`reference_server.py`; the HTTP comparison above also selects explicit image digests.
