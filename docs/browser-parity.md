# Browser coverage and live delivery

The production-image browser gate uses the unchanged `browser/smoke.mjs` and npm lockfile
from `basecamp/once-campfire-verification` revision
`ec02debb3e44f40b8778a6a42db3c4515b2f9eaf`. Playwright's image is pinned by digest
in `test_browser.py`. The runner creates fresh Linux storage, starts the production
image, runs Chromium, and writes a receipt with image IDs and validator hashes.

```sh
python3 test_browser.py once-campfire-goose:app
# An existing clean verifier checkout can avoid fetching it again:
python3 test_browser.py once-campfire-goose:app --verification /path/to/once-campfire-verification
```

The shared suite exercises first-run setup, two-tab live messaging, duplicate suppression,
stored-markup safety, permalink copying, editing, search, profile/account updates, QR codes,
live room creation and renaming, bots, custom styles, session transfer, invitations, and
autocomplete-created direct pings with draft preservation. This establishes functional
coverage of those flows. Administrative forms use simpler markup than Rust/Jai; it is not
a screenshot-equivalence claim. The existing 27-case differential suite separately checks
room, paging, sidebar, search and POST rendering against the reference servers, including
all 315 served asset hashes and MIME types.

`test_cable.py` checks signed-stream rejection, two-reader delivery, 200 KiB fragmented
messages with concurrent incoming commands, multiple subscriptions per connection,
duplicate subscriptions, unsubscribe/slot reuse, publication ordering, and presence cleanup.
A stalled-reader case fills all 64 publication permits, checks that committed writes remain
unacknowledged, rejects 100 additional writes without database changes or retained-memory
growth above a 16 MiB allowance, and verifies complete recovery after disconnect. Two fast
readers advance through exactly eight active publications while the slow reader is stalled.
They receive the same ordered sequence across window reuse; a late subscriber receives
only publications enrolled after it joins. Readers spread over the HTTP workers receive the
same ordered publications while each worker's first connection stalls and then
disconnects, and while others leave by WebSocket Close; once every worker is empty, a new
reader is enrolled afresh.
First-run and HTTP regression tests continue to check authorization,
atomic persistence, write rollback, cache invalidation, and concurrent posting.

## Delivery contract

Each admitted mutating HTTP request reserves one of 64 publication permits before writing.
An asynchronous broker orders publications and pipelines at most eight. It retains one
encoded body per active publication and mails each HTTP worker that has a cable connection
one reference to it, at that worker's own goose-http mail address, so its
work per publication grows with the number of workers, not readers. Each worker owns its
connections' subscriptions and delivery state. It snapshots its matching subscriptions when
a publication reaches it, so subscriptions added later do not inherit it, and wakes each
ready reader with a local wake that takes no mailbox slot. Each reader writes at most one 32 KiB
batch of whole frames per goose-http drain credit, from the shared body, and completes its
publications in order; only a larger message is fragmented. An unsubscribe cancels unsent
deliveries; an already-started WebSocket message finishes before its identifier can be reused.
Client commands received between fragments wait in a bounded 64 KiB buffer.
Each connection keeps at most 16 subscriptions. A worker credits the broker once all its
enrolled readers drained a publication or left. A worker without connections is credited
at once and skipped; when it has connections again, it is enrolled in later publications. Disconnected readers, including those that end
with a WebSocket Close, are removed, and each worker checks its readers' addresses in turn.
A message POST is acknowledged only after its transaction
commits and every enrolled subscriber's batches have reached their socket, or the subscriber
disconnects. Socket acceptance does not prove that a browser has processed the message.

A stalled subscriber holds retirement of its publication and all later acknowledgements.
Other readers can advance within the eight-publication window; the broker admits another
publication to the window only after the oldest one completes and its acknowledgement is
accepted or its HTTP recipient disconnects. The 64 admission permits cover queued and active
publications together. Encoded body storage is reused after retirement, and connection
metadata holds eight subscription masks rather than a growing per-reader queue.
The HTTP wait expires after 60 seconds, but the committed message remains in the database.
Admission exhaustion returns 503 before a new write starts. This trades availability for
bounded outstanding delivery and avoids silently dropping accepted messages.

## Remaining compatibility work

The experimental server is not a complete Campfire replacement. Upload creation, push
notifications and webhook delivery remain unimplemented. Read/unread and
typing notification channels are accepted but do not yet deliver their full events. Active
WebSocket subscriptions do not yet recheck session or membership revocation; HTTP requests
and initial subscriptions do check access. The broker supports 16 subscriptions per socket;
the protocol needs an explicit rejection response when that limit is exceeded. Full profile
editing, opening a closed room (`/rooms/opens/:id` keeps the room's type), user bans,
reverse-proxy HTTPS handling, and the remaining admin flows need broader coverage. Refresh
currently returns at most 1,000 changed messages.

These routes follow Rails' controllers, and their statuses, redirects, turbo streams and
markup match the pinned Rust reference on a fresh account (`test_routes.py` covers them):

- Boosts at `/messages/:id/boosts`: index, new, create (302 to the index) and the booster's
  own destroy (204), with append/remove streams to the room. Boosts touch their message and room.
- The bot API at `/rooms/:room_id/:bot_key/messages`, with Rails' `id-token` keys: index with
  Rails' JSON, `X-Total-Count` and `Link` paging, create, and update/destroy of the bot's own
  messages; boost create (201 JSON) and destroy. An unknown key falls back to session
  authentication, as in Rails.
- `/rooms/:id/involvement` (the bell's frame and update); invisibility removes the room from,
  and leaving it re-adds the room to, the user's own sidebar stream.
- `DELETE /rooms/:id` for the room's creator or an administrator, removing it from every
  sidebar; `/rooms/closeds` new, create, show, edit and update, honoring the account's room
  creation restriction and broadcasting to the members' own streams.
- `/users/:id` and `DELETE /searches/clear`.

Known differences: an involvement outside the enum answers 422 where Rails raises (500).
`/rooms/:id/settings` answers 500, as both references do: Rails routes it to a controller that
does not exist. A deleted room's messages, memberships and attachment records are removed in
the request's transaction instead of Rails' background job, and blobs are not purged. Bot
bodies are stored as escaped text, as bot posts already were. The user page's transfer link
uses this server's own transfer URL and QR route, and its ban button posts to a route that is
not implemented yet. A closed room broadcast reaches each member's own rooms stream as one
publication, which every worker matches against the room's committed memberships.

The HTTP throughput samples have no connected WebSocket subscribers. The separate shared
fan-out workload measures complete delivery to 64 tabs with six subscriptions each and
audits persisted message, rich-text and FTS bodies. Neither workload measures the missing
effects above or establishes full application equivalence or an intrinsic language-speed
advantage.
