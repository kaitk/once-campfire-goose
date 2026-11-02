# Fan-out delivery: coalescing, shared bodies, zero-copy sends and per-worker delivery

Measured on 2026-10-28 and 29, with a reproduction on a second machine added on 2026-11-02. Results against Jai come from a Ryzen 7 5800X3D desktop and a
Ryzen 7 PRO 6850U laptop (both WSL2, Docker Engine), with the shared verifier,
`benchmark_shared.py`, Jai's own `bench/scenarios/fanout` and the published Jai image
(`ghcr.io/lucasmeijer/once-campfire-jai@sha256:bbbe5c64…`). Every sample and scenario run
validated, and the full suite and native io_uring tests passed. The per-change numbers come
from same-session A/B runs on a MacBook (M1) under Docker's arm64 VM, where Jai doesn't run.

"Fan-out" is complete messages per second, each received by every reader. Unless stated
otherwise: 64 WebSocket readers with 6 subscriptions each, 4 posters, rotated rounds, medians.

## Status

The experiment is concluded (2026-11-02); its changes are merged with
[PR #1](https://github.com/aardappel/once-campfire-goose/pull/1). A run by Wauter, Goose's
author, on his own desktop reproduces the gains ([below](#second-machine)). Two things remain open:

- **Saturated throughput at 2,000 and more readers**, where Goose runs 0.56–0.78× Jai's rate. The
  gap is frames per send (about 6 against Jai's 29, see [Jai's design](#jais-design)); closing it
  likely means handling posts off the threads that write to readers, which Jai does.
- **The goose-http pin** is the tag `v0.5.11-campfire.3` on an experiment branch, until those
  changes are in a goose-http release.

## Defaults

Publications are acknowledged once queued (`CAMPFIRE_PUBLICATION_ACK=queued`): after the
database commit and after the broker has retained the payload and snapshotted its subscribers,
not after every reader's socket drained. That is the point at which Jai acknowledges too (see
[Jai's design](#jais-design)). `CAMPFIRE_PUBLICATION_ACK=drained` restores the stricter
acknowledgement. The window stays 8, a cable batch is up to 256 KiB, and a worker wakes at most 16
readers per loop pass ([pass cap](#pass-cap)). Write pacing is available but off.

## Against Jai (5800X3D, this branch)

Same-round ratios, Goose / Jai, at `210a469` with the settings that are now the defaults:

| | Goose | Jai | Goose / Jai |
|---|---:|---:|---:|
| 64 readers (`benchmark_shared.py`): fan-out msg/s | 4,170 | 2,942 | **1.37–1.45×** |
| 64 readers: CPU per message | 0.60 ms | 0.96 ms | 0.62× |
| 64 readers: delivery p99 | 4.05 ms | 3.76 ms | 1.08× |
| Jai's scenario, 2,000 clients: saturated msg/s | 286 | 470 | **0.61×** |
| 2,000 clients: saturated delivery p99 | 67 ms | 4,846 ms | **0.014×** |
| 2,000 clients: paced delivery p50 / p99 | 10.2 / 17.4 ms | 11.3 / 16.2 ms | 0.90× / 1.07× |
| 2,000 clients: CPU per delivery | 6.6 µs | 4.2 µs | 1.58× |
| 2,000 clients: peak anonymous memory | 16 MiB | 305 MiB | **0.05×** |
| Jai's scenario, 10,000 clients: saturated msg/s | 69 | 89 | **0.78×** |
| 10,000 clients: saturated delivery p99 | 248 ms | 15,081 ms | 0.016× |
| 10,000 clients: peak anonymous memory | 38 MiB | 651 MiB | 0.06× |
| 2,000 clients, 16 posters: saturated msg/s | 393 | 494 | 0.80× |

How the 2,000- and 10,000-client rates got there, on the same machine (Goose / Jai):

| | 2,000 | 10,000 |
|---|---:|---:|
| step 9, drained acknowledgement, 32 KiB batch | 0.32× | 0.31× |
| queued acknowledgement | 0.45× | 0.49× |
| + 256 KiB batch | 0.49× | 0.58× |
| + pass cap, K 16 (the defaults) | 0.61× | 0.78× |

Jai ran 470 msg/s at 2,000 in the pass-cap session and 520 in the batch session, so the last
row's 2,000-client ratio is a little flattering (about 0.55× against 520); the 10,000 figures held
(89 and 96). On the 6850U, which has a sixth of the L3, Jai runs 0.40× of its desktop rate and
Goose 0.65×, so every ratio there sits higher: queued-8 at `d1e12a1` was 0.73× at 2,000 and
0.93× at 10,000, and 1.46× at 64 readers.

Where Jai still leads is saturated throughput at 2,000 and more readers, POST latency under load
(3.7 against 13.9 ms) and CPU per delivery. It pays for the throughput with its queues: Jai's
outboxes hold up to 4,096 frames per reader, so under saturation its delivery p99 is 5–15 s and
its memory 300–650 MiB, while Goose's window keeps p99 at tens of ms and memory near 20 MiB.

## Second machine

Wauter merged PR #1 and ran a quick comparison on his own desktop: four server
cores per app, two shared samples and one sample per larger configuration. The hardware and
the exact settings of the deeper, paced Goose run weren't reported, and this is a summary of
his results rather than the raw samples. Every case passed the delivery and persistence checks.

| | Goose | Jai | Goose / Jai | 5800X3D, above |
|---|---:|---:|---:|---:|
| cached reads/s | 379,498 | 310,009 | 1.22× | |
| posts/s | 6,132 | 4,174 | 1.47× | |
| 64 readers: fan-out msg/s | 4,667 | 3,198 | **1.46×** (1.44× in the other sample) | 1.37–1.45× |
| 2,000 clients: saturated msg/s | 270 | 483 | **0.56×** | 0.61× |
| 2,000 clients, deeper window with pacing | 292 | 483 | 0.60× | |
| 10,000 clients: saturated msg/s | 57.9 | 98.9 | **0.59×** | 0.78× |
| 10,000 clients, deeper window with pacing | 65.8 | 98.9 | 0.67× | |
| saturated delivery p99 | 80–635 ms | 5.8–7.3 s | | 67–248 ms / 4.8–15 s |
| peak anonymous memory | 16–39 MiB | 327–509 MiB | | 16–38 / 305–651 MiB |

The 64-reader lead and the latency and memory advantages reproduce. At 2,000 clients the rate
matches the 5800X3D's (0.61× there was a little flattering, about 0.55× against Jai's other
session). At 10,000 his Jai ran faster (98.9 against 89–96 msg/s) and Goose slower (57.9 against
69), which with one sample each leaves 0.59× against 0.78×. Pacing helped at both sizes there,
where on the 6850U it was neutral at 10,000; it stays off by default.

## Against Jai (6850U, at `cf542ab`)
64 readers (`benchmark_shared.py`), Goose / Jai fan-out on epoll:

| revision | queued-8 | queued-128 | drained, 8 (then the default) |
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

Steps 9–12 are in the 5800X3D tables above.

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

10. **256 KiB batches** (`eba111e`, `432bf06`). `CAMPFIRE_CABLE_BATCH` sets the most frame bytes
    one reader write carries (a power of two from 16 KiB to 1 MiB; 64-bit frame lengths above
    64 KiB), and the default is now 256 KiB. A 32 KiB batch holds three ~10 KB frames, which is
    where queued-8 sat. 5800X3D, queued-8: +9% fan-out at 2,000 readers (0.49× Jai) and +18% at
    10,000 (0.58×), CPU per delivery −9 to −16%; frames per send 2.8 → 3.3–4.0. 6850U: +9% at
    10,000, none at 2,000. Nothing for drained acknowledgement, which sends 1.6 frames per call
    at either size. Memory is unchanged: frames go out from the shared bodies.
11. **Local wakes right after the worker's mail** (`d1e12a1`, goose-http `v0.5.11-campfire.3`).
    goose-http delivers a worker's local wakes as soon as it has taken the worker's mail, instead of
    on a later turn. On the 5800X3D, 64-reader queued-8 delivery p99 is 4.14 ms against 8.26 at
    step 9 in the same session (4.48 / 4.59 / 3.80 / 3.75 against 13.01 / 8.26 / 8.26 / 4.76), with
    fan-out unchanged (1.40–1.44× Jai). The 6850U never showed step 9's raised p99.
12. **Pass cap and new defaults** (`210a469` and the default change). See [pass cap](#pass-cap);
    the defaults became queued acknowledgement, window 8 and K 16.

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
- **`CABLE_BATCH` size, before step 10:** 8 KiB cost 23% fan-out and +33% CPU/msg; 64 KiB gained
  nothing on the M1, which sends ~1.9 frames per call, so the cap never bound there. Step 10's
  256 KiB gain only shows on the desktop and at 10,000 readers.
- **A larger window with 256 KiB batches:** it doesn't raise frames per send on its own, since a
  reader writes as soon as it's ready (see [write pacing](#write-pacing)).
- **Fewer posters per run:** Jai's scenario fixes 4 closed-loop posters, so Goose's saturated rate
  there is posters ÷ POST latency (4 / 13.9 ms ≈ 288 msg/s against 286 measured). With more
  posters Goose rises and Jai doesn't: on the 6850U at 2,000 readers, 4 → 8 → 16 posters took Goose
  146 → 173 → 224 msg/s (0.67× → 0.82× → 1.09× Jai) and 2.85 → 7.83 frames per send, while Jai stayed
  at 208–216. On the 5800X3D 16 posters reach 0.82× (404 against 494).
- **Requests first** (fork branch `fanout-post-first`, goose-http `post-priority`): a loop pass
  serves plain HTTP events before upgraded connections and wakes, so posts don't wait behind
  sends. M1, 5 rounds: POST p50 12.2 against 12.3 ms, 299 against 291 msg/s (noise); with pacing
  −8%. A post is seen only when its pass ends, so reordering within the pass can't help; the
  pass cap, which shortens passes, does.
- **campfire.2's +5–8% user cycles in `bench/count.sh`:** Zen 3 op-cache placement, not work. It
  adds 7.6 instructions per request; building with `-falign-functions=64 -falign-jumps=32` erases
  the epoll gap and reverses the io_uring one, and the hot functions are byte-identical, only moved.
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
concurrent posts proceed in parallel. At 2,000 saturated readers it writes 27–29 frames
(~335 KB) per `writev`.

Goose orders every publication through one broker thread, and retires a publication only
after every enrolled reader's batch has drained to its socket, through a global window of 8 by
default (up to 512). Each worker mails the broker one credit per publication. A reader writes as
soon as it is ready, which with fast clients is almost always, so a write carries what arrived
since the last one: 1.2–1.4 deliveries per `sendmsg` at 2,000 saturated readers on the 6850U at
step 9, where about 75% of the server's CPU is the kernel's send path. With the defaults it is 5.8
on the 5800X3D (3.3 without the pass cap), still a fifth of Jai's; the per-call cost is likely most of
the remaining gap in CPU per delivery. A larger window only lets more publications queue up in
the broker; it doesn't hold writes back, so it doesn't batch them (above). The two levers tried
are below: the pass cap (on by default) and write pacing (off).

## Pass cap

`CAMPFIRE_CABLE_PASS_READERS=K` (default 16; 0 turns it off) makes `cable_pump` wake at most K
listed readers, in order, and wake the rest only once each of those K was called (by its WAKE or
an earlier event) or left. goose-http delivers wakes asked for while it delivers others on its
next call, and a pending wake makes the next wait a zero-timeout poll, so a worker writes K
readers at a time and polls for posts and acknowledgements in between, instead of writing all of
its ~667 ready readers (at 2,000) in one pass. The gate matters: every serviced reader calls
`cable_pump`, so without it K readers would wake K each. A kick that was sent always ends in a
call or a leave, and a live reader's own 3 s TIMEOUT calls it anyway, so the chain can't stall.

M1 laptop, 2,000 saturated readers, 4 posters, queued acknowledgement, 5 rotated rounds,
medians (ranges), all from one session:

| variant | msg/s | POST p50 / p99 | saturated p99 | paced p99 | CPU per message | frames per send | `epoll_pwait`/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| window 8 | 267 (258–279) | 13.3 / 46.2 ms | 102 ms | 29 ms | 10.2 ms | 1.9 | 621 |
| window 8, K 8 | 306 (293–314) | 11.2 / 49.4 ms | 124 ms | 29 ms | 8.5 ms | 3.0 | 24,289 |
| window 8, K 16 | 300 (284–321) | 11.4 / 47.5 ms | 125 ms | 33 ms | 8.4 ms | 3.1 | 11,892 |
| window 16, pace 20 ms | 354 (326–374) | 8.7 / 43.8 ms | 127 ms | 25 ms | 6.3 ms | 8.4 | 1,359 |
| window 16, pace 20 ms, K 16 | 355 (338–369) | 8.8 / 45.6 ms | 142 ms | 24 ms | 6.5 ms | 8.4 | 5,336 |

Two earlier sessions agree: K 16 +15% (302 vs 263 msg/s, ahead in all 5 rounds), K 32/64/128/256
+12/+12/+11/+6%. Smaller K did better each time, down to 16; K 8 ties it with twice the polls. The
cap does what it set out to: posts are seen sooner (POST p50 −15%), readers find more
publications pending (frames per send 1.9 → 3.1), and CPU per message falls 17%. It reaches
only 3 frames per send, against pacing's 8, and pacing on top of it gains nothing, because pacing
already keeps passes short. Saturated p99 rises 10–20%: a reader's frames wait for its chunk.

5800X3D, queued-8 with 256 KiB batches, 3 rotated rounds with Jai in each, medians (ranges):

| variant | 2,000: msg/s | × Jai | POST p50 | CPU per delivery | 10,000: msg/s | × Jai | POST p50 | sat p99 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| K off | 243.8 (215–251) | 0.52 | 14.3 ms | 8.1 µs | 52.8 (46–54) | 0.60 | 69.5 ms | 298 ms |
| K 16 | 286.4 (285–295) | 0.61 | 13.9 ms | 6.6 µs | 69.3 (68–73) | 0.78 | 58.1 ms | 248 ms |
| K 64 | 278.6 (277–280) | 0.59 | 13.7 ms | 7.1 µs | 67.7 (68–70) | 0.76 | 57.2 ms | 234 ms |
| Jai | 469.7 (459–476) | — | 3.7 ms | 4.2 µs | 88.6 (88–94) | — | 15.9 ms | 15,081 ms |

K 16 is ahead in every round at both sizes, by at least 14% at 2,000 against the uncapped best
round. Frames per send rise 3.3 → 5.8 while `sendmsg` calls fall by a third, and polls rise from
~320 to ~5,800 per second. Saturated p99 doesn't rise here (65 → 67 ms at 2,000). K 64 reaches the
same frames per send with a sixth of the polls but runs 3–5% slower: K 16's shorter chunks let
posts in sooner. With 16 posters K 16 is 2.7% behind (393 against 404 msg/s over 4 rounds, between
1.5% and 6.7% each): posters already keep passes short, so the cap only adds polls. At 64 readers a
worker has about 16 readers and the cap rarely splits a pass (delivery p99 4.05 against 3.99 ms).

## Write pacing

Experimental and off by default (merged from fork branch `fanout-pace`).

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

6850U, 4 posters, against Jai in the same rounds: window 16 with 20 ms is 0.855× Jai against
queued-8's 0.753× at 2,000 readers (+14%, 4.9 frames per send), with paced p99 unchanged; window 32
equals window 16. At 10,000 readers it's neutral, and window 32 with 100 ms is −10% with a 1.2 s
saturated p99. With 16 posters it's −4% (1.030 against 1.076× Jai). On the M1 the pass cap adds
nothing on top of it (355 against 354 msg/s), and on its own the pass cap gives about half
pacing's gain there. It delays a reader that wrote within the last D ms, which would likely raise the 64-reader delivery p99 (not measured), so it stays off.

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
