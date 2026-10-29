# Fan-out delivery: coalescing, shared bodies, zero-copy sends and per-worker delivery

Measured on 2026-10-28. Results against Jai come from a Ryzen 7 PRO 6850U laptop (WSL2,
Docker Engine) with the shared verifier, `benchmark_shared.py` and the published Jai image
(`ghcr.io/lucasmeijer/once-campfire-jai@sha256:bbbe5c64…`). Every sample and scenario run
validated, and the full suite and native io_uring tests passed. The per-change numbers come
from same-session A/B runs on a MacBook (M1) under Docker's arm64 VM, where Jai doesn't run.

"Fan-out" is complete messages per second, each received by every reader. Unless stated
otherwise: 64 WebSocket readers with 6 subscriptions each, 4 posters, rotated rounds, medians.

## Against Jai (6850U, same-run ratios)

64 readers (`benchmark_shared.py`), Goose / Jai fan-out on epoll:

| revision | queued-8 | queued-128 | default (drained, 8) |
|---|---:|---:|---:|
| upstream `37189c6` | 0.58–0.63× | 0.60–0.65× | — |
| `d33b4c3` (changes 1–3) | 0.87–0.95× | 0.94–0.95× | — |
| `4b78473` (changes 1–7) | 0.93–0.96× | 0.89–0.94× | 0.63–0.66× |
| **`cf542ab` (all changes)** | **1.34×** | **1.35×** | **1.04×** |

At `cf542ab`, Goose uses 0.63–0.68× Jai's CPU per message. Its delivery p99 is 3.7–4.1 ms
queued and 2.5–2.7 ms with the default, against 4.0–4.1 ms for Jai, and its POST p99 is
lower than Jai's. On native io_uring the ratios are 1.38×, 1.39× and 1.08×. Posts were
already about 1.55× Jai's, and memory about a third.

Jai's own fan-out scenario (`bench/scenarios/fanout`, DEFLATE=0: 30 posts 200 ms apart, then
4 posters for 15 s), `cf542ab` / Jai:

| | 2,000 clients | 10,000 clients |
|---|---:|---:|
| paced delivery p50 / p99 | 0.93× / 0.94× | 0.96× / 0.95× |
| saturated delivery rate | 0.50× (`4b78473`: 0.21×) | 0.40× (0.24×) |
| saturated CPU per delivery | 2.0× | 2.5× |
| paced CPU per delivery | 1.16× | 0.95× |
| peak anonymous memory | 0.07× (20 MiB vs 297) | 0.23× (43 vs 188) |

