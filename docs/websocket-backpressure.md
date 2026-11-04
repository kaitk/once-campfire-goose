# Outbound WebSocket flow control

The experimental application pins upstream including the
[merged PR](https://github.com/kaitk/goose-http/pull/2), which adds `after_drain` and
`DRAINED`, allowing a publisher to send one bounded batch per socket drain credit.
All 60 package tests pass at both optimization levels. A mailbox publisher test
stalls its reader, resumes, and verifies 32 MiB in exact order on both loops with
no measurable RSS increase during the stall. The drain API and fairness fix are upstream, and
the application applies no patches ([dependency patches](../patches/README.md)); the
emulated-ring send patch it once carried was [retired](send-copy-pr.md).
The historical reproduction below describes sending without those credits.

## Reproduction

The isolated probe upgrades one loopback connection to WebSocket and sends 4,096 messages of
8,192 bytes through the package mailbox: 32 MiB of payload, then the publisher stops. The mailbox
has only eight slots. `Config.max_queued` is 4,096 bytes. The slow client reads the upgrade headers
and then stops reading. The control drains every frame. These are process RSS samples, not a
Campfire benchmark or exact counts of queued bytes.

| Package / loop | Client | RSS growth |
|---|---|---:|
| v0.4.3 / `serve` | not reading | 47.68 MiB |
| v0.4.3 / `serve` | reading all frames | 0.75 MiB |
| v0.5.4 / `serve` | not reading | 48.86 MiB |
| v0.5.4 / `serve` | reading all frames | 0.68 MiB |
| v0.5.4 / `serve_epoll` | not reading | 64.54 MiB |

Both versions compile with the public pinned Goose compiler. The explicit epoll loop uses
`write_buffer` (8 KiB here), not `max_queued`, as its ordinary response-pressure threshold.
The environment was Linux/Docker under WSL2 with the default security profile. `serve` can use
its io_uring emulation in this environment; the diagnosis concerns the common mailbox path.
Exact bytes, revisions and controls are in [the measurement record](../repro/backpressure-results.json).

From a standalone Linux development checkout after `sh build_linux.sh`:

```sh
export GOOSE_HOME="$PWD/build/home"
build/toolchain/build/goose build --cc clang -o build/cable-backpressure repro/cable_backpressure.goose
python3 repro/check_backpressure.py build/cable-backpressure
python3 repro/check_backpressure.py build/cable-backpressure --read
python3 repro/prepare_backpressure.py
build/toolchain/build/goose build --offline --cc clang -o build/cable-backpressure-v054 build/cable_backpressure_v054.goose
python3 repro/check_backpressure.py build/cable-backpressure-v054
python3 repro/check_backpressure.py build/cable-backpressure-v054 --read
build/toolchain/build/goose build --offline --cc clang -o build/cable-backpressure-epoll build/cable_backpressure_epoll.goose
python3 repro/check_backpressure.py build/cable-backpressure-epoll
```

Each probe is limited to 32 MiB of payload, uses only loopback, and terminates its child process.
Do not run multiple probes on the same network namespace: they use port 27893.

## Cause and scope

`max_queued` is documented to pause incoming reads. A mailbox wake calls the application's handler
before that pressure check. `ws_send` appends a complete frame and returns no would-block result;
the wake can rearm itself and continue sending while the peer remains stalled. `serve_epoll` also
dispatches wakes before draining its existing output. Upgraded connections remain in raw-body mode,
which does not supply the normal HTTP response `MORE` callback as an outbound drain notification.

This is a missing push-flow-control facility, not a claim that `max_queued` promises a hard bound on
arbitrary application output. A bounded mailbox alone does not solve it: the loop drains that box
into its outbound buffers. No language/compiler change was required by the probes.

The implementation was inspected at:

- [v0.5.4 `uring.goose`](https://github.com/kaitk/goose-http/blob/e456443241af004fe5784af4d7b3597a54422a62/uring.goose)
- [v0.5.4 `http.goose`](https://github.com/kaitk/goose-http/blob/e456443241af004fe5784af4d7b3597a54422a62/http.goose)
- [v0.5.4 WebSocket API](https://github.com/kaitk/goose-http/blob/e456443241af004fe5784af4d7b3597a54422a62/websocket.goose)

## Options

1. Add bounded push admission and an outbound-drain notification to goose-http, with coverage for
   both loops and slow readers. An application needs an atomic accept/would-block operation for a
   frame (or a streaming equivalent), plus a wake once capacity returns. Campfire can then bound
   per-subscriber pending data and slow posting when delivery queues fill. This is the recommended
   foundation for comparing equivalent delivery guarantees with current Jai.
2. Carry that API as a small, pinned package patch in this repository while preparing an upstream
   contribution. It removes the release dependency but makes us responsible for maintaining and
   testing the patch until the package incorporates it.
3. Disconnect clients that exceed a backlog budget and require reconnect/reload. This can bound
   memory once pending bytes are observable, but weakens delivery guarantees. It cannot support
   a claim that every subscribed client received every message in the same workload as Jai.

Switching to v0.5.4 or to the epoll loop alone does not resolve the reproduced issue. A separate
native WebSocket server could provide the missing flow control, but expands the non-Goose part of
the application and is more work than repairing this specific package API.

## Earlier application validation

The final production image passed all 27 differential rendering cases and all 315 asset
hash/MIME checks against each pinned reference, Rust and Jai e56ba63. Its fresh-storage container
smoke test also passed, including HTTP_PORT, schema creation, first-run setup and room rendering. The first-run implementation additionally passes fresh-schema
creation, concurrent administrator setup, signed sessions, bcrypt login, invitation membership,
invalid-origin rejection and duplicate-user rollback. Existing integration tests pass with response
caching both enabled and disabled. At that checkpoint, browser parity and current Rust/Jai
benchmarking were pending. The [current report](send-copy.md) records those completed checks;
historical results against Jai e56ba63 do not establish a lead over 2ecd487.
