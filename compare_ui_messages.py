#!/usr/bin/env python3
"""Differential message checks against the Rails reference image: the same edits, deletes, bot posts and
link preview requests, with the same secret, to Rails and to this server, compared as parsed HTML
(compare_rendering.CanonicalHTML), by status, and by what the room's stream broadcasts; and the rich
text corpus (rich_text_corpus.py) posted through the bot API and the composer, and as edits, compared by
the bodies stored. Needs Docker and the reference image:

    python3 compare_ui_messages.py once-campfire-goose:messages-app [--reference once-campfire-verification:reference-a05ee90]"""
import argparse
import base64
import hashlib
import html
import json
from pathlib import Path
import re
import secrets
import socket
import struct
import tempfile
import time
from urllib.parse import urlencode

import compare_db
from compare_rendering import CanonicalHTML
from compare_uploads import App, normalize
from rich_text_corpus import CORPUS
from test_uploads import multipart, png


class Cable:
    def __init__(self, app):
        self.sock = socket.create_connection(("127.0.0.1", app.port), timeout=20)
        cookie = "; ".join(f"{k}={v}" for k, v in app.cookies.items())
        self.sock.sendall((f"GET /cable HTTP/1.1\r\nHost: 127.0.0.1:{app.port}\r\nOrigin: http://127.0.0.1:{app.port}\r\n"
                           "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                           "Sec-WebSocket-Protocol: actioncable-v1-json\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                           f"Cookie: {cookie}\r\n\r\n").encode())
        head = b""
        while not head.endswith(b"\r\n\r\n"):
            head += self.take(1)
        assert b" 101 " in head.split(b"\r\n")[0], head

    def take(self, size):
        data = bytearray()
        while len(data) < size:
            part = self.sock.recv(size - len(data))
            assert part, "WebSocket EOF"
            data.extend(part)
        return data

    def send(self, value):
        data = json.dumps(value).encode()
        mask = secrets.token_bytes(4)
        size = bytes([0x80 | len(data)]) if len(data) < 126 else b"\xfe" + struct.pack("!H", len(data))
        self.sock.sendall(b"\x81" + size + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))

    def receive(self):
        result = bytearray()
        while True:
            op, size = self.take(2)
            if size == 126: size = struct.unpack("!H", self.take(2))[0]
            elif size == 127: size = struct.unpack("!Q", self.take(8))[0]
            result.extend(self.take(size))
            if op & 0x80:
                if op & 0x0F in (9, 10): result.clear(); continue
                return json.loads(result)

    def subscribe(self, page):
        for tag in re.findall(r"<turbo-cable-stream-source[^>]+>", page):
            channel = re.search(r'channel="([^"]+)"', tag)[1]
            signed = html.unescape(re.search(r'signed-stream-name="([^"]+)"', tag)[1])
            identifier = json.dumps({"channel": channel, "signed_stream_name": signed})
            self.send({"command": "subscribe", "identifier": identifier})
        time.sleep(1.5)

    def expect(self, needle):
        """The next broadcast containing needle, or one aimed at the same kind of element by another id (a server
        that still uses the client's id), so the id shows as a difference; if none comes, a marker, so the
        difference is reported rather than the run aborted."""
        loose = needle.split("_message_")[0] + "_message_" if "_message_" in needle else needle
        self.sock.settimeout(10)
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                body = self.receive().get("message")
                if isinstance(body, str) and loose in body:
                    return body
        except (TimeoutError, OSError):
            pass
        return f"NO BROADCAST containing {needle}"


def main_of(page):
    start = page.index('<main id="main-content">')
    return page[start:page.index("</main>", start) + 7]


def presentation_of(page, id):
    # Message DOM ids come from the primary key (GHSA-3v99-4vxh-xg84), not the client's id.
    # A server that still names the element by the client's id isn't found by the primary key: the first
    # presentation is compared instead, so the id shows as a difference rather than a crash.
    start = page.find(f'<div id="presentation_message_{id}"')
    if start < 0: start = page.find('<div id="presentation_message_')
    if start < 0: return f"NO presentation_message_{id}"
    end = page.find('<turbo-frame id="boosting_', start)
    return page[start:end if end >= 0 else len(page)]