At this scale Goose now matches Jai's latency and CPU for paced traffic, and uses a small
fraction of its memory. Under saturation Jai still delivers twice as fast, at half the CPU per
delivery. The rate also varies more between rounds for Goose (86 against 125–132 msg/s at 2,000).
Uneven readers per worker don't explain it: SO_REUSEPORT spreads the 2,000 connections within
±4% of even across the workers. The local collapses we saw came from the host (see
[local bench pitfalls](#local-bench-pitfalls)).

Step 9 has not been measured against Jai on the 6850U yet; locally it lifts saturated delivery
at 2,000 readers by 11% over `cf542ab`.

## Against the baseline (M1, same session)

Against upstream `37189c6` (the head of `codex/campfire-experiment` and goose-http v0.5.11):

| | baseline | this branch | ratio |
|---|---:|---:|---:|
| 64 readers, default configuration: fan-out msg/s | 1,669 | 3,245 | 1.94× |
| 64 readers, default configuration: delivery p99 | 4.3 ms | 2.6 ms | 0.61× |
| 64 readers, best configuration (baseline queued-128, branch queued-8): fan-out msg/s | 1,940 | 3,816 | 1.97× |
| 64 readers, best configuration: delivery p99 | 101 ms | 4.5 ms | 0.04× |
| 2,000 readers (queued-128 / queued-8): fan-out msg/s | 56.7 | 159.6 | 2.8× |
| 2,000 readers: server CPU per message | 58.6 ms | 15.9 ms | 0.27× |
| 2,000 readers: delivery p99, saturated / paced | 2.4 s / 40.5 ms | 86 ms / 23.5 ms | |

Cached room reads (~230k/s) and posts (~7,400/s) are unchanged. Anonymous memory after
fan-out is unchanged too: 24–31 MiB at 64 readers and 23–26 MiB with 2,000 live WebSockets.
The baseline 64-reader rows are 2 rounds and the 2,000-reader row 1 round, as a final check;
the per-change rows below are 3 rounds each.

On a Ryzen 7 PRO 6850U laptop (WSL2) with the verifier and current Jai, the first three
changes alone (at `d33b4c3`) measured 1.50–1.57× the baseline's fan-out, which is 0.94× Jai at
queued-128, with ~40% less CPU per message.

## Changes, in commit order

1. **Coalesced frames** (`c45867a`). A delivery carries pending frames up to `CABLE_BATCH`
   (32 KiB) instead of one batch per drain credit, so a reader that falls behind catches up
   in fewer, larger sends.
2. **Credit only real deliveries** (`93e1e7c`). Pings and subscription confirmations no
   longer count as drain credits, which used to let the broker over-send.
3. **Shared bodies** (`9542706`). The broker encodes a publication once into a refcounted
   goose-http shared blob, and each delivery mail describes inline bytes and ranges of it
   instead of carrying a copy. Locally: queued-128 fan-out 1,905 → 2,871 msg/s, CPU/msg
   −40%, delivery p99 84 → 15 ms (steps 1–3 together).
4. **Linear entity scan** (`8e627f6`). Rendering sought each `&`'s `;` to the end of the
   message, so a 40 KB `&`-heavy post took ~0.4 s (200,000 `&`: 17 s, now 5 ms). It was a
   real post-path bug, and it caused the flaky window-512 pressure test (`d33b4c3` also
   made that test tolerate slow hosts).
5. **Broker work list** (`3fb6070`). Each delivery pass visits only connections that were
   credited, enrolled, unsubscribed or refused for a full mailbox, and a credit names its
   connection's index, so a credit no longer costs O(connections). Fan-out at 10,000
   readers: 11.7 → 19.5 msg/s, CPU/msg −18%; unchanged at 64 and 1,000.
6. **`CAMPFIRE_HTTP_MAX_CONNS`** (`c5610fd`). Opt-in per-worker connection and waiting
   limits (default unchanged, 1,024), needed above ~4,000 readers.
7. **goose-http pin with zero-copy shared sends and checked blob handles** (`4b78473`, then
   the mutex follow-up). `send_shared` ranges go out from their blobs with `sendmsg` (epoll)
   or an io_uring `sendmsg` (native and emulated rings); only bytes the socket doesn't
   take get copied. TLS and Windows still copy. Blob handles are generation-checked, so a
   stale or forged handle is refused instead of read. queued-8 fan-out +19%, CPU/msg −11%.
8. **Per-worker delivery** (`4ca9f64` and its tests). The broker keeps the global order,
   window, acknowledgements and retirement, but mails each worker every publication once;
   each worker enrolls, writes and credits its own readers, and credits the broker once per
   publication. The broker's serial work per message is O(workers) instead of O(readers).
   Against step 5 on the same goose-http pin: 64 readers +23% fan-out, CPU/msg −30%;
   2,000 readers +51% fan-out, CPU per delivery −46%, paced delivery p50 28 → 18 ms.

9. **Worker addresses and the empty-recv skip** (`a62f2f8`, goose-http pin
   `v0.5.11-campfire.2`). goose-http now gives each worker a mail address of its own, delivered
   as a WORKER event, and lets a worker wake its own exchanges without a mailbox slot. The broker
   mails that address instead of one of the worker's connections, so the representative
   connection, its hand-over when it leaves and the per-connection kick mail are gone (the box
   shrinks from 2,048 slots to 512 at window 8). The same pin skips the recv after a wake when
   the socket was found empty and no edge has come since: at 2,000 readers, 6 s of saturated
   fan-out made 1,775 `recvfrom` calls instead of 1,819,379, nearly half the server's syscalls. Against `cf542ab` rebuilt on the same pin, same session, 3 rotated rounds: 2,000
   readers saturated 298.0 → 331.5 msg/s (+11%), server CPU per message 9.5 → 8.9 ms (−7%),
   delivery p99 66 → 55 ms; at a fixed 2,000-reader load CPU per message −6%; 64 readers
   4,730 → 4,850 msg/s (+2.5%), CPU/msg −3%. Reads and posts are unchanged.

Steps 7 and 8 together: 64 readers 4,177 msg/s (3,204 with step 7 alone, 3,796 with step 8
alone); 2,000 readers 7.6 µs CPU per delivery (16.8 and 10.0).

### Delivery semantics after steps 8 and 9

Ordering, bounded memory, stalled-reader retirement, unsubscribe cancelling unsent
deliveries, finishing an already-started message before its identifier is reused, the
window, permits and 503 on exhaustion are unchanged; see
[browser coverage](browser-parity.md). One thing moved: a publication enrolls a worker's
subscribers when it reaches that worker, so a subscription confirmed between broker
enrollment and that moment receives it, a slightly later, still causal, cut-off.

The broker mails each worker at its goose-http worker address, and a worker wakes its ready
readers locally; neither depends on any one connection staying open. A worker whose last
connection leaves is credited at once and skipped, and is enrolled in later publications
when it has connections again. Each worker's box holds 4 × window + 256 slots of 128 bytes
(512 at window 8; it was 128 of 8 KiB before step 8).

It also fixes a gap: a client's WebSocket Close ended its exchange without CLOSED, so its
presence was never cleaned up. Workers now run the same leave and presence cleanup.

## Tried and dropped

So nobody needs to redo them:

- **Batched drain credits:** a lock-free stack where only the push onto an empty stack
  wakes the broker. Over two A/Bs, throughput was within noise and CPU/msg −1.5 to −3%;
  the profile put all queue wake-ups at ~3.6%. Not merged.
- **`CABLE_BATCH` size:** 8 KiB cost 23% fan-out and +33% CPU/msg; 64 KiB gained nothing.
  It stays 32 KiB.
- **Larger publication windows after step 5:** queued 8, 16, 32, 64 and 128 are within
  noise on throughput (2,878–3,018 msg/s), and queued-8 has the lowest delivery p99 (6.7 vs
  10.1 ms at 128); at 2,000 readers queued-8 matches queued-128 as well. A large window no
  longer buys throughput. After step 9 at 2,000 saturated readers, queued 8, 64 and 128
  gave 313.5, 309.4 and 298.0 msg/s, with p99 63, 67 and 68 ms (3 rounds). The window
  doesn't decide how many frames a write carries here; see [Jai's design](#jais-design).
- **A limit on kicks in flight per worker** (fork branch `fanout-batch`), so that publication
  mail interleaves with a long round of kicks: limits of 8, 32 and 128 at 2,000 readers were
  within the spread of the runs (k8 against the head: 169.9 vs 172.0, 262.9 vs 250.1 and
  294.5 vs 260.7 msg/s over three A/Bs, heads ranging 226–288). Step 9 removed the kick
  mail it was bounding.
- **Native io_uring as the default backend:** at `d33b4c3` it passed its tests but wasn't ≥
  epoll (memory +20–27%). After step 7 it led epoll by 8–29% at `4b78473`, but after step 8
  the lead is about +3% fan-out, with about 20% more memory. The default stays epoll.
- **The second timer re-arm per delivery** (`http::later` at WAKE and again at DRAINED):
  ~1% in the profile. Unchanged.
- **Zero-copy under TLS:** not attempted. Sealing needs contiguous plaintext, and
  encryption is a copy anyway.

## Jai's design

Jai has no broker. The thread that handles a POST matches the subscribers itself and appends
a reference to the shared frame to each subscriber's outbox, under that connection's mutex,
then wakes the connection's event loop. The loop swaps the outbox out and writes it oldest
first, up to 64 frames per `writev`. An outbox holds up to 4,096 frames before the poster
waits for that subscriber (65,536 before a broadcast that can't wait disconnects it), so a
POST is acknowledged once its message is queued for every subscriber, and publications from
concurrent posts proceed in parallel.

Goose orders every publication through one broker thread, and retires a publication only
after every enrolled reader's batch has drained to its socket, through a global window of 8 by
default (up to 512). Each worker mails the broker one credit per publication. A reader writes as
soon as it is ready, which with fast clients is almost always, so a write carries what arrived
since the last one: 1.2–1.4 deliveries per `sendmsg` at 2,000 saturated readers on the 6850U,
where about 75% of the server's CPU is the kernel's send path. A larger window only lets more publications
queue up in the broker; it doesn't hold writes back, so it doesn't batch them (above). The
levers left are batching per reader (writing on a worker's tick, or after its pending mail,
instead of on every arrival) and a bound per worker or per reader in place of the global
window.

## Write pacing (experimental, branch `fanout-pace`)

Why Goose writes ~2 frames per `sendmsg` at saturation: posts are handled on the same worker
loops that write to the readers, so a POST waits behind a pass of sends, and publications arrive
only as fast as every reader drains. No reader builds a backlog, and neither a 256 KiB–1 MiB batch
nor a queued window of 64–512 changed that (2.0–2.4 frames per send at 2,000 readers). Jai handles
posts on their own threads, so its outboxes fill while the loop is busy.

`CAMPFIRE_CABLE_PACE_MS` holds a reader's next batch back until D ms after its last write, unless
`CAMPFIRE_CABLE_PACE_FRAMES` (16) publications wait; a reader idle for D ms writes at once, so
paced latency doesn't change. The window must hold D ms of publications, but a larger one only
queues more: posts fill every permit, and p99 grows to the queue's depth. M1 laptop, 2,000
saturated readers, queued acknowledgement, 3 rotated rounds, medians:

| window, pace | msg/s | saturated p99 | CPU per message | frames per send | anon |
|---|---:|---:|---:|---:|---:|
| 64, off | 320 | 63 ms | 8.9 ms | 2.0 | 19–22 MiB |
| 16, 10 ms | 339 | 87 ms | 7.3 ms | 4.4 | 18–20 MiB |
| 16, 20 ms | 411 | 80 ms | 5.7 ms | 9.5 | 19–20 MiB |
| 16, 30 ms | 400 | 95 ms | 5.3 ms | 13.2 | 13–24 MiB |
| 32, 20 ms | 407 | 106 ms | 5.8 ms | 9.4 | 18–20 MiB |
| 32, 30 ms | 423 | 119 ms | 5.3 ms | 14.3 | 16–18 MiB |
| 64, 40 ms | 387 | 327 ms | 4.7 ms | 16.5 | 110–150 MiB |
| 512, 40 ms | 465 | 643 ms | 4.8 ms | 18.5 | 212–320 MiB |

Window 16 with 20 ms gives about +28% at +17 ms of p99 and no extra memory. Longer pacing raises
frames per send but not throughput here. The memory of the large-window runs is goose-http copying
the unsent part of a send that the socket didn't take into each connection's own buffer. At
10,000 readers each reader gets a frame only every ~20 ms, so pacing there needs ~100 ms.

## Requests first (experimental, branch `fanout-post-first`)

`CAMPFIRE_REQUESTS_FIRST=1` sets goose-http's `Config.requests_first` (tag
`v0.5.11-campfire.3-rf`, epoll loop only): each pass serves its plain HTTP events, so posts and
their mailed acknowledgements, before its WebSocket connections' events and the cable wakes. M1
laptop, 2,000 saturated readers, 4 posters, queued acknowledgement, 5 rotated rounds, medians
(ranges):

| variant | msg/s | POST p50 / p99 | saturated p99 | paced p99 | CPU per message | frames per send |
|---|---:|---:|---:|---:|---:|---:|
| window 8 | 291 (266–301) | 12.3 / 41.2 ms | 94 ms | 26 ms | 9.7 ms | 1.9 |
| window 8, requests first | 299 (247–308) | 12.2 / 37.0 ms | 84 ms | 26 ms | 9.4 ms | 2.0 |
| window 16, pace 20 ms | 412 (380–422) | 7.9 / 36.8 ms | 96 ms | 24 ms | 5.7 ms | 9.4 |
| window 16, pace 20 ms, requests first | 380 (343–431) | 8.5 / 42.2 ms | 96 ms | 31 ms | 6.0 ms | 8.7 |

Requests first doesn't change POST p50 alone and costs a little with pacing. A post rarely
waits behind the sends of its own pass. It waits for that pass to end, because its request and
its acknowledgement are only seen at the next wait. Reordering a pass can't shorten that;
pacing does, by making passes cheaper (POST p50 12.3 → 7.9 ms).

## Local bench pitfalls

- The verifier's load generator is client-bound on arm64: its scalar `str::contains` over every
  received frame saturates the client cores before the server. Locally we use a variant that
  searches with `memchr` (`campfire-benchbox:fast`) and give the server 3 cores and the client 7.
- A laptop that sleeps or throttles mid-run collapses a round (25–90 msg/s against ~300 at 2,000
  readers, p99 over a second). Docker Desktop reports no steal time, so the harness can't detect
  it; keep the machine awake and rerun rounds that collapse.
- Compare only within one session, in rotated rounds: the same image's medians moved by more
  between sessions than most changes measured here.

## Method

`perf` profiles, taken under saturated fan-out after step 3, ranked the remaining costs:
the kernel TCP send path ~37% (inflated locally: the load generator and loopback share the
VM), the per-reader body copy ~12%, the broker ~9%, worker-to-broker wake-ups ~3.6%. At
10,000 readers the broker thread was saturated in its per-credit scans (step 5). With 2,000
readers and paced posts, it spent ~20 ms of serial CPU per message (step 8).
