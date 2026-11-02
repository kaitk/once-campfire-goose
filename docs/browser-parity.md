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
reader is enrolled afresh. It also checks the 17th subscription's `reject_subscription`, typing
relay and its rate limit, unread notices for members only (including rooms granted after the
subscription), read notices, and revocation: a closed-room membership revision, sign-out, a
session deleted out of band, deactivation and a ban each close the affected connections with
Action Cable's `disconnect` message, refused reconnections, and a revoked stalled reader
releasing the publication window it held.
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
ready reader with a local wake that takes no mailbox slot. Each reader writes at most one 256 KiB
batch (`CAMPFIRE_CABLE_BATCH`) of whole frames per goose-http drain credit, from the shared body, and completes its
publications in order; only a larger message is fragmented. An unsubscribe cancels unsent
deliveries; an already-started WebSocket message finishes before its identifier can be reused.
Client commands received between fragments wait in a bounded 64 KiB buffer.
Each connection keeps at most 16 subscriptions. A worker credits the broker once all its
enrolled readers drained a publication or left. A worker without connections is credited
at once and skipped; when it has connections again, it is enrolled in later publications. Disconnected readers, including those that end
with a WebSocket Close, are removed, and each worker checks its readers' addresses in turn.
By default a message POST is acknowledged once its transaction commits and the broker has
retained the publication and snapshotted its subscribers. With `CAMPFIRE_PUBLICATION_ACK=drained`
it is acknowledged only after every enrolled subscriber's batches have reached their socket, or
the subscriber disconnects. Socket acceptance does not prove that a browser has processed the message.

A stalled subscriber holds retirement of its publication and all later acknowledgements.
Other readers can advance within the eight-publication window; the broker admits another
publication to the window only after the oldest one completes and its acknowledgement is
accepted or its HTTP recipient disconnects. The 64 admission permits cover queued and active
publications together. Encoded body storage is reused after retirement, and connection
metadata holds eight subscription masks rather than a growing per-reader queue.
The HTTP wait expires after 60 seconds, but the committed message remains in the database.
Admission exhaustion returns 503 before a new write starts. This trades availability for
bounded outstanding delivery and avoids silently dropping accepted messages.

## Live notices and revocation

These follow Rails' channels and callbacks:

- **UnreadRoomsChannel** (`user_<id>_unreads`): each created message (browser or bot) carries
  `{"roomId":…,"at":…}`, `at` being its creation time in seconds. It rides in the message's
  own publication, after the message in the same shared body, so it takes no extra permit,
  window slot or broker work, and coalesces into the same batch as the message frame. Each
  worker keeps the room ids of each user with an UnreadRoomsChannel subscription there, loaded
  when the subscription is made and kept current by the access log below; enrollment looks
  the room up once per such connection. Rails sends it to members who are unread or connected
  after the post; this sends it to every member. The difference is invisible to the client
  (an invisible room is not in the sidebar, and every other disconnected member was just
  marked unread) and no non-member hears of the room.
- **ReadRoomsChannel** (`user_<id>_reads`): subscribing to a room's PresenceChannel, or its
  `present` action, sends `{"room_id":…,"at":…}` to the user's other tabs.
- **TypingNotificationsChannel**: `start` and `stop` performed on a subscription the connection
  holds are broadcast to the room's subscribers, the typist included as in Rails, as
  `{"action":…,"user":{"id":…,"name":…}}`. The name is read when the event is sent rather
  than when the connection opened.

Typing and read notices are transient events. They go through a separate queue of 256 to the
broker, which shares each body once and mails each worker with connections a reference, but
only while that worker's mailbox holds fewer than 32 messages; a worker keeps the last 64 in a
ring and writes them whole, between messages, at a connection's next batch. They never take a
publication permit or window slot, never hold back retirement, and a full queue, a busy
mailbox or a connection 64 events behind drops them instead of waiting. A connection may send
five typing events at once and one per 200 ms after; the rest are dropped. So typing spam
can cost CPU but cannot make posts wait or return 503, which a shared window would have
allowed; the price is that a stalled or flooded tab may miss a typing or read notice, which
the client's five-second typing timeout and the next page load repair. Rails delivers these
without loss.