def value_of(page):
    match = re.search(r'<lexxy-editor [^>]*value="([^"]*)"', page)
    return re.sub(r"avatar\?v=\d+", "avatar?v=VERSION", html.unescape(match[1])) if match else None


def run(app):
    results = run_steps(app)
    base = f"http://127.0.0.1:{app.port}"
    uuid = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

    def clean(value):
        if isinstance(value, str): return re.sub(uuid, "UUID", value.replace(base, "http://SERVER"))
        if isinstance(value, (list, tuple)): return type(value)(clean(v) for v in value)
        if isinstance(value, dict): return {k: clean(v) for k, v in value.items()}
        return value
    return {key: clean(value) for key, value in results.items()}


def run_steps(app):
    results = {}
    app.request("/first_run")
    status, headers, _ = app.request("/first_run", "user%5Bname%5D=Ada+Admin&user%5Bemail_address%5D=ada%40example.test&user%5Bpassword%5D=admin+password+123")
    assert status in (302, 303), status
    # The database can't be read while the container runs (a bind mount shares no WAL index), so ids
    # come from the responses.
    room = 1
    cable = Cable(app)
    cable.subscribe(app.request(f"/rooms/{room}")[2].decode())
    stream = {"Accept": "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"}

    def post(body, client):
        status, _, created = app.request(f"/rooms/{room}/messages", urlencode({"message[body]": body, "message[client_message_id]": client}), headers=stream)
        assert status == 200, status
        return int(re.search(rb'data-message-id="(\d+)"', created)[1])

    def page(path, **kw):
        status, headers, body = app.request(path, **kw)
        return status, normalize(body.decode())

    text = post("<p>Don't <strong>panic</strong> &amp; https://example.com</p>", "c1")
    status, body = page(f"/rooms/{room}/messages/{text}/edit")
    results["edit text: status"] = status
    results["edit text: main"] = main_of(body)
    status, body = page(f"/rooms/{room}/messages/{text}/edit", headers={"Turbo-Frame": f"edit_message_{text}"})
    results["edit text in a frame: main"] = main_of(body)
    status, body = page(f"/rooms/{room}/messages/{text}")
    results["show: status"] = status
    results["show: presentation"] = presentation_of(body, text)

    sgid = re.search(r'sgid="([^"]+)"', app.request(f"/autocompletable/users?room_id={room}")[2].decode())[1]
    embed = ('<actiontext-opengraph-embed>\n<div class="og-embed gap "><div class="og-embed__content"><div class="og-embed__title">'
             '<a href="https://news.example.org/story" rel="noreferrer" target="_blank">Big &amp; news</a></div>'
             '<div class="og-embed__description">All about it, at length</div></div><div class="og-embed__image">'
             '<img src="https://news.example.org/i.png" class="image center" alt="" /></div></div></actiontext-opengraph-embed>')
    attachment = f'<action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" content="{html.escape(embed)}"></action-text-attachment>'
    rich = post(f'<p>Hi <action-text-attachment sgid="{sgid}" content-type="application/vnd.campfire.mention" content="x"></action-text-attachment>'
                f' see https://news.example.org/story</p>{attachment}', "c2")
    status, body = page(f"/rooms/{room}/messages/{rich}")
    results["mention and preview: presentation"] = presentation_of(body, rich)
    status, body = page(f"/rooms/{room}/messages/{rich}/edit")
    results["mention and preview: editor value"] = value_of(body)
    solo = post(f"<p>https://news.example.org/story</p>{attachment}", "c3")
    results["solo preview: presentation"] = presentation_of(page(f"/rooms/{room}/messages/{solo}")[1], solo)
    sneaky = embed.replace("https://news.example.org/story", "http://127.0.0.1/rooms/1").replace("https://news.example.org/i.png", "javascript:alert(1)")
    odd = post(f'<p>Look</p><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" content="{html.escape(sneaky)}"></action-text-attachment>', "c4")
    results["unsafe preview: presentation"] = presentation_of(page(f"/rooms/{room}/messages/{odd}")[1], odd)

    body, kind = multipart([("message[client_message_id]", "c5"), ("message[attachment]", ("notes.txt", "text/plain", b"plain notes\n"))])
    status, _, created = app.request(f"/rooms/{room}/messages", body, kind, headers=stream)
    assert status == 200, status
    attached = int(re.search(rb'data-message-id="(\d+)"', created)[1])
    status, body = page(f"/rooms/{room}/messages/{attached}/edit")
    results["edit attachment: status"] = status
    results["edit attachment: main"] = main_of(body)

    status, headers, _ = app.request(f"/rooms/{room}/messages/{text}", urlencode({"_method": "patch", "message[body]": "<p>Edited <em>now</em></p>"}), headers=stream)
    results["update: status and location"] = (status, re.sub(r"^http://[^/]+", "", headers.get("location", "")))
    results["update: broadcast"] = normalize(cable.expect(f'target="presentation_message_{text}"'))
    for label, data, accept in (("update without message", {"_method": "patch", "other": "x"}, stream),
                                ("update as JSON", {"_method": "patch", "message[body]": "j"}, {"Accept": "application/json"}),
                                ("update as a turbo stream", {"_method": "patch", "message[body]": "t"}, {"Accept": "text/vnd.turbo-stream.html"}),
                                ("update to blank", {"_method": "patch", "message[body]": ""}, stream)):
        results[f"{label}: status"] = app.request(f"/rooms/{room}/messages/{text}", urlencode(data), headers=accept)[0]
    results["show as JSON: status"] = app.request(f"/rooms/{room}/messages/{text}.json")[0]
    status, headers, body = app.request(f"/rooms/{room}/messages/{text}", urlencode({"_method": "delete"}), headers=stream)
    results["destroy: response"] = (status, body.decode())
    results["destroy: broadcast"] = cable.expect('action="remove"')
    results["destroy as HTML: status"] = app.request(f"/rooms/{room}/messages/{attached}", urlencode({"_method": "delete"}))[0]
    results["destroyed"] = [app.request(f"/rooms/{room}/messages/{id}")[0] for id in (text, attached)]

    assert app.request("/account/bots", urlencode({"user[name]": "Deploy bot"}))[0] in (302, 303)
    key = re.search(rf"/rooms/{room}/([0-9]+-[^/\"&<]+)/messages", html.unescape(app.request("/account/bots")[2].decode()))[1]
    plain = {"Content-Type": "text/plain"}
    bot_body = 'Deploy <b>done</b>: <a href="https://ci.example.com/1" onclick="evil()">build 1</a><script>steal()</script> &amp; <em>more</em>'
    status, headers, _ = app.request(f"/rooms/{room}/{key}/messages", bot_body.encode(), "text/plain", headers=plain)
    results["bot post: status"] = status
    bot_message = int(headers["location"].rsplit("/", 1)[1])
    shown = page(f"/rooms/{room}/messages/{bot_message}")[1]
    results["bot post: presentation"] = presentation_of(shown, bot_message)
    # The stored body, compared exactly (a list, so it isn't compared as parsed HTML).
    stored = "SELECT body FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?"
    results["bot post: stored body"] = [compare_db.one(app.work, app.name, stored, bot_message)]
    for label, raw in (("bare ampersand", "Pong <b>bold</b> & more"), ("unclosed tag", "<p>Direct <em>reply</em><script>alert(1)</script>")):
        status, headers, _ = app.request(f"/rooms/{room}/{key}/messages", raw.encode(), "text/plain", headers=plain)
        posted = int(headers["location"].rsplit("/", 1)[1])
        results[f"bot post with {label}: stored body"] = [status, compare_db.one(app.work, app.name, stored, posted)]
    items = json.loads(app.request(f"/rooms/{room}/{key}/messages")[2])
    item = next(i for i in items if i["id"] == bot_message)
    results["bot post: JSON body"] = item["body"]
    status, _, body = app.request(f"/rooms/{room}/{key}/messages/{bot_message}", b"Now <i>green</i>", "text/plain", method="PUT", headers=plain)
    results["bot update: status and body"] = (status, json.loads(body)["body"])
    results["bot update: broadcast"] = normalize(cable.expect(f'target="presentation_message_{bot_message}"'))

    # After the database reads above: more writes leave the bind-mounted file unreadable while the app runs.
    # Links are made in text nodes only, outside links, escaped as the serializer writes text.
    for label, raw in (("a URL in attributes", '<p><img alt="see http://alt.example.com" title="http://title.example.com" src="https://img.example.com/i.png"> after</p>'),
                       ("a pre's leading newline", "<pre>\ncode http://pre.example.com\n</pre>"),
                       ("ampersands", "<p>a&amp;b http://x.test/?a=1&amp;b=2 &lt;tag&gt;</p>"),
                       ("an email by a non-breaking space", "<p>mail&nbsp;ada@example.test&nbsp;now, www.example.com.</p>"),
                       ("a link's own URL", '<p><a href="https://a.example.com">https://inner.example.com</a> and https://outer.example.com</p>')):
        status, headers, _ = app.request(f"/rooms/{room}/{key}/messages", raw.encode(), "text/plain", headers=plain)
        posted = int(headers["location"].rsplit("/", 1)[1])
        results[f"linking {label}: presentation"] = presentation_of(page(f"/rooms/{room}/messages/{posted}")[1], posted)
    # A file in the rich text (a direct upload's attachable sgid) is shown by its name and size, with no preview.
    payload = png(30, 20)
    checksum = base64.b64encode(hashlib.md5(payload).digest()).decode()
    status, _, created = app.request("/rails/active_storage/direct_uploads", json.dumps({"blob": {"filename": "inline.png", "byte_size": len(payload),
                                     "checksum": checksum, "content_type": "image/png"}}), "application/json")
    assert status == 200, status
    created = json.loads(created)
    status, _, _ = app.request(re.sub(r"^https?://[^/]+", "", created["direct_upload"]["url"]), payload, "image/png", method="PUT")
    assert status == 204, status
    for label, raw in (("a file", f'<p>Here</p><action-text-attachment sgid="{created["attachable_sgid"]}" content-type="image/png" filename="inline.png" filesize="{len(payload)}"></action-text-attachment>'),
                       ("a captioned file", f'<p>Here</p><action-text-attachment sgid="{created["attachable_sgid"]}" content-type="image/png" caption="A &amp; B"></action-text-attachment>')):
        status, headers, _ = app.request(f"/rooms/{room}/{key}/messages", raw.encode(), "text/plain", headers=plain)
        results[f"rich text with {label}: status"] = status
        if "location" in headers:
            posted = int(headers["location"].rsplit("/", 1)[1])
            results[f"rich text with {label}: presentation"] = presentation_of(page(f"/rooms/{room}/messages/{posted}")[1], posted)
    for label, data, kind in (("unfurl a private address", json.dumps({"url": "http://127.0.0.1/secret"}), "application/json"),
                              ("unfurl localhost", json.dumps({"url": "http://localhost:3000/"}), "application/json"),
                              ("unfurl a blank URL", json.dumps({"url": ""}), "application/json"),
                              ("unfurl an array", json.dumps({"url": ["http://example.com"]}), "application/json"),
                              ("unfurl a form's private URL", "url=http%3A%2F%2F10.0.0.1%2F", "application/x-www-form-urlencoded"),
                              ("unfurl without a URL", "other=1", "application/x-www-form-urlencoded")):
        status, _, body = app.request("/unfurl_link", data, kind)
        results[label] = (status, body.decode()[:0])
    results["unfurl by GET: status"] = app.request("/unfurl_link")[0]
    cable.sock.close()
    results.update(corpus_steps(app, room, key, stream))
    return results


