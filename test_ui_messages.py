#!/usr/bin/env python3
"""Message edit and delete frames, edit broadcasts, link previews and bot message HTML, as in Rails:
MessagesController#show/edit/update/destroy, Messages::ByBotsController and UnfurlLinksController.

Link previews are fetched from a local HTTP server standing in for public sites: the guard still judges
every address, with CAMPFIRE_PUSH_TEST_RESOLVE answering the test hosts' lookups, and
CAMPFIRE_UNFURL_TEST_CONNECT sends the admitted connections to 127.0.0.1 (both TEST ONLY settings)."""
import gzip
import html
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlencode


class WebSocket:
    def __init__(self, port, cookie):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=15)
        self.sock.sendall((f"GET /cable HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\n"
                           f"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nCookie: {cookie}\r\n\r\n").encode())
        head = b""
        while not head.endswith(b"\r\n\r\n"):
            head += self.take(1)
        assert head.startswith(b"HTTP/1.1 101"), head
        assert self.receive()["type"] == "welcome"

    def take(self, size):
        data = bytearray()
        while len(data) < size:
            part = self.sock.recv(size - len(data))
            assert part, "unexpected WebSocket EOF"
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
            if size == 126:
                size = struct.unpack("!H", self.take(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.take(8))[0]
            result.extend(self.take(size))
            if op & 0x80:
                return json.loads(result)

    def subscribe(self, identifier):
        self.send({"command": "subscribe", "identifier": identifier})
        while True:
            message = self.receive()
            if message.get("identifier") == identifier and "type" in message:
                assert message["type"] == "confirm_subscription", message
                return

    def expect(self, *needles):
        """The next publication containing every needle; earlier unrelated publications are skipped."""
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            body = self.receive().get("message")
            if isinstance(body, str) and all(needle in body for needle in needles):
                return body
        raise TimeoutError(f"no publication with {needles}")


def stream_identifiers(page):
    found = {}
    for tag in re.findall(r"<turbo-cable-stream-source[^>]+>", page):
        channel = re.search(r'channel="([^"]+)"', tag)[1]
        signed = html.unescape(re.search(r'signed-stream-name="([^"]+)"', tag)[1])
        found.setdefault(channel, []).append(json.dumps({"channel": channel, "signed_stream_name": signed}))
    return found


def multipart(fields):
    boundary = "----campfire" + secrets.token_hex(8)
    body = b""
    for name, value in fields:
        if isinstance(value, tuple):
            filename, kind, data = value
            body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{filename}\"\r\n"
                     f"Content-Type: {kind}\r\n\r\n").encode() + data + b"\r\n"
        else:
            body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode()
    return body + f"--{boundary}--\r\n".encode(), f"multipart/form-data; boundary={boundary}"


# --- The sites link previews come from -------------------------------------------------------------

SITES = {}      # (host, path) -> (status, headers, body)
FETCHES = []    # (method, host, path)


class Site(http.server.BaseHTTPRequestHandler):
    def answer(self, head):
        host = self.headers.get("Host", "").rsplit(":", 1)[0]
        FETCHES.append((self.command, host, self.path))
        status, headers, body = SITES.get((host, self.path), (404, {"Content-Type": "text/plain"}, b"not found"))
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        if "Content-Length" not in headers:
            self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def do_GET(self):
        self.answer(False)

    def do_HEAD(self):
        self.answer(True)

    def log_message(self, *args):
        pass


def page(*metas, charset=True):
    tags = "".join(f'<meta property="og:{key}" content="{html.escape(value)}">' for key, value in metas)
    return (("<meta charset=\"utf-8\">" if charset else "") + f"<html><head>{tags}</head><body>Hi</body></html>").encode()


HTML = {"Content-Type": "text/html; charset=utf-8"}

site = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Site)
site_port = site.server_address[1]
threading.Thread(target=site.serve_forever, daemon=True).start()
og = f"http://og.test:{site_port}"

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="campfire-ui-messages-") as directory:
    work = Path(directory)
    database = work / "production.sqlite3"
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = dict(os.environ, DATABASE_PATH=str(database), SECRET_KEY_BASE=secrets.token_hex(64), HTTP_PORT=str(port),
               STORAGE_PATH=str(work / "files"),
               CAMPFIRE_PUSH_TEST_RESOLVE="og.test=93.184.216.34,img.test=93.184.216.35,fxtwitter.com=93.184.216.36,"
                                          "private.test=10.1.2.3,hop.test=93.184.216.37",
               CAMPFIRE_UNFURL_TEST_CONNECT="127.0.0.1")
    base = f"http://127.0.0.1:{port}"
    with (work / "server.log").open("w+") as log:
        server = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        sockets = []

        def request(path, data=None, cookie="", method=None, headers=None, raw=False):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            fields = {"Host": f"127.0.0.1:{port}", "Accept-Encoding": "gzip"}
            if cookie:
                fields["Cookie"] = cookie
            if data is not None and not raw:
                fields.update({"Content-Type": "application/x-www-form-urlencoded", "Sec-Fetch-Site": "same-origin"})
                data = urlencode(data, doseq=True)
            fields.update(headers or {})
            conn.request(method or ("GET" if data is None else "POST"), path,
                         data.encode() if isinstance(data, str) else data, fields)
            response = conn.getresponse()
            body = response.read()
            if response.getheader("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            result = response.status, {k.lower(): v for k, v in response.getheaders()}, body.decode()
            conn.close()
            return result

        def query(sql, *args):
            with sqlite3.connect(database, timeout=10) as db:
                return db.execute(sql, args).fetchall()

        def unfurl(value, cookie, kind="json"):
            if kind == "json":
                return request("/unfurl_link", json.dumps({"url": value}), cookie, raw=True,
                               headers={"Content-Type": "application/json", "Sec-Fetch-Site": "same-origin"})
            return request("/unfurl_link", {"url": value}, cookie)

        try:
            for _ in range(200):
                if server.poll() is not None:
                    raise AssertionError("server exited")
                try:
                    if request("/up")[0] == 200:
                        break
                except ConnectionRefusedError:
                    time.sleep(.05)
            else:
                raise AssertionError("server did not start")
            status, headers, _ = request("/first_run", {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test", "user[password]": "admin password"})
            admin = headers["set-cookie"].split(";", 1)[0]
            code = query("SELECT join_code FROM accounts")[0][0]
            status, headers, _ = request(f"/join/{code}", {"user[name]": "Bob Member", "user[email_address]": "bob@example.test", "user[password]": "member password"})
            member = headers["set-cookie"].split(";", 1)[0]
            status, headers, _ = request(f"/join/{code}", {"user[name]": "Cy Member", "user[email_address]": "cy@example.test", "user[password]": "member password"})
            other = headers["set-cookie"].split(";", 1)[0]
            room = 1
            stream = {"Accept": "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"}

            def post(body, client, cookie=member):
                status, _, _ = request(f"/rooms/{room}/messages", {"message[body]": body, "message[client_message_id]": client}, cookie)
                assert status == 200, status
                return query("SELECT id FROM messages WHERE client_message_id=?", client)[0][0]

            reader = WebSocket(port, admin)
            sockets.append(reader)
            reader.subscribe(stream_identifiers(request(f"/rooms/{room}", cookie=admin)[2])["RoomMessagesChannel"][0])

            # The edit frame: messages/edit.html.erb in the application layout, even for a Turbo-Frame request.
            message = post("<div>Don't <b>panic</b> &amp; https://example.com</div>", "edit-1")
            for frame in ({}, {"Turbo-Frame": "edit_message_edit-1"}):
                status, headers, body = request(f"/rooms/{room}/messages/{message}/edit", cookie=member, headers=frame)
                assert status == 200 and headers["content-type"] == "text/html; charset=utf-8", status
                assert body.startswith("<!DOCTYPE html>") and "<title>Campfire</title>" in body
            frame = body[body.index('<turbo-frame id="edit_message_edit-1">'):]
            assert f'<form id="form_message_edit-1" data-controller="form"' in frame and f'action="/rooms/{room}/messages/{message}"' in frame
            assert '<input type="hidden" name="_method" value="patch" />' in frame
            editor = re.search(r'<lexxy-editor ([^>]*)>', frame)[1]
            assert 'name="message[body]"' in editor and 'input="message_body_trix_input_message_edit-1"' in editor
            assert f'data-direct-upload-url="{base}/rails/active_storage/direct_uploads"' in editor
            assert html.unescape(re.search(r'value="([^"]*)"', editor)[1]) == "<div>Don't <b>panic</b> &amp; https://example.com</div>"
            assert f'<lexxy-prompt trigger="@" name="mention" src="/autocompletable/users?room_id={room}"' in frame
            assert "Save changes" in frame and "Delete message" in frame and 'form="delete_form_message_edit-1"' in frame
            assert 'data-turbo-confirm="Are you sure you want to delete this message?"' in frame
            assert frame.count(f'href="/rooms/{room}/messages/{message}"') == 2 and "Close editor and discard changes" in frame
            assert (f'<form id="delete_form_message_edit-1" data-turbo-frame="edit_message_edit-1" action="/rooms/{room}/messages/{message}"'
                    ' accept-charset="UTF-8" method="post"><input type="hidden" name="_method" value="delete" />') in frame
            print("PASS: the edit frame is Rails' edit view, with save, delete and close, in the application layout")

            # show is any member's; edit, update and destroy the creator's or an administrator's.
            status, _, body = request(f"/rooms/{room}/messages/{message}", cookie=other)
            assert status == 200 and body.startswith("<!DOCTYPE html>") and 'id="message_edit-1"' in body and 'id="presentation_message_edit-1"' in body
            assert request(f"/rooms/{room}/messages/{message}/edit", cookie=admin)[0] == 200
            status, _, body = request(f"/rooms/{room}/messages/{message}/edit", cookie=other)
            assert status == 403 and body == ""
            assert request(f"/rooms/{room}/messages/{message}", {"_method": "patch", "message[body]": "hijack"}, other)[0] == 403
            assert request(f"/rooms/{room}/messages/{message}", {"_method": "delete"}, other)[0] == 403
            assert request(f"/rooms/{room}/messages/999999/edit", cookie=member)[0] == 404
            assert request(f"/rooms/999999/messages/{message}", cookie=member)[0] == 404
            assert request(f"/rooms/{room}/messages/{message}.json", cookie=member)[0] == 406
            assert request(f"/rooms/{room}/messages/{message}", {"message[body]": "x"}, member)[0] == 404
            assert request(f"/rooms/{room}/messages/{message}", {"_method": "patch", "message[body]": "x"}, member, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
            assert query("SELECT body FROM message_search_index WHERE rowid=?", message)[0][0] == "Don't panic & https://example.com"
            print("PASS: show for members, edit/update/destroy for the creator or an administrator (403), 404s and formats")

            # update: redirect to the message, and replace only its presentation, keeping the scroll.
            status, headers, body = request(f"/rooms/{room}/messages/{message}", {"_method": "patch", "message[body]": "<p>Edited <em>now</em></p>"}, member, headers=stream)
            assert status == 302 and headers["location"] == f"{base}/rooms/{room}/messages/{message}", (status, headers)
            published = reader.expect('target="presentation_message_edit-1"')
            assert 'maintain_scroll="true"' in published and 'action="replace"' in published and "<em>now</em>" in published
            assert '<div id="presentation_message_edit-1" dir="auto" data-reply-target="body" data-messages-target="body">' in published
            assert 'id="message_edit-1"' not in published and "message__actions" not in published
            assert query("SELECT body FROM message_search_index WHERE rowid=?", message)[0][0] == "Edited now"
            assert request(f"/rooms/{room}/messages/{message}", {"_method": "put", "message[body]": "Put"}, member)[0] == 302
            assert request(f"/rooms/{room}/messages/{message}", {"_method": "patch", "other": "x"}, member)[0] == 400
            assert request(f"/rooms/{room}/messages/{message}", {"_method": "patch", "message[body]": "json"}, member, headers={"Accept": "application/json"})[0] == 500
            assert request(f"/rooms/{room}/messages/{message}", {"_method": "patch", "message[body]": "stream"}, member, headers={"Accept": "text/vnd.turbo-stream.html"})[0] == 406
            assert query("SELECT body FROM message_search_index WHERE rowid=?", message)[0][0] == "stream"
            status, headers, _ = request(f"/rooms/{room}/messages/{message}", {"_method": "patch", "message[body]": ""}, member)
            assert status == 302 and query("SELECT body FROM action_text_rich_texts WHERE record_id=?", message)[0][0] == ""
            print("PASS: update redirects to the message and broadcasts its presentation with maintain_scroll; blank bodies, PUT, 400, JSON 500, 406")

            # destroy: the turbo stream removes it everywhere; without a turbo stream Accept it's 406, deleted all the same.
            status, headers, body = request(f"/rooms/{room}/messages/{message}", {"_method": "delete"}, member, headers=stream)
            assert status == 200 and headers["content-type"].startswith("text/vnd.turbo-stream.html")
            assert body == '<turbo-stream action="remove" target="message_edit-1"></turbo-stream>', body
            reader.expect('<turbo-stream action="remove" target="message_edit-1"></turbo-stream>')
            assert query("SELECT count(*) FROM messages WHERE id=?", message)[0][0] == 0
            doomed = post("Bye", "edit-2")
            status, _, body = request(f"/rooms/{room}/messages/{doomed}", {"_method": "delete"}, admin)
            assert status == 406 and body == "", status
            assert query("SELECT count(*) FROM messages WHERE id=?", doomed)[0][0] == 0
            print("PASS: destroy removes the message with destroy.turbo_stream, and answers 406 to other formats after deleting")

            # An attachment-only message: its presentation and a delete button, no editor.
            body, kind = multipart([("message[client_message_id]", "file-1"), ("message[attachment]", ("notes.txt", "text/plain", b"plain notes\n"))])
            status, _, _ = request(f"/rooms/{room}/messages", body, member, raw=True, headers={"Content-Type": kind, "Sec-Fetch-Site": "same-origin"})
            assert status == 200, status
            attached = query("SELECT id FROM messages WHERE client_message_id='file-1'")[0][0]
            status, _, body = request(f"/rooms/{room}/messages/{attached}/edit", cookie=member)
            frame = body[body.index('<turbo-frame id="edit_message_file-1">'):]
            assert status == 200 and "notes.txt" in frame and "<lexxy-editor" not in frame and "Save changes" not in frame
            assert '<button name="button" type="submit" class="btn btn--negative center margin-block-end" form="delete_form_message_file-1"' in frame
            status, _, body = request(f"/rooms/{room}/messages/{attached}", {"_method": "delete"}, member, headers=stream)
            assert status == 200 and 'target="message_file-1"' in body
            assert query("SELECT count(*) FROM messages WHERE id=?", attached)[0][0] == 0
            assert query("SELECT count(*) FROM active_storage_attachments WHERE record_type='Message' AND record_id=?", attached)[0][0] == 0
            print("PASS: an attachment message's edit frame shows the attachment and its delete button, and it can be deleted")

            # Mentions and link previews round-trip through the editor as Rails rebuilds them.
            sgid = re.search(r'sgid="([^"]+)"', request(f"/autocompletable/users?room_id={room}", cookie=member)[2])[1]
            embed = ('<actiontext-opengraph-embed><div class="og-embed gap "><div class="og-embed__content"><div class="og-embed__title">'
                     '<a href="https://news.example.org/story" rel="noreferrer" target="_blank">Big &amp; news</a></div>'
                     '<div class="og-embed__description">All about it</div></div><div class="og-embed__image">'
                     '<img src="https://news.example.org/i.png" class="image center" alt="" /></div></div></actiontext-opengraph-embed>')
            body = (f'<p>Hi <action-text-attachment sgid="{sgid}" content-type="application/vnd.campfire.mention" content="x"></action-text-attachment>'
                    ' see https://news.example.org/story</p>'
                    f'<action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" content="{html.escape(embed)}"></action-text-attachment>')
            rich = post(body, "rich-1")
            presentation = reader.expect('id="message_rich-1"')
            assert '<div class="og-embed__title">' in presentation and '<a href="https://news.example.org/story">Big &amp; news</a>' in presentation
            assert '<img src="https://news.example.org/i.png" class="image center" alt="">' in presentation and "<figure" not in presentation
            assert '<span class="mention">' in presentation
            assert query("SELECT body FROM message_search_index WHERE rowid=?", rich)[0][0].startswith("Hi @")
            editor = re.search(r'<lexxy-editor ([^>]*)>', request(f"/rooms/{room}/messages/{rich}/edit", cookie=member)[2])[1]
            value = html.unescape(re.search(r'value="([^"]*)"', editor)[1])
            assert f'<action-text-attachment sgid="{sgid}" content-type="application/vnd.campfire.mention" content="&quot;\\u003cspan class=\\&quot;mention\\&quot; sgid=\\&quot;{sgid}\\&quot;\\u003e' in value, value
            assert ('<action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" content="&quot;\\u003cfigure class=\\&quot;attachment attachment--content attachment--og\\&quot;\\u003e'
                    in value), value
            assert '\\u003ca rel=\\&quot;noreferrer\\&quot; target=\\&quot;_blank\\&quot; href=\\&quot;https://news.example.org/story\\&quot;\\u003eBig \\u0026amp; news\\u003c/a\\u003e' in value
            # A preview may not point its link or image at this Campfire, an address or another scheme.
            sneaky = embed.replace("https://news.example.org/story", f"http://127.0.0.1:{port}/rooms/1").replace("https://news.example.org/i.png", "javascript:alert(1)")
            post(f'<action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" content="{html.escape(sneaky)}"></action-text-attachment>', "rich-2")
            presentation = reader.expect('id="message_rich-2"')
            assert "Big &amp; news" in presentation and "/rooms/1\"" not in presentation and "javascript" not in presentation and "og-embed__image" not in presentation
            # A message that is only the link it previews shows the preview alone.
            post(f'<p>https://news.example.org/story</p><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" content="{html.escape(embed)}"></action-text-attachment>', "solo-1")
            presentation = reader.expect('id="message_solo-1"')
            solo = presentation[presentation.index('id="presentation_message_solo-1"'):]
            assert "og-embed__title" in solo and '<a target="_blank" href="https://news.example.org/story">' not in solo and "<p>" not in solo.split("og-embed")[0]
            print("PASS: mentions and link previews are kept, rendered as Rails' partials, rebuilt for the editor, and checked")

            # Bots post HTML, sanitized as rich text renders.
            assert request("/account/bots", {"user[name]": "Deploy bot"}, admin)[0] == 303
            bot_id, token = query("SELECT id,bot_token FROM users WHERE role=2")[0]
            key = f"{bot_id}-{token}"
            text = {"Content-Type": "text/plain"}
            bot_body = 'Deploy <b>done</b>: <a href="https://ci.example.com/1" onclick="evil()">build 1</a><script>steal()</script> &amp; more'
            status, headers, _ = request(f"/rooms/{room}/{key}/messages", bot_body, raw=True, headers=text)
            assert status == 201
            bot_message = query("SELECT id FROM messages WHERE creator_id=?", bot_id)[0][0]
            presentation = reader.expect(f'data-message-id="{bot_message}"')
            assert '<b>done</b>' in presentation and '<a href="https://ci.example.com/1">build 1</a>' in presentation
            assert "onclick" not in presentation and "steal" not in presentation and "&lt;b&gt;" not in presentation
            assert query("SELECT body FROM action_text_rich_texts WHERE record_id=?", bot_message)[0][0] == bot_body
            assert query("SELECT body FROM message_search_index WHERE rowid=?", bot_message)[0][0] == "Deploy done: build 1 & more"
            item = next(i for i in json.loads(request(f"/rooms/{room}/{key}/messages")[2]) if i["id"] == bot_message)
            assert "<b>done</b>" in item["body"]["html"] and "steal" not in item["body"]["html"]
            status, _, body = request(f"/rooms/{room}/{key}/messages/{bot_message}", "Now <i>green</i>", method="PUT", raw=True, headers=text)
            assert status == 200 and json.loads(body)["body"]["plain_text"] == "Now green"
            published = reader.expect(f'target="presentation_message_')
            assert 'maintain_scroll="true"' in published and "<i>green</i>" in published and "message__actions" not in published
            print("PASS: bot messages keep their HTML, sanitized as Rails renders rich text, and bot edits replace only the presentation")

            # Link previews: POST /unfurl_link.
            SITES[("og.test", "/page")] = (200, HTML, page(("title", "Tom & Jerry <b>Live</b>"), ("description", "A\u00a0cat <script>chase</script>"),
                                                           ("image", f"http://img.test:{site_port}/i.png"), ("url", f"{og}/canonical")))
            SITES[("img.test", "/i.png")] = (200, {"Content-Type": "image/png"}, b"")
            status, headers, body = unfurl(f"{og}/page", member)
            assert status == 200 and headers["content-type"] == "application/json; charset=utf-8", (status, body)
            assert body == ('{"title":"Tom \\u0026amp; Jerry Live","url":"' + og + '/canonical","image":"http://img.test:' + str(site_port)
                            + '/i.png","description":"A\\u0026nbsp;cat chase","context_for_validation":{"context":null},"errors":{}}'), body
            assert ("HEAD", "img.test", "/i.png") in FETCHES
            # A relative og:url falls back to the URL; an image that isn't one is dropped; form params work too.
            SITES[("og.test", "/relative")] = (200, HTML, page(("url", "/x"), ("title", "T"), ("image", f"http://og.test:{site_port}/page"), ("description", "D")))
            status, _, body = unfurl(f"{og}/relative", member, kind="form")
            assert status == 200 and json.loads(body) == {"title": "T", "url": f"{og}/relative", "image": None, "description": "D",
                                                          "context_for_validation": {"context": None}, "errors": {}}, body
            assert body.startswith('{"title":"T","url":') and body.index('"image"') < body.index('"description"')
            # Without a declared encoding, non-ASCII bytes go.
            SITES[("og.test", "/latin")] = (200, HTML, page(("title", "Café"), ("description", "Ünïcode"), charset=False))
            assert json.loads(unfurl(f"{og}/latin", member)[2])["title"] == "Caf"
            # Redirects are followed and re-checked.
            SITES[("hop.test", "/go")] = (302, {"Location": f"{og}/page"}, b"")
            assert unfurl(f"http://hop.test:{site_port}/go", member)[0] == 200
            SITES[("hop.test", "/private")] = (301, {"Location": f"http://private.test:{site_port}/page"}, b"")
            SITES[("hop.test", "/ftp")] = (302, {"Location": "ftp://og.test/page"}, b"")
            SITES[("hop.test", "/relative")] = (302, {"Location": "/page"}, b"")
            for i in range(11):
                SITES[("hop.test", f"/loop{i}")] = (302, {"Location": f"http://hop.test:{site_port}/loop{i + 1}"}, b"")
            SITES[("hop.test", "/loop11")] = (200, HTML, page(("title", "T"), ("description", "D")))
            for path in ("/private", "/ftp", "/relative", "/loop0"):
                assert unfurl(f"http://hop.test:{site_port}{path}", member)[0] == 204, path
            assert unfurl(f"http://hop.test:{site_port}/loop2", member)[0] == 200
            assert not any(host == "private.test" for _, host, _ in FETCHES)
            # Nothing from private addresses, other schemes, files and media, or what isn't a 200 text/html page.
            SITES[("og.test", "/text")] = (200, {"Content-Type": "text/plain"}, page(("title", "T"), ("description", "D")))
            SITES[("og.test", "/gone")] = (404, HTML, page(("title", "T"), ("description", "D")))
            SITES[("og.test", "/pic.png")] = (200, HTML, page(("title", "T"), ("description", "D")))
            SITES[("og.test", "/untitled")] = (200, HTML, page(("description", "D")))
            for url in (f"http://127.0.0.1:{site_port}/page", f"http://private.test:{site_port}/page", f"http://localhost:{site_port}/page",
                        f"ftp://og.test:{site_port}/page", f"{og}/text", f"{og}/gone", f"{og}/pic.png", f"{og}/untitled", "not a url"):
                assert unfurl(url, member)[0] == 204, url
            assert ("GET", "og.test", "/pic.png") not in FETCHES
            # A tweet is read from fxtwitter.com; when that can't be read, Rails raises.
            SITES[("fxtwitter.com", "/ada/status/1")] = (200, HTML, page(("title", "Ada"), ("description", "Tweet")))
            assert json.loads(unfurl(f"http://x.com:{site_port}/ada/status/1", member)[2])["title"] == "Ada"
            assert unfurl(f"http://x.com:{site_port}/ada/status/2", member)[0] == 500
            # params.require(:url): blank is 400; anything else that isn't a string unfurls nothing.
            assert unfurl("", member)[0] == 400 and unfurl(None, member)[0] == 400 and unfurl(False, member)[0] == 400 and unfurl([], member)[0] == 400
            assert unfurl(["x"], member)[0] == 204 and unfurl({"a": 1}, member)[0] == 204 and unfurl(5, member)[0] == 204
            assert request("/unfurl_link", {"other": "x"}, member)[0] == 400
            assert request("/unfurl_link", cookie=member)[0] == 404
            assert request("/unfurl_link", {"url": f"{og}/page"}, member, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
            assert request("/unfurl_link", {"url": f"{og}/page"})[0] == 302
            print("PASS: /unfurl_link answers Rails' OpenGraph JSON, follows checked redirects, and refuses private, non-HTML and media URLs")
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read()[-20000:], file=sys.stderr)
            raise
        finally:
            for ws in sockets:
                ws.sock.close()
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
            site.shutdown()