Access changes go through a log of 4,096 entries in `platform.c`, recorded under writer
admission once their transaction commits, so in commit order, and announced to the workers
through the broker. A worker applies new entries before it enrolls any publication (one
atomic load when nothing changed), before a subscription, on its keepalive timer and when
nudged. A revocation applies to the user's connections authenticated before it: their
deliveries are cancelled and credited at once, so a stalled revoked reader stops holding the
window, and each connection sends Action Cable's `disconnect` and closes. As in Rails, a
removed membership and a sign-out reset all of the user's connections
(`"reason":"remote","reconnect":true`); deactivation and a ban close them for good
(`"reconnect":false`). A reconnecting client subscribes afresh, which checks the session and
memberships again, and a connection without a valid session now receives
`{"type":"disconnect","reason":"unauthorized","reconnect":false}` instead of a 403, so the
client stops retrying. Like Rails' `check_session`, an open connection looks its session up
again each minute (`CAMPFIRE_CABLE_SESSION_CHECK_MS`), on its keepalive timer or after a
drained batch, never per delivery, which catches sessions removed outside these routes.
Rooms granted (open and direct room creation, closed-room revisions, reopening a closed room)
are logged too, so unread notices cover them without a query. A worker that falls a whole log
behind resets all its connections.

Routes added for this: `DELETE /session` (sign-out, also as `_method=delete`) and
`PATCH /rooms/closeds/:id` with its edit form, which converts a room to a closed one and
revises its members (`user_ids[]`), as `Rooms::ClosedsController#update`. Closing a room does
not broadcast the per-member sidebar replacement; revoked members' sidebars reload when they
reconnect.

## Account administration, PWA and push subscriptions

`test_admin.py` runs against a fresh schema. It covers role changes and deactivation
(`/account/users`), bans (`/users/:id/ban`), join-code regeneration, the account logo
(`/account/logo` and multipart `account[logo]` uploads), `/webmanifest` and
`/service-worker`, and push subscription storage (`/users/me/push_subscriptions`). Each
route is tested for success, for members and other users where only administrators or the
owner may act, for cross-site writes and for signed-out requests. Statuses, redirects and
side effects follow the Rails reference at `90b33002`: a deactivation removes sessions,
searches, push subscriptions and shared-room memberships and renames the email address; a
ban records the user's public session addresses, signs them out and removes their messages,
boosts, rich text, search rows and attachments, and is refused with 422 for a private or
invalid address. The manifest, service worker and account-users turbo stream match the Rust
reference byte for byte apart from host-dependent URLs and cache headers.

These differ from Rails. A ban removes messages in its own transaction rather than in a
job, and publishes the removals once: to the room's stream when they are all in one room,
otherwise to the stream every signed-in page follows, up to 64 KiB of removals. Logo uploads
are stored as Active Storage blobs with MD5 checksums, but without an image processor no
variants are made: `/account/logo` serves a Rails-made 512 or 192 PNG variant if one exists,
otherwise a PNG, JPEG, GIF or WebP original as uploaded, and the stock icon for other files.
Uploads share the 1 MiB request-body limit. Push endpoints must be HTTPS on port 443 at a
permitted push service, but their host is not resolved; the sender must check addresses
when it delivers. Test notifications are acknowledged with Rails' redirect but not sent.
The subscription list names browsers with a small user-agent parser rather than the
`useragent` gem. Redirects use relative locations.

## Remaining compatibility work

The experimental server is not a complete Campfire replacement. Upload creation, boost
mutation, sending web push notifications and webhook delivery remain unimplemented.
Closed rooms cannot yet be created, and room deletion is not implemented. Sessions do not record IP addresses or
user agents, so a ban of a user who only signed in here bans no addresses, and banned
addresses are not yet refused writes (429). Logo variants are not generated. Room creation restrictions, full profile editing and reverse-proxy
HTTPS handling need broader coverage. Refresh currently returns at most 1,000 changed
messages.

The HTTP throughput samples have no connected WebSocket subscribers. The separate shared
fan-out workload measures complete delivery to 64 tabs with six subscriptions each and
audits persisted message, rich-text and FTS bodies; its tabs subscribe to UnreadRoomsChannel,
so each now also receives an unread notice per message, as from Rails and Jai. Neither workload
measures the missing effects above or establishes full application equivalence or an
intrinsic language-speed advantage.