def corpus_steps(app, room, key, stream):
    """Each corpus body posted by the bot API and by the composer, and every fifth as a bot's update
    and a composer edit; the bodies stored, exactly, as [body, stored] pairs (None for no message), read
    from the database once all are posted. A post whose attachment names an SGID that isn't one answers
    500 in Rails after the message is saved, so the database shows whether a refused post made one."""
    plain = {"Content-Type": "text/plain"}
    bot_messages = f"/rooms/{room}/{key}/messages"

    def bot_post(body):
        status, headers, _ = app.request(bot_messages, body.encode(), "text/plain", headers=plain)
        assert status == 201, status
        return int(headers["location"].rsplit("/", 1)[1])

    def composer_post(body, client):
        status, _, created = app.request(f"/rooms/{room}/messages", urlencode({"message[body]": body, "message[client_message_id]": client}), headers=stream)
        match = re.search(rb'data-message-id="(\d+)"', created)
        return int(match[1]) if match else None

    last = marker = bot_post("corpus")
    posted = []
    for body in CORPUS:
        status, headers, _ = app.request(bot_messages, body.encode(), "text/plain", headers=plain)
        if status == 201: last = int(headers["location"].rsplit("/", 1)[1])
        else:
            newest = compare_db.one(app.work, app.name, "SELECT max(id) FROM messages")
            if newest == last: posted.append(None); continue
            last = newest
        posted.append(last)
    for i, body in enumerate(CORPUS):
        composer_post(body, f"corpus-{i}")
    edits = CORPUS[::5]
    updated, edited = [], []
    for i, body in enumerate(edits):
        message = bot_post("before")
        app.request(f"{bot_messages}/{message}", body.encode(), "text/plain", method="PUT", headers=plain)
        updated.append(message)
        message = composer_post("before", f"corpus-edit-{i}")
        app.request(f"/rooms/{room}/messages/{message}", urlencode({"_method": "patch", "message[body]": body}), headers=stream)
        edited.append(message)
    rows = compare_db.query(app.work, app.name, "SELECT m.id, m.client_message_id, rt.body FROM messages m LEFT JOIN action_text_rich_texts rt "
                            "ON rt.record_type='Message' AND rt.record_id=m.id AND rt.name='body' WHERE m.id>? ORDER BY m.id", marker)
    by_id = {id: body for id, _, body in rows}
    by_client = {client: body for _, client, body in rows}
    return {"rich text corpus: bot posts' stored bodies": [[b, by_id.get(m)] for b, m in zip(CORPUS, posted)],
            "rich text corpus: composer posts' stored bodies": [[b, by_client.get(f"corpus-{i}")] for i, b in enumerate(CORPUS)],
            "rich text corpus: bot updates' stored bodies": [[b, by_id.get(m)] for b, m in zip(edits, updated)],
            "rich text corpus: composer edits' stored bodies": [[b, by_id.get(m)] for b, m in zip(edits, edited)]}


