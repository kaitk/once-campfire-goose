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
Rooms granted (open, direct and closed room creation, closed-room revisions, reopening a closed room)
are logged too, so unread notices cover them without a query. A worker that falls a whole log
behind resets all its connections.

`DELETE /session` (sign-out, also as `_method=delete`) was added for this, as
`SessionsController#destroy`. Closed-room creation and revision, open and direct
room creation, reopening a closed room, deactivation and bans all log their grants and
revocations from the routes' own transactions. Deleting a room does not reset its former
members' connections, which Rails' `Room::DestroyJob` does after the sidebar removal: here the
room and its messages go in one transaction, nothing can publish to its id again (ids are not
reused), and resetting first would cut off the members' removal broadcast.

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
and their 512 and 192 PNG variants are described under
[uploads](#uploads-and-active-storage). Push endpoints must be HTTPS on port 443 at a
permitted push service; their host is resolved and checked only when a notification is
delivered (see [Web Push](#web-push)), where Rails also resolves it when the subscription is
saved. Test notifications are sent by the delivery threads after Rails' redirect.
The subscription list names browsers with a small user-agent parser rather than the
`useragent` gem. Redirects use relative locations.

## Bot webhooks

As `MessagesController#deliver_webhooks_to_bots` does, a posted message, including one a bot
posts by its key, goes to the webhook of each active bot of a direct room, or of each mentioned
active bot of the room, but never to its creator. Mention attachments are kept, minified to
their `sgid` and content type as Action Text stores them; only SGIDs signed with the
`signed_global_ids` key name a user, and the search index stores each mention as `@Name`.
The room's mentions prompt (`/autocompletable/users?room_id=`) returns `<lexxy-prompt-item>`
elements with Rails' attachable SGIDs, bots included.

After the message commits, the HTTP worker only puts one job per bot on a bounded
4,096-entry queue, which Web Push shares; when the queue is full the job is dropped and
logged, and the message stands. `CAMPFIRE_DELIVERY_THREADS` delivery threads (default 4;
`CAMPFIRE_WEBHOOK_THREADS` is its earlier name), each restarted if it aborts, POST `Webhook#payload` with `Content-Type: application/json` and ActiveSupport's JSON
escaping, using goose-http's blocking client with a 7-second limit on the connect and on
each wait for the response. The payload's plain text is `plain_text_body`: the rich text, or a
file's name for a message that is only an attachment. A 200 answer of `text/html` or
`text/plain` becomes the bot's message, which takes a publication permit, commits and is
published like any other. Any other answer with a media type, whatever its status, is an
attachment reply, as `extract_attachment_from` makes one: a blob named
`attachment.<symbol>` from Rails' `Mime::LOOKUP` (`attachment.` for an unregistered type),
identified by Marcel as an upload is, attached to the bot's message, analyzed, thumbnailed on a
media thread and published. So a 500 page of `text/html` posts `attachment.html`, as in Rails.
An invalid media type (`Mime::Type::InvalidMimeType`) is logged without a reply. A connect
or read timeout posts "Failed to respond within 7 seconds", as Rails does. Other failures,
including a refused connection such as the benchmark seed's `http://127.0.0.1:9/hook/<id>`,
are logged without a reply. The bot API also accepts Rails' `<id>-<token>` bot keys, which
the bot list and the payload's room path now use; bare 64-digit tokens still work.

These differ from Rails. An empty text answer posts nothing, where Rails would post an empty
message. Answers over 100 MiB, the default upload limit, fail the delivery. A host name's
DNS lookup is not bounded by the timeout, and an endpoint that keeps trickling bytes within
each 7-second wait is not cut off by an overall deadline (the Rust and Jai ports stop after
60 seconds). Requests carry goose-http's `User-Agent` and `Accept: */*` rather than Ruby's,
and no `Accept-Encoding`. Jobs are in memory: those queued or in flight at shutdown are lost,
where Solid Queue would keep them. `test_webhooks.py` checks the forms, both bot keys, the
prompt's SGIDs, the exact payload (an uploaded file's included), stored and live replies in an
open and a direct room, attachment replies' names, types, files and thumbnails, and that slow,
failing, refused, attachment and empty answers never delay a POST.

## Uploads and Active Storage

Files are stored as Rails' Active Storage stores them for Campfire: blob rows with 28-character
base36 keys, MD5 checksums and the `local` disk service's layout under `STORAGE_PATH`
(`<key[0..2]>/<key[2..4]>/<key>`), attachment rows, and tracked variants
(`active_storage_variant_records`, with the variant's own blob attached as `image`). Content types
are identified with Marcel 1.1.0's tables (`data/marcel.txt`, from the Rust reference's dump of
the reference bundle) from the bytes, the declared type and the filename, as `Blob#unfurl`
does. Images are analyzed with libvips as `ImageAnalyzer::Vips` does (dimensions, swapped for
EXIF orientations that turn a quarter), and variants are made as image_processing 1.14 makes
them (`autorot`, `thumbnail_image` with `size: :down`, the sharpening convolution, the saver for
the format). Variation digests are `Marshal.dump` digests with Ruby's Symbol/String distinction,
and `default_variant_format` takes a web image's own extension, so the thumbnail of `photo.JPG`
is `{format: "JPG", resize_to_limit: [1200, 800]}`, as in Rails.

- `POST /rooms/:id/messages` with `message[attachment]` (multipart, as the composer's
  FileUploader posts it) creates the message, blob and attachment in one transaction, renders
  `messages/_attachment`'s markup (dimensions from the analysis) and broadcasts it like any
  message. The search index gets the filename, and no rich text is stored, as in Rails. A bot's
  `curl -F attachment=@file` to its `/rooms/:id/:bot_key/messages` URL does the same.
- The profile form's `user[avatar]` (multipart `PATCH /users/me/profile`) replaces the avatar,
  purging the old one, and `DELETE /users/:id/avatar` destroys the current user's. The avatar
  route serves the `:square` variant (512 px WebP); an avatar Rails can't vary gets the initials.
- The account form's `account[logo]` stores the logo; `/account/logo` serves its `:large` (512)
  and `:small` (192) PNG variants, and the stock icon for a logo libvips can't vary.
- `/rails/active_storage/blobs/redirect/...` and `/representations/redirect/...` (and their
  aliases) redirect to signed `/rails/active_storage/disk/...` URLs that expire in five minutes;
  the disk route streams the file with `sendfile`, ranges, conditional requests, the signed
  content type and disposition, and `Cache-Control: max-age=3600, public`. Content types Rails
  serves as binary, or doesn't allow inline, are downloads.
- Deleting a message (in the browser or through the bot API) purges its attachment, variants
  and files; a ban's removed messages do too.

Variants are made by media threads (`CAMPFIRE_MEDIA_THREADS`, default 2), never on an HTTP
worker: right after an upload, and when a representation, avatar or logo is requested before
its variant exists, in which case the request waits (`http::later`) while its worker serves
others, and the media thread mails it the answer. libvips runs one thread per job and keeps no
operation cache. Uploads may be up to `CAMPFIRE_UPLOAD_MAX_BYTES` (default 100 MiB, 1 MiB to
1 GiB) on the four upload forms only; every other body keeps the 1 MiB limit, past which both
answer 413. Bodies are gathered in memory, so each worker's gather budget is twice the upload
limit plus 16 MiB.

`test_uploads.py` covers the rows, markup, broadcast, variant sizes, disk serving,
authorization, the size limits, purging, avatars and the logo. `compare_uploads.py` posts the
same files with the same secret to the Rails reference image and to this server and compares
the turbo streams as `compare_rendering.py` compares pages, the blob, attachment, variant record
and search rows, and the variants' types and sizes. All of them match Rails (the
`once-campfire-verification` reference image at 90b33002): signed blob and variation keys, the
`JPG` thumbnail's String digest, Marcel's content types, EXIF-turned dimensions, the 1200x500,
512x410 WebP, 512x341 and 192x128 PNG variants. The one difference it masks predates uploads: the
copy-link button's value attribute, from the vendored templates' revision.

Known differences from Rails:

- Rails makes a message's thumbnail inside `MessagesController#create`, before it answers; here
  a media thread makes it just after, and a thumbnail requested first waits for it. Rails makes
  avatar and logo variants on first request only; here they are also made after the upload.
  Uploaded images are analyzed in the request (a header read) rather than by `AnalyzeJob`, so
  their rows hold the analyzed metadata from the start.
- Videos: Rails analyzes them with ffprobe and draws posters with ffmpeg. Neither is in this
  image (ffmpeg would double its size), so a video is stored and rendered with Rails' `<video>`
  markup, and plays from its blob URL, but its metadata has no dimensions or duration, and its
  poster representation answers 500, as Rails does without a previewer. Audio is likewise not
  analyzed. Building a minimal ffmpeg as the Jai port does is the remaining work.
- Variant bytes differ from Rails' where libvips' build or its codec libraries do (this image
  builds libvips 8.16.1, the Rails image's version, against Ubuntu 24.04's libraries); sizes,
  formats and rows match.
- A logo or avatar whose variant libvips can't make (a corrupt image) gets the stock icon or
  the initials; Rails raises. A representation that can't be made answers 500, as in Rails.
- The proxy routes (`/blobs/proxy`, `/representations/proxy`), which Campfire never links,
  redirect like the redirect routes instead of streaming. Direct uploads
  (`POST /rails/active_storage/direct_uploads` and the disk `PUT`) are not served: Campfire
  doesn't use them, and its initializer only restricts them.
- Filenames longer than 1 KiB are refused (500). Content-Disposition's ASCII fallback
  transliterates Latin-1 letters only, other characters becoming `?`.
- Deleting a room purges its messages' attachments and rich-text embeds, with their variants,
  in the room's transaction, and deletes their files after it commits; Rails purges them later,
  in `purge_later` jobs.

## Web Push

With `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY` set (URL-safe Base64, as `WebPush.generate_key`
writes them, and checked to be one P-256 key pair at startup, which logs `Web Push: on` or why
it is off), every new message is pushed as `Room::MessagePusher` does at `90b33002`: browser
posts, bot API posts and webhook replies alike. After the commit, `create_message` puts one job
on the delivery queue, whatever the room's size. A delivery thread then finds the subscriptions
of the room's members other than the author whose membership is visible and disconnected
(`connected_at` missing or over 60 seconds old, as cable presence keeps it), involved in
everything, then involved in mentions and mentioned in the message, each in id order. The
payload is Rails' `JSON.generate` of `{title, options: {body, icon: "/account/logo", data:
{path: "/rooms/:id", badge}}}`: a shared room's name and "Creator: plain text", or in a
direct room the creator's name and the plain text, which for a file alone is its name as
`Filename#to_s` sanitizes it; the badge is the subscriber's count of
unread memberships. Each notification is then its own job, as each is a pool task in Rails.
`POST /users/me/push_subscriptions/:id/test_notifications` queues "Campfire Test" with a
random UUID and the subscriptions page's URL for the user's own subscription (404 otherwise)
and redirects.

