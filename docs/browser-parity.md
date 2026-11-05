# Rails parity, browser coverage and live delivery

The port follows Campfire's Rails code at `a05ee908` (Rails main of November 2, 2026): its routes,
statuses, redirects, flashes, turbo streams, broadcasts, markup (compared as parsed HTML) and
headers. An audit walked every route in Rails' `config/routes.rb` with each controller's
before_actions; each area was then checked against the Rails reference image
(`once-campfire-verification:reference-a05ee90`) by a script that drives both servers through the
same steps and compares what they answer.

Until November 4 the target was `90b33002`, the revision the shared harness
(`basecamp/once-campfire-verification`) names. The harness uses it only to build its seed
database: the Rails it measures is a later one (`0aa339d`), and its browser smoke checks fixes
Rails made after `90b3300`, such as the closed form on the session-transfer page (`27f5461`).
Following Rails main matches what the harness runs and takes in Rails' security fixes since. A
`90b3300` database, the harness's seed included, is migrated at boot as Rails' `db:prepare`
migrates it ([database schema](#database-schema)).

**Where it differs from Rails.** The compared responses are counted in the table below. The
differences that remain are listed [at the end](#deliberate-differences), all deliberate but
one. The session cookie is signed again hourly rather than on every request; jobs run on
in-process threads, and queued work is lost at shutdown; a room's deletion and a ban's message
removal run on a cleanup thread in batches, with batched removal broadcasts; ffprobe has a time
limit; typing and read notices can be dropped, and unread notices go to every member; Web Push
opens a connection per delivery; the built-in TLS is narrower than Thruster's; ETags don't
depend on the response's encoding; a page rendered for a Turbo frame has no `csrf-param` and
`csrf-token` meta tags, which turbo-rails' frame layout still writes; and a rich-text attachment
naming a forged SGID renders without it, where Rails answers 500. The one not yet done: a file embedded in a message's rich
text doesn't reach the search index's text or a bot's webhook payload.

| Area | Comparison | Matches |
|---|---|---:|
| Sign-in, first run, join, transfers, sign-out, browser checks, version headers | `compare_ui_auth.py` | 37 of 37 |
| Rooms, Pings, room settings, room deletion and autocomplete | `compare_ui_rooms.py` | 73 of 73 |
| Messages: edit, delete, edit broadcasts, bot HTML, text linking, files in rich text, link previews | `compare_ui_messages.py` | 46 of 46 |
| Search, permalinks, room navigation and paging | `compare_ui_search.py` | 48 of 51 (the frame layout's token tags) |
| Profile and password changes, account settings, custom styles, bots, QR codes, push subscriptions | `compare_ui_account.py` | 109 of 109 |
| Uploads: images, video and audio, variants, previews, oversized and undecodable images | `compare_uploads.py` | all |
| Built-in TLS: port 80, HTTPS headers and cookies, ALPN, certificates Thruster wrote | `compare_ui_tls.sh` | all |
| ETags, Cache-Control, conditional GETs, HEAD, default headers, Content-Security-Policy, Vary | `compare_ui_etag.py` | 71 of 71 |
| Error pages, `public/` files, routing before sign-in, avatar and logo headers, Active Storage proxies and direct uploads, engine routes, Content-Security-Policy, Vary | `compare_ui_public.py` | 125 of 125 |

The scripts need Docker and the Rails image, so they run by hand; the Docker test suite
(`docker build --target test`) runs everything else on every build.

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
autocomplete-created direct pings with draft preservation. Messages carry Rails main's ids
(`message_<id>` from the primary key, the client's id in `data-client-message-id`), which the
pinned smoke's duplicate suppression passes with. The existing 27-case differential suite
separately checks room, paging, sidebar, search and POST rendering against the reference
servers, including all 313 served asset hashes and MIME types.

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
subscription), read notices, and revocation: a closed-room membership revision, a room's
deletion, sign-out, a password change, a session deleted out of band, deactivation and a ban
each close the affected connections with
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
  `{"roomId":…,"at":…}`, `at` being its creation time in seconds, as Rails main's
  `broadcast_unread_room` sends it. It rides in the message's own publication, after the
  message in the same shared body, so it takes no extra permit, window slot or broker work, and
  coalesces into the same batch as the message frame. Each worker keeps the room ids of each
  user with an UnreadRoomsChannel subscription there, loaded when the subscription is made and
  kept current by the access log below; enrollment looks the room up once per such connection.
  The sidebar controller (Rails main's `rooms_list`) compares `at` with the last read notice,
  so a notice that arrives after the room was read in another tab doesn't mark it unread. Rails
  main sends the notice from a job, to the members who are unread or connected to the room;
  here it goes to every member's subscription (see
  [deliberate differences](#deliberate-differences)).
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
removed membership, a room's deletion, a sign-out and a password change reset all of the
user's connections
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
revocations from the routes' own transactions.

Deleting a room follows Rails main's `Room#destroy_later`. The request's transaction turns an
open room into a closed one, so nobody who joins the account meanwhile is let in, and deletes
its memberships; the members' sidebars then get the removal broadcast. A cleanup thread then
does what `Room::DestroyJob` does: it resets the former members' connections, logged with its
first write, and deletes the room's messages 50 per write transaction, with their files after
each, and then the room. Other writes get through between batches, where deleting a large room
in one transaction would hold the write lock throughout. The thread keeps its queue in memory:
a crash midway leaves the closed room and its remaining messages, as a lost job leaves them in
Rails.

## Account administration, PWA and push subscriptions

`test_admin.py` runs against a fresh schema. It covers role changes and deactivation
(`/account/users`), bans (`/users/:id/ban`), join-code regeneration, the account logo
(`/account/logo` and multipart `account[logo]` uploads), `/webmanifest` and
`/service-worker`, and push subscription storage (`/users/me/push_subscriptions`). Each
route is tested for success, for members and other users where only administrators or the
owner may act, for cross-site writes and for signed-out requests. Statuses, redirects and
side effects follow the Rails reference at `a05ee908`: a deactivation removes sessions,
searches, push subscriptions and shared-room memberships and renames the email address; a
ban records the user's public session addresses, signs them out and removes their messages,
boosts, rich text, search rows and attachments, and is refused with 422 for a private or
invalid address. The account page lists the administrators in full and the members 500 at a
time, banned members to administrators only, as Rails main does. A push subscription posted
for a session that a password change has ended meanwhile gets 401. The manifest and service
worker match the Rust reference byte for byte apart from host-dependent URLs and cache headers.

A ban's messages are removed once the ban commits, as Rails main's `RemoveBannedContentJob`
removes them, by the cleanup thread that finishes room deletions: 50 messages per write
transaction, with their files after each. Rails broadcasts one removal per message; here each
batch's removals go to each room's stream in one publication, targeted by primary key. A
publication that gets no permit within 60 seconds is skipped and logged; the messages are gone
either way, and a page load shows it. Logo uploads
and their 512 and 192 PNG variants are described under
[uploads](#uploads-and-active-storage). Push endpoints must be HTTPS on port 443 at a
permitted push service; their host is resolved and checked only when a notification is
delivered (see [Web Push](#web-push)), where Rails also resolves it when the subscription is
saved. Test notifications are sent by the delivery threads after Rails' redirect.
Redirects carry absolute locations, as Rails' `*_url` helpers make them.

The profile (`/users/me/profile` and `/users/:id/profile`), account settings, custom styles,
bots and push subscriptions pages render Rails' views in the application layout, with the
account's custom CSS unescaped in its `<style>`. Profile updates take Rails' parameters (name,
email address, password, bio, avatar). As in Rails main's `Users::ProfilesController`,
changing the password needs the current one (`user[password_challenge]`): without it, or with
a wrong one, nothing is saved and the profile shows Rails' alert; updates that send one are
limited to ten in three minutes per address; and a change ends every session and push
subscription of the user's, resets their connections, and signs this browser in again with a
new session. Account updates take the name, the logo and `settings` (the "Must be admin to
create new rooms" switch, cast as a Rails boolean). Bots are created with 12-character tokens,
edited with avatars and webhooks, re-keyed and deleted (`User#deactivate`). QR codes at
`/qr_code/:id` are drawn as rqrcode_core 2.1.0 draws them (`qr.goose`), byte for byte, and an
id that isn't valid Base64, or is too long for a QR code, gets an empty 400. Session transfer
links carry Rails main's `generates_token_for(:transfer)` token, which expires after four
hours and includes part of the password's salt, so changing the password ends the links made
before. Notices use the flash.

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
published like any other. Any other 200 with a media type is an attachment reply, as
`extract_attachment_from` makes one: a blob named `attachment.<symbol>` from Rails'
`Mime::LOOKUP` (`attachment.` for an unregistered type), identified by Marcel as an upload is,
attached to the bot's message, processed on a media thread as a posted file is, and published.
Any other status posts nothing, as in Rails main. An invalid media type (`Mime::Type::InvalidMimeType`) is logged without a reply. A connect
or read timeout posts "Failed to respond within 7 seconds", as Rails does. Other failures,
including a refused connection such as the benchmark seed's `http://127.0.0.1:9/hook/<id>`,
are logged without a reply. Text answers are stored as they came, as Rails stores a bot's
body, and sanitized when rendered. Bot keys are Rails' `<id>-<token>`.

These differ from Rails. Answers over 100 MiB, the default upload limit, fail the delivery. A host name's
DNS lookup is not bounded by the timeout, and an endpoint that keeps trickling bytes within
each 7-second wait is not cut off by an overall deadline (the Rust and Jai ports stop after
60 seconds). Requests carry goose-http's `User-Agent` and `Accept: */*` rather than Ruby's,
and no `Accept-Encoding`. Jobs are in memory, and those queued or in flight at shutdown are
lost, where Solid Queue keeps them and the Rust and Jai ports run the queued ones before they
stop (Rust up to a deadline). `test_webhooks.py` checks the forms, Rails' bot keys (a bare
token is refused), the prompt's SGIDs, the exact payload (an uploaded file's included), stored
and live replies in an open and a direct room, empty and HTML text replies, attachment and
video replies' names, types, files, analysis and thumbnails, that a 500 posts nothing, and that
slow, failing, refused, attachment and empty answers never delay a POST.

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

Videos and audio are analyzed with ffprobe and videos previewed with ffmpeg, as Active Storage's
`VideoAnalyzer`, `AudioAnalyzer` and `VideoPreviewer` do. The image builds ffmpeg and ffprobe
from the Debian source package the Rails image ships (7:7.1.5-0+deb13u1, pinned by its `.dsc`
checksum), configured as the Rust and Jai ports configure it: every built-in demuxer, decoder and
parser plus dav1d, but only the JPEG encoder, the `image2` muxer, the filters the preview's
command line needs and the file and pipe protocols. That adds 25 MB to the image (217 to 242 MB);
Ubuntu's own ffmpeg package would add about 400 MB.

- ffprobe runs as Rails runs it (`-print_format json -show_streams -show_format -v error` on the
  blob's file under its extension), and its JSON is read with Rails' rules: a video's `width`,
  `height` (the display height from `display_aspect_ratio`, swapped for a quarter turn by the
  `rotate` tag or the display matrix), `duration`, `angle`, `display_aspect_ratio`, `audio` and
  `video`; an audio file's `duration`, `bit_rate`, `sample_rate` and the stream's `tags`. Values go
  through Ruby's `Float()` and `Integer()` and are written as Ruby writes them (`64.0`, `0.5`,
  `[16,9]`, ActiveSupport's `\u003c` escapes), merged after `identified` and before
  `analyzed`. Without ffprobe the analysis is Rails' `{}` probe (`"audio":false,"video":false`).
  Analysis touches the records holding the blob (a message and its room, a user, the account),
  as `Blob#touch_attachments` does.
- A video is previewable while `ffmpeg -version` succeeds (asked once, at startup, which logs
  `Video previews: on` or why not); the PDF previewers never accept, as the Rails image has
  neither poppler nor mupdf. The preview image is ffmpeg's frame from Rails main's
  `video_preview_arguments`
  (`-vf select=eq(n\,0)+eq(key\,1)+gt(scene\,0.015)+gte(t\,5),... -frames:v 1 -f image2 -`,
  which takes a frame at five seconds at the latest), attached to the video's blob as
  `preview_image`: its own blob,
  `<base>.jpg`, `image/jpeg`, analyzed with libvips. A preview's variants are the preview image's
  tracked variants, its default format `jpg`; a variation with no transformations is the preview
  image itself.
- `messages/_attachment` renders a video as Rails main does: `<video>` with the blob as `src`,
  inside the dimension wrapper Rails sizes from the analyzed width and height, and as `poster`
  its `preview(:poster)` (the preview image's `{format: :webp, resize_to_limit: [1200, 800]}`
  variant) only when the preview image and that variant were both made. An image is shown
  through its `:thumb` representation only when that variant was made, and is otherwise a
  download link. Audio and videos without a previewer are download links.
- ffmpeg gets 10 seconds, Rails main's `TimeLimitedVideoPreviewer` limit, and ffprobe 30 (Rails
  sets it none; this is the Rust port's), after which they are killed and the preview or
  analysis fails. They inherit no descriptor but their pipes, and ffprobe's stderr goes to the
  server's, as in Rails.

- `POST /rooms/:id/messages` with `message[attachment]` (multipart, as the composer's
  FileUploader posts it) creates the message, blob and attachment in one transaction, renders
  `messages/_attachment`'s markup (dimensions from the analysis) and broadcasts it like any
  message. The search index gets the filename, and no rich text is stored, as in Rails. A bot's
  `curl -F attachment=@file` to its `/rooms/:id/:bot_key/messages` URL does the same, and so does
  a bot's attachment reply to a webhook. The post is answered and broadcast only once
  `Message#process_attachment` has run, as `create_with_attachment!` runs it before
  `broadcast_create`: a media thread analyzes a video or audio file (an image was analyzed in
  the request) and makes a video's preview image and its `:poster` variant, or an image's
  `:thumb` variant, so the answer and the broadcast carry the size and the preview. Images and
  videos without a width and height, or with more than 250 million pixels, get no preview
  (`too_many_pixels_to_preview?`). A preview that fails (ffmpeg can't draw a frame, libvips
  can't decode the image) is logged and the message posted without it, as Rails main rescues
  `PreviewError` and `Vips::Error`. Then the room's bots get their webhooks, as
  `deliver_webhooks_to_bots` follows the broadcast. Where the analysis itself fails, or a video
  has no previewer, the answer is 500 and nothing is broadcast, as Rails raises before
  broadcasting; the message stays, as in Rails.
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
- Deleting a message (in the browser or through the bot API) purges its attachment, variants,
  a video's preview image and the preview's variants, and their files; a ban's removed messages
  and a deleted room's do too, on the cleanup thread.
- Active Storage's proxies send the default headers, as Live controllers do in Rails 8.2, and
  answer a request for several byte ranges with 416. A direct upload's JSON leaves out the
  protected metadata (`identified`, `analyzed`, `composed`), and a direct upload without a content type is
  created with a null one.

Variants, previews and ffprobe analyses are made by media threads (`CAMPFIRE_MEDIA_THREADS`,
default 2), never on an HTTP worker: right after an upload, and when a representation, avatar
or logo is requested before its variant or preview exists, in which case the request waits
(`http::later`) while its worker serves others, and the media thread mails it the answer. A post
with an image, video or audio file waits the same way (up to five minutes) once its rows commit,
its worker giving back the post's cable permit: the media thread processes the file, mails the
exchange its answer, then publishes the message with a permit of its own, the exchange sending
the answer when the publication is acknowledged, as any post's. A webhook reply's delivery thread
hands its attachment reply over the same way. An exchange that times out or whose client
leaves doesn't stop the broadcast. With the media queue full (1,024 jobs), such a post is answered
and broadcast at once, unanalyzed and without a preview, and that is logged: refusing it would
lose a message that has already committed. An avatar's or the logo's video or audio file is
analyzed after its upload, as `AnalyzeJob` does. libvips runs one thread per job and keeps no
operation cache.
Uploads may be up to `CAMPFIRE_UPLOAD_MAX_BYTES` (default 100 MiB, 1 MiB to 1 GiB) on the four
upload forms only; every other body keeps the 1 MiB limit, past which both answer 413. Bodies
are gathered in memory, so each worker's gather budget is twice the upload limit plus 16 MiB.

`test_uploads.py` covers the rows, markup, broadcast, variant sizes, disk serving,
authorization, the size limits, purging, avatars and the logo, and videos and audio: an MJPEG
AVI it writes around frames the image's ffmpeg encodes (with a 4:3 sample aspect ratio, so it
analyzes as 16:9), posted in the browser and through the bot API, a poster requested before its
preview exists, a file ffprobe can't read, a WAV, and the purge of a video's preview and its
variants; `test_webhooks.py` a bot's video reply. `analyzers_test.goose` checks the
analyzers' rules on ffprobe output the AVI can't carry (rotation, conversion errors, tags).
`compare_uploads.py` posts the same files with the same secret to the Rails reference image and
to this server and compares the turbo streams as `compare_rendering.py` compares pages, the
blob, attachment, variant record and search rows, the variants' types and sizes, the room
page's video markup, and the status and markup of a post whose video can't be previewed. Its
files include a PNG past 250 million pixels and one libvips can't decode. They are compared
with the `once-campfire-verification` reference image at `a05ee908`: signed blob and variation
keys, the `JPG` thumbnail's String digest, Marcel's content types, EXIF-turned dimensions, the
1200x500, 512x410 WebP, 512x341 and 192x128 PNG variants, the video's and the WAV's metadata,
the preview image's blob and attachment, its poster variant's digest, the 64x48 WebP poster,
the video's sized markup in its post's turbo stream, and the 200 of the video posted without a
preview. Nothing is masked: copy-link buttons carry Rails main's absolute URL.

Known differences from Rails:

- Rails makes a message's thumbnail or poster inside `MessagesController#create`, before it
  answers; here a media thread makes it while the post waits. Rails makes avatar and logo
  variants on first request only; here they are also made after the upload.
  Uploaded images are analyzed in the request (a header read) rather than by `AnalyzeJob`, so
  their rows hold the analyzed metadata from the start.
- Rails makes a webhook reply's analysis and preview inside its `Bot::WebhookJob`; here the
  delivery thread hands them to a media thread, which broadcasts the reply once they are made. A
  post whose processing outlasts five minutes is answered 503 ("Delivery timed out"), and still
  broadcast when its processing ends. With the media queue full, a post with a file is answered
  and broadcast at once, without analysis or preview (above); Rails has no such queue.
- Analysis and previews read the blob's file in place, through a link named with its
  extension, rather than a checksum-verified copy (`Blob#open`), as image variants here already
  do. A preview whose ffmpeg writes nothing fails rather than storing an empty image.
- Variant and preview bytes differ from Rails' where libvips' or ffmpeg's build or their codec
  libraries do (this image builds libvips 8.16.1 and ffmpeg 7.1.5, the Rails image's versions,
  against Ubuntu 24.04's libraries and compiler); sizes, formats and rows match.
- A logo or avatar whose variant libvips can't make (a corrupt image) gets the stock icon or
  the initials; Rails raises. A representation that can't be made answers 500, as in Rails.
- Filenames longer than 1 KiB are refused (500). Content-Disposition's ASCII fallback
  transliterates Latin-1 letters only, other characters becoming `?`.
- Deleting a room or banning a user purges the messages' attachments and rich-text embeds, with
  their variants, in the cleanup thread's batch transactions, and deletes their files after
  each commits; Rails purges them in `purge_later` jobs of their own.

## Web Push

With `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY` set (URL-safe Base64, as `WebPush.generate_key`
writes them, and checked to be one P-256 key pair at startup, which logs `Web Push: on` or why
it is off), every new message is pushed as `Room::MessagePusher` does at `a05ee908`: browser
posts, bot API posts and webhook replies alike. After the commit, `create_message` puts one job
on the delivery queue, whatever the room's size. A delivery thread then finds the subscriptions
of the room's active members (not banned or deactivated, who keep their subscriptions but are
sent nothing) other than the author whose membership is visible and disconnected
(`connected_at` missing or over 60 seconds old, as cable presence keeps it), involved in
everything, then involved in mentions and mentioned in the message, each in id order. The
payload is Rails' `JSON.generate` of `{title, options: {body, icon: "/account/logo", data:
{path: "/rooms/:id", badge}}}`: a shared room's name and "Creator: plain text", or in a
direct room the creator's name and the plain text, which for a file alone is its name as
`Filename#to_s` sanitizes it; the badge is the subscriber's count of
unread memberships. Each notification is then its own job, as each is a pool task in Rails.
`POST /users/me/push_subscriptions/:id/test_notifications` queues "Campfire Test" with a
random UUID and the subscriptions page's URL for the user's own subscription (404 otherwise)
and redirects. Every page of a signed-in session ends with Rails main's
`push-subscription-sync` marker, the SHA-256 of the session's id and creation time, which the
browser uses to post its subscription again once per session, since a password change
removes every subscription of the user's.

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
message's own job is too, where Solid Queue keeps `Room::PushMessageJob`. Each delivery opens
its own connection, where Rails main keeps idle connections to the push services for 30
seconds (at most 150) and reuses them.

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
a first delivery. `test_push.py` checks who is notified for each involvement, for presence and
for a banned member,
the bot API, direct rooms, the decrypted payload against Rails' JSON and the VAPID signature
with its own RFC 8291 and ES256 code, refusals, 404/410/500 answers and invalid keys, test
notifications and that slow push services never delay a POST; `push_crypto_test.c` checks
RFC 8291's example, ES256 and the address policy. The test's push service listens on a Unix
socket, reached through two TEST ONLY settings that are off unless set:
`CAMPFIRE_PUSH_TEST_RESOLVE` (`name=address,…`, answered instead of DNS, still judged by the
guard) and `CAMPFIRE_PUSH_TEST_CONNECT` (where to connect once the guard admits an address);
the server logs a `TEST ONLY` line when either is set.

## Sign-in, setup and HTTPS

`/session/new`, the first run (`/first_run`) and joining (`/join/:code`) render Rails' views
in the layout, with avatar uploads. A failed sign-in renders the page with Rails' alert and
401; ten attempts in three minutes from one address render it with 429. An unauthenticated
request is sent to sign in and returned afterwards to the URL it asked for
(`return_to_after_authenticating`, kept with the flash in Rails' encrypted `_campfire_session`
cookie). Signing out removes the named push subscription, the session and its cookie, and
resets the user's cable connections. A taken email sends the visitor to sign in with the email
filled in; a signed-in user is sent away from the setup pages; join codes are Rails'
`xxxx-xxxx-xxxx`. Sessions record the client's address and user agent and refresh them at most
hourly (`Session#resume`), which also signs the `session_token` cookie again and so keeps its
permanent expiry rolling; a request other than GET or HEAD from a banned address gets 429.
Every ApplicationController response carries `X-Version` and `X-Rev`, and a browser Rails'
`allow_browser` refuses gets its unsupported-browser page (the `useragent` gem's checks, matched
against 382 of its vectors).

As in Rails' production settings, `assume_ssl` and `force_ssl` are on unless `DISABLE_SSL` is
set: every request counts as HTTPS, so URLs are `https://`, cookies are secure, and responses
carry HSTS (but not a WebSocket's 101). Writes are checked by `Sec-Fetch-Site` and `Origin`,
without authenticity tokens, as Rails main's header-only forgery protection (with
`load_defaults` 8.2's origin check) and the Rust and Jai ports check them, so pages carry no
`csrf-*` meta tags or `authenticity_token` fields; origins are checked against the same scheme. A
plain-HTTP deployment, and the shared harness (its `fixtures/reference.env`), set
`DISABLE_SSL=true`.

With `TLS_DOMAIN`, the image terminates TLS itself, as the Rails image's Thruster does: it gets
certificates through TLS-ALPN-01 from `ACME_DIRECTORY` (Let's Encrypt by default, with
`EAB_KID`/`EAB_HMAC_KEY` for external account binding), serves h2 and HTTP/1.1 by ALPN on
`HTTPS_PORT` (443), redirects port 80 (`HTTP_PORT`) as Thruster does, renews certificates
without a restart, and keeps them in autocert's layout under `/rails/storage/thruster`, so an
install moved from the Rails image keeps its certificates. Settings are read as
`THRUSTER_<NAME>` first, then `<NAME>`. The ACME lane and the chooser it feeds are goose-acme's
`acme.serve` (`v0.0.5`).

## Rooms, Pings and navigation

Open and closed rooms' new and edit pages render Rails' form with the people list, the
Everyone/closed switch and the delete button; members who didn't create a room get Rails'
read-only page, and creation honours the account's restriction. New open rooms give everyone
`mentions` involvement. Pings (`/rooms/directs`) have their settings page and deletion, may
include bots and deactivated users, and are prepended to each member's sidebar. The mentions
and Ping pickers (`/autocompletable/users`) answer Rails' JSON or HTML, 20 to a page with
`X-Total-Count` and `Link`. A room a user can't reach sends them to the root with Rails'
"Room not found or inaccessible" alert, and `/` goes to the last room visited (the `last_room`
cookie) or shows the welcome page. Permalinks (`/rooms/:id/@:message_id`) show the messages
around one. Message paging takes `before` and `after`, answers 204 for an empty page, and
validates with Rails main's `fresh_when etag:` (an ETag of the page, no Last-Modified).
Searching records the user's ten latest searches, sanitizes the query as Rails does
(`gsub(/[^[:word:]]/, " ")`) and quotes each word for FTS5 as `Message.match_terms` does, so
`AND`, `OR` and `NEAR` are searched for as words; results are the last 100 by the
search index's rowid, the message id, as in Rails since
[#304](https://github.com/basecamp/once-campfire/pull/304), which the Rust and Jai ports and the
shared harness follow too.

## Messages

The edit frame is Rails' `messages/edit`, with Save, Delete and the close links, for text and
attachment messages alike; an update's response and broadcast replace only the message's
presentation, with `maintain_scroll`. Message ids in the markup and in broadcast targets come
from the primary key (`message_<id>`, `presentation_message_<id>` and the rest), with the
client's id in `data-client-message-id`, as Rails main has them since GHSA-3v99-4vxh-xg84, so
one client can't target another's message by choosing its client id. Bot bodies are stored as
Rails stores them and sanitized when rendered (disallowed elements dropped with their content,
as `SanitizeTags` does). Text nodes outside links are linked as `rails_autolink` links them
(URLs of its schemes or `www.`, and email addresses, trailing punctuation left outside), and a
newline just after `<pre>` is dropped as the HTML5 parser drops it. A file embedded in the rich
text by an attachable SGID this app signed is shown by its name and size, or its caption, as
Rails main's `active_storage/blobs/_blob` shows it. The editor gets each attachment's rendered
partial as its content, as Lexxy expects. When a message is posted, members of a shared room
who are already unread are left as they are (`Room#unread_memberships`). A messages page asked
for in a format other than HTML answers 500, as `render_to_string`'s missing template does.
`POST /unfurl_link` follows Rails' OpenGraph fetching on four threads off the HTTP workers,
refusing private and loopback addresses before connecting and after every redirect; previews
are stored, rendered as Rails' `_opengraph_embed`, and a message that is only its previewed link
shows just the preview.

## Caching headers and conditional requests

Responses carry what Rails' middleware adds (`etag.goose`). Rack::ETag gives a 200 or 201 with
a body `ETag: W/"…"` (the first 32 hex digits of the body's SHA-256, taken before compression,
so the same in every encoding) and `Cache-Control: max-age=0, private, must-revalidate`; other
controller responses without a Cache-Control of their own get `no-cache`. Rack::ConditionalGet
answers 304 to a GET or HEAD whose If-None-Match equals the ETag exactly, or, without one, to an
If-Modified-Since against a Last-Modified; Rack::Head keeps the ETag and sends Content-Length 0.
Controller responses carry Rails 8.2's `default_headers` (X-Frame-Options,
X-Content-Type-Options and the rest, no longer X-XSS-Protection), the Live controllers'
(avatars, the logo, Active Storage's proxies) included, and none has a Server field. Active
Storage's disk files and the assets carry Rack::Files' and ActionDispatch::Static's headers. The
page cache computes a page's validators once, when it stores the page, and replays them on a
hit; on the cached room page this measured no throughput change.

The Content-Security-Policy is Rails main's (`csp.goose`): ApplicationController's responses,
a halted before_action's included, get `script-src <host>/assets/ 'sha256-…' 'sha256-…';
object-src 'none'; base-uri 'self'; worker-src <host>/service-worker.js`, with the hashes of the
importmap and the inline `import "application"`, computed when the assets are compiled; other
controllers and Action Cable get the configured `script-src 'self'; object-src 'none'; base-uri
'self'`; exception pages, `public/` files, assets and 304s get none. Pages carry Rails'
`<meta name="csp-nonce" />`. `DISABLE_CONTENT_SECURITY_POLICY=true` drops both. Vary is built
as Rails main and Thruster build it: `Sec-Fetch-Site` from forgery protection's after_action
(where the action ran, outside the controllers that skip forgery protection and the bot API),
`Accept` where a render negotiated it, and `Accept-Encoding` appended as Thruster appends it.
The policy and Vary depend on the request's Host and Accept, which are part of the page cache's
key.

## Error pages, public files and routing

Exceptions answer as ShowExceptions and PublicExceptions do (`public_pages.goose`): Rails'
`public/404.html`, `422.html` and `500.html`, an empty page for a status without one, the
`{status:, error:}` hash for JSON, XML and YAML requests, `charset=UTF-8`, and no version
headers. Where a Rails controller answers with `head`, Goose sends the same empty response.
Requests are matched against Rails' route table (158 routes, the engines' included) before
authentication, so a path or method no route takes, or a route whose controller lacks the
action, gets the 404 page without a session, as in Rails. A request's format follows Rails
8.2's strict Accept negotiation, so `/nope.json` asked for with a browser's Accept gets the HTML
404 page. `public/` (`robots.txt` and the error pages, vendored from `90b3300` and unchanged at
`a05ee908`) and the assets are served as ActionDispatch::Static serves them, with its path
cleaning, `.html` fallback, Last-Modified, If-Modified-Since, byte ranges and Rails 8.2's
`charset=utf-8` on HTML and CSS.

Avatars and the account logo carry the Live controllers' headers: weak ETags, Rails' order of
Cache-Control, `send_file`'s fields and the default headers; the initials avatar is Rails'
`show.svg.erb` and a bot's is Rails' `default-bot-avatar.svg`. The Active Storage proxies stream
blobs and representations with `http_cache_forever`'s headers and byte ranges. Direct uploads
(`POST /rails/active_storage/direct_uploads`, then the signed disk `PUT`) answer Rails' JSON and
errors, and the Action Mailbox conductor and ingress routes answer as in production (403 and
404).

## Database schema

An empty database gets Rails main's schema (`data/schema.sql`, from `a05ee908`), recorded in
`schema_migrations` and `ar_internal_metadata` as `db:schema:load` records it, so the Rails
image boots it as up to date. A database Campfire `90b3300` made, or an earlier Goose made from
that schema, is migrated at boot in one write transaction, as Rails main's `db:prepare` migrates
it: the two message indexes (`room_id` with `created_at`, and with `updated_at`), and
`rooms.messages_count`, counted for each room, with `Room::MessagesCount`'s three triggers. As
`Room::MessagesCount.ensure!` does, a database with the column but not every trigger is counted
again and gets all three. A database from before `90b3300` is refused, with its pending
migrations logged: boot the Rails image on it once. The bot API's `X-Total-Count` reads
`rooms.messages_count`, as Rails main's does. `test_setup.py` checks each case against
`90b3300`'s schema.

## Deliberate differences

- **Session cookie.** Rails signs `session_token` again on every authenticated request; here,
  as in the Rust and Jai ports, it is signed again with the hourly `Session#resume`, so a page
  served from the cache needs no cookie of its own. Its permanent expiry keeps rolling.
  `_campfire_session` is written only when it holds a flash or a return-to URL, as in the Rust
  port.
- **Frame layout tokens.** A page rendered for a Turbo frame (the room, a permalink, search) uses
  turbo-rails' frame layout, which still calls `csrf_meta_tags`, so Rails writes `csrf-param` and a
  freshly masked `csrf-token` into its head, and keeps the token's seed in the session. Nothing reads
  them: forgery protection checks `Sec-Fetch-Site` and `Origin` only. Goose leaves them out, which
  spares frame responses a session write; these are the three search rows that differ.
- **Jobs.** Webhooks, Web Push, unfurling, media processing and the cleanup after a room's
  deletion or a ban run on in-process threads with in-memory queues. Work queued or running at
  shutdown is lost: Solid Queue keeps it, and the Rust and Jai ports run their queued jobs
  before they stop (Rust up to a deadline). A crash midway through a room's deletion or a ban's
  removals leaves the rest, as a lost job leaves it in Rails.
- **Room deletion and bans.** As Rails main's `Room::DestroyJob` and `RemoveBannedContentJob`,
  but on the cleanup thread, 50 messages per write transaction. A ban's removals are broadcast
  one publication per room per batch, where Rails broadcasts one per message (see
  [account administration](#account-administration-pwa-and-push-subscriptions)).
- **Media.** Attachments are analyzed and previewed before the post is answered, as in Rails,
  and within Rails main's limits, but on a media thread: a post whose processing takes over five
  minutes answers 503 and is still broadcast when it ends, and with the media queue full a file
  goes out without analysis or preview. ffprobe is stopped after 30 seconds, where Rails sets it
  no limit; ffmpeg's 10 seconds are Rails main's.
- **Unfurling.** An unfurl has 10 seconds in all for everything the link leads to (the
  lookups, each redirect, the page and the image check), and then answers 204, however
  slowly a host sends; each connect, TLS included, and each read and write has 7 seconds,
  and a GET isn't sent again, as in Rails main (from its `a196a93` and `414ff33`). A lookup
  still going at the deadline is left to end on a thread of its own. The sanitizer approximates
  Nokogiri/Loofah rather than parsing HTML5.
- **Rich text.** An attachment naming an SGID this app didn't sign is left out of the rendered
  message, where Rails answers 500. A file embedded in the rich text doesn't yet reach the
  search index's text or the plain text of a bot's webhook payload.
- **Live notices.** Typing and read notices can be dropped for a stalled or flooded tab (see
  [Live notices and revocation](#live-notices-and-revocation)). Unread notices ride the
  message's own publication to every member's UnreadRoomsChannel subscription, where Rails main
  sends them from a job to the members who are unread or connected to the room; filtering would
  take a query per post. The members this adds are those with an invisible membership, whose
  sidebar doesn't list the room, and an author no longer connected to it. A Ping's sidebar
  broadcasts after the first member's take a publication permit only if one is free; with all
  64 in use, that member sees the Ping at their next sidebar load.
- **Web Push.** Each delivery opens its own connection, where Rails main keeps idle connections
  to the push services and reuses them.
- **TLS.** Certificates are ordered at startup rather than at a name's first handshake; only
  TLS-ALPN-01 is used; the server speaks TLS 1.3 with ECDSA certificates, and non-ASCII names
  must be given as `xn--`. Thruster's other settings (its cache, gzip, X-Sendfile, timeouts,
  request size, logging and a separate `TARGET_PORT` listener) aren't reproduced.
- **Validators.** Rails main gzips its cached pages (the room, messages, search and sidebar
  pages) itself and takes their ETag from the gzipped body, so a client that accepts gzip gets a
  different ETag from an identity one and its If-None-Match never matches: it never gets a 304.
  Goose's ETag is taken before compression, the same in every encoding, so revalidation works
  for every client. Thruster's response cache, which answers a warm URL's Range and
  If-Modified-Since with the whole stored 200, isn't reproduced. If-Modified-Since is read in
  the IMF-fixdate form only.
  A Live controller's empty `head` is always chunked; the Rails image sends it chunked or with
  Content-Length 0.

## What the benchmarks measure

The HTTP throughput samples have no connected WebSocket subscribers. The separate shared
fan-out workload measures complete delivery to 64 tabs with six subscriptions each and
audits persisted message, rich-text and FTS bodies; its tabs subscribe to UnreadRoomsChannel,
so each also receives an unread notice per message, as from Rails and Jai. Neither workload
measures the rest of the application, and neither establishes an intrinsic language-speed
advantage.