def same(a, b):
    if isinstance(a, str) and isinstance(b, str) and "<" in a:
        return CanonicalHTML(a, "http://unused.invalid").events == CanonicalHTML(b, "http://unused.invalid").events
    return a == b


def difference(a, b):
    x, y = CanonicalHTML(a, "http://unused.invalid").events, CanonicalHTML(b, "http://unused.invalid").events
    at = next(i for i, (p, q) in enumerate(zip(x + [None], y + [None])) if p != q)
    return f"at event {at}\n  rails: {x[at:at + 3]}\n  goose: {y[at:at + 3]}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--reference", default="once-campfire-verification:reference-a05ee90")
    args = parser.parse_args()
    secret = secrets.token_hex(64)
    results = {}
    with tempfile.TemporaryDirectory(prefix="campfire-compare-messages-") as directory:
        for label, image in (("rails", args.reference), ("goose", args.image)):
            app = App(image, secret, Path(directory) / label)
            try:
                results[label] = run(app)
            finally:
                app.close()
    failures = 0
    for key, expected in results["rails"].items():
        actual = results["goose"].get(key)
        if same(expected, actual):
            print(f"PASS: {key}")
        else:
            failures += 1
            if isinstance(expected, str) and isinstance(actual, str) and "<" in expected:
                print(f"FAIL: {key} differs {difference(expected, actual)}")
            elif key.startswith("rich text corpus:") and isinstance(actual, list) and len(actual) == len(expected):
                differing = [(e, a) for e, a in zip(expected, actual) if e != a]
                print(f"FAIL: {key}: {len(differing)} of {len(expected)} differ")
                for (body, rails), (_, goose) in differing:
                    print(f"  body:  {body!r}\n  rails: {rails!r}\n  goose: {goose!r}")
            else:
                print(f"FAIL: {key}\n  rails: {expected!r}\n  goose: {actual!r}")
    print(f"{len(results['rails']) - failures} of {len(results['rails'])} match Rails")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