A delivery does what `WebPush::Notification#deliver` and the web-push 3.1.0 gem do, in C over
OpenSSL's libcrypto (`push_crypto.c`). The endpoint must be an `https` URL on port 443 at a
permitted push service; its host is resolved and the first address that
`RestrictedHTTP::PrivateNetworkGuard` (the surfguard gem's default policy, transcribed: private,
loopback, link-local, shared, documentation, benchmarking, multicast and reserved IPv4; IPv6
loopback, unique-local, link-local, IPv4-mapped and compatible, NAT64 by its embedded IPv4,
and anything outside IANA's allocated unicast) admits, IPv4 first, is the one connected to,
while TLS still checks the host. Otherwise nothing is sent, as Rails sends nothing. The body is
RFC 8291 `aes128gcm`: an ephemeral P-256 ECDH with the subscription's `p256dh`, HKDF with its
auth secret, one AES-128-GCM record padded with the delimiter only, and the gem's record size
(the record's own length); a record over 4,096 bytes is not sent ("encrypted payload is too
big"). `Authorization: vapid t=<JWT>,k=<public key>` carries an ES256 JWT with `aud` the
endpoint's scheme and host, `exp` twelve hours ahead and `sub` `mailto:support@37signals.com`;
`Ttl: 2419200`, `Urgency: high`, `Content-Encoding: aes128gcm` and `Content-Type:
application/octet-stream` are the gem's. A 2xx is success; 410 and 404 destroy the
subscription ("Destroying push subscription: <id>" is logged), as does a `p256dh` that is no
P-256 point; other answers and connection failures are logged with the gem's error names.

These differ from Rails. Rails destroys a subscription on 410 and on any `OpenSSL::OpenSSLError`,
TLS failures included, but not on 404 (`WebPush::InvalidSubscription`); here 404 destroys it, as
the Jai port does and RFC 8030 means it, and TLS failures are only logged. Rails resolves the
endpoint when a subscription is saved too, which would block an HTTP worker here; the guard
runs at delivery. Rails sends test notifications inline and answers 500 when the push service
refuses them; here they are queued, their failures are logged, and a 404 or 410 destroys the
subscription like any delivery's. Each wait (connect, send, read) is limited to 10 seconds
where Net::HTTP allows 60; DNS lookups are not bounded. FCM's 400 "UnauthorizedRegistration"
is logged as `WebPush::ResponseError` rather than `Unauthorized`, since goose-http's client
keeps no reason phrase. A refused subscription is logged (each delivery thread logs one again
after 64 others), where Rails skips it in silence. Jobs are in memory, as Rails' pool is, but the
message's own job is too, where Solid Queue keeps `Room::PushMessageJob`. As in Rails, each
delivery opens its own connection.

All four push services accept HTTP/1.1, which goose-http's blocking client speaks: the gem itself
posts with Net::HTTP, which has no HTTP/2, and on 2026-11-02 `fcm.googleapis.com`,
`updates.push.services.mozilla.com`, `web.push.apple.com` and `*.notify.windows.com` each
answered a TLS 1.3, ALPN `http/1.1` POST with an HTTP/1.1 status and their own error (Apple's
`{"reason":"BadAuthorizationHeader"}` with an `apns-id`). goose-tls's client offers TLS 1.3
only, which all four accept. Nothing needs HTTP/2 today; should a service require it, goose-http
has an HTTP/2 server (frames, HPACK, flow control) but no client, so it would take a client
connection preface and SETTINGS exchange, an HPACK encoder, one stream per request with flow
control, and ALPN `h2` in goose-tls's client context, or connection reuse across deliveries
to make it worthwhile.

The benchmark seed's subscriptions point at `https://127.0.0.1:9/push/<id>`, which is not a
permitted push service, so they are refused before the message is even read and nothing is
connected to. In its write room each post still costs one query on a delivery thread (three
subscriptions of members involved in everything). In this arm64 Mac's Docker VM, with the server
on four cores and `ab` posting 40,000 messages from 32 keep-alive clients in that shape (four
rotated rounds, medians; round-to-round noise is about 5%): 8,070 posts/s with push on, 8,061
for main at `cf1dd5e` and 8,463 with push off, and
208.5 µs of server CPU per post against 189.5 µs for main and 179.2 µs with push off. The
~20 µs is that query on a delivery thread, which Rails and the Jai port also do per message
(a thread that only wakes and returns costs nothing measurable); TLS clients are made only for
a first delivery. `test_push.py` checks who is notified for each involvement and for presence,
the bot API, direct rooms, the decrypted payload against Rails' JSON and the VAPID signature
with its own RFC 8291 and ES256 code, refusals, 404/410/500 answers and invalid keys, test
notifications and that slow push services never delay a POST; `push_crypto_test.c` checks
RFC 8291's example, ES256 and the address policy. The test's push service listens on a Unix
socket, reached through two TEST ONLY settings that are off unless set:
`CAMPFIRE_PUSH_TEST_RESOLVE` (`name=address,…`, answered instead of DNS, still judged by the
guard) and `CAMPFIRE_PUSH_TEST_CONNECT` (where to connect once the guard admits an address);
the server logs a `TEST ONLY` line when either is set.

## Remaining compatibility work

The experimental server is not a complete Campfire replacement. Video attachments get no
analysis or poster (see
[uploads](#uploads-and-active-storage)). Sessions do not
record IP addresses or user agents, so a ban of a user who only signed in here bans no
addresses, and banned addresses are not yet refused writes (429). Full profile editing and
reverse-proxy HTTPS handling need broader coverage.
Refresh currently returns at most 1,000 changed messages.

These routes follow Rails' controllers, and their statuses, redirects, turbo streams and
markup match the pinned Rust reference on a fresh account (`test_routes.py` covers them):

- Boosts at `/messages/:id/boosts`: index, new, create (302 to the index) and the booster's
  own destroy (204), with append/remove streams to the room. Boosts touch their message and room.
- The bot API at `/rooms/:room_id/:bot_key/messages`, with Rails' `id-token` keys (bare
  64-character tokens still work): index with Rails' JSON, `X-Total-Count` and `Link` paging,
  create, and update/destroy of the bot's own messages; boost create (201 JSON) and destroy.
  Bot posts go through the browser's `create_message`, so they reach other bots' webhooks. An
  unknown key falls back to session authentication, as in Rails.
- `/rooms/:id/involvement` (the bell's frame and update); invisibility removes the room from,
  and leaving it re-adds the room to, the user's own sidebar stream.
- `DELETE /rooms/:id` for the room's creator or an administrator, removing it from every
  sidebar; `/rooms/closeds` new, create,
  show, edit and update, honoring the account's room creation restriction and broadcasting
  to the members' own streams. Members a revision removes have their connections reset;
  members it adds receive the room's unread notices at once.
- Saving a closed room at `/rooms/opens/:id` opens it again and grants it to every active user.
- `/users/:id` and `DELETE /searches/clear`.

Known differences: an involvement outside the enum answers 422 where Rails raises (500).
`/rooms/:id/settings` answers 500, as both references do: Rails routes it to a controller that
does not exist. A deleted room's messages, memberships and attachment records are removed in
the request's transaction instead of Rails' background job, and blobs are not purged. Bot
bodies are stored as escaped text, as bot posts already were. The user page's transfer link
uses this server's own transfer URL and QR route; its ban button posts to `/users/:id/ban`. A
closed room broadcast reaches each member's own rooms stream as one publication, which every
worker matches against the room's committed memberships when it receives it; a member that
revision removed is no longer in them, and its connections are reset in any case.

The HTTP throughput samples have no connected WebSocket subscribers. The separate shared
fan-out workload measures complete delivery to 64 tabs with six subscriptions each and
audits persisted message, rich-text and FTS bodies; its tabs subscribe to UnreadRoomsChannel,
so each now also receives an unread notice per message, as from Rails and Jai. Neither workload
measures the missing effects above or establishes full application equivalence or an
intrinsic language-speed advantage.
