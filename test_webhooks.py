#!/usr/bin/env python3
"""Bot webhooks: payloads, replies in the database and live, and failing or slow endpoints."""
import base64
import hashlib
import hmac
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
from urllib.parse import quote, urlencode

from test_uploads import avi, jpeg, multipart, png


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
                return message["type"]

    def publication(self, marker, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self.receive()
            if isinstance(message.get("message"), str) and marker in message["message"]:
                return message["message"]
        raise TimeoutError(f"no publication with {marker!r}")

    def close(self):
        self.sock.close()


class Receiver(http.server.ThreadingHTTPServer):
    """A bot's webhook endpoint: records each request and answers by path."""
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.requests = []
        self.changed = threading.Condition()

    def wait(self, path, count=1, timeout=15):
        with self.changed:
            assert self.changed.wait_for(lambda: len(self.of(path)) >= count, timeout), f"no request to {path}"
            return self.of(path)

    def of(self, path):
        return [r for r in self.requests if r["path"] == path]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    replies = {
        "/reply": (200, "text/plain; charset=utf-8", "Pong <b>bold</b> & more"),
        "/html": (200, "Text/HTML", "<p>Direct <em>reply</em><script>alert(1)</script></p>"),
        "/error": (500, "text/plain", "boom"),
        "/json": (200, "application/json", '{"reply":"no"}'),
        "/empty": (200, "text/plain", ""),
        "/png": (200, "image/png", png(40, 30)),
        # A 64x48 MJPEG AVI shown 16:9, which ffprobe and ffmpeg process before it is published.
        "/avi": (200, "video/x-msvideo", avi(64, 48, [jpeg(64, 48, 40 * i, aspect=(4, 3)) for i in range(3)])),
        "/stream": (200, "application/octet-stream", b"\x00\x01binary"),
        "/invalid": (200, "image", b"not a type"),
    }

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        with self.server.changed:
            self.server.requests.append({"path": self.path, "headers": dict(self.headers.items()), "raw": body,
                                         "json": json.loads(body), "at": time.monotonic()})
            self.server.changed.notify_all()
        if self.path == "/slow":
            time.sleep(9)
            status, kind, text = 200, "text/plain", "Too late"
        else:
            status, kind, text = self.replies[self.path]
        data = text if isinstance(text, bytes) else text.encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except OSError:
            pass  # the server gave up on a slow answer

    def log_message(self, *args):
        pass


def sgid(secret, user):
    key = hashlib.pbkdf2_hmac("sha256", secret.encode(), b"signed_global_ids", 1000, 64)
    envelope = json.dumps({"_rails": {"data": f"gid://campfire/User/{user}?expires_in", "pur": "attachable"}},
                          separators=(",", ":"))
    data = base64.urlsafe_b64encode(envelope.encode()).decode()
    return data + "--" + hmac.new(key, data.encode(), hashlib.sha1).hexdigest()


def mention(token):
    return (f'<action-text-attachment sgid="{token}" content-type="application/vnd.campfire.mention" '
            'content="&lt;span class=&quot;mention&quot;&gt;x&lt;/span&gt;"></action-text-attachment>')


def main():
    executable = Path(sys.argv[1]).resolve()
    receiver = Receiver()
    threading.Thread(target=receiver.serve_forever, daemon=True).start()
    hooks = f"http://127.0.0.1:{receiver.server_address[1]}"
    with tempfile.TemporaryDirectory(prefix="campfire-webhooks-") as temporary:
        work = Path(temporary)
        database = work / "production.sqlite3"
        with socket.socket() as available:
            available.bind(("127.0.0.1", 0))
            port = available.getsockname()[1]
        secret = secrets.token_hex(64)
        environment = dict(os.environ, DATABASE_PATH=str(database), HTTP_PORT=str(port), SECRET_KEY_BASE=secret,
                           STORAGE_PATH=str(work / "files"))
        log_path = work / "server.log"
        with log_path.open("w+") as log:
            server = subprocess.Popen([str(executable)], env=environment, stdout=log, stderr=log)
            sockets = []

            def request(path, fields=None, cookie="", raw=None):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
                body = raw if raw is not None else (None if fields is None else urlencode(fields))
                conn.request("GET" if body is None else "POST", path, body,
                             {"Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded"})
                response = conn.getresponse()
                result = response.status, {k.lower(): v for k, v in response.getheaders()}, response.read().decode()
                conn.close()
                return result

            def rows(query, *args):
                with sqlite3.connect(database) as db:
                    return db.execute(query, args).fetchall()

            def bot_attachments(bot):
                return rows("SELECT m.room_id,b.filename,b.content_type,b.key FROM messages m JOIN active_storage_attachments a "
                            "ON a.record_type='Message' AND a.name='attachment' AND a.record_id=m.id JOIN active_storage_blobs b "
                            "ON b.id=a.blob_id WHERE m.creator_id=? ORDER BY m.id", bot)

            def blob_bytes(key):
                return (work / "files" / key[:2] / key[2:4] / key).read_bytes()

            def bot_messages(bot):
                return rows("SELECT m.room_id,t.body FROM messages m JOIN action_text_rich_texts t ON t.record_id=m.id "
                            "AND t.record_type='Message' WHERE m.creator_id=? ORDER BY m.id", bot)

            def wait_for(check, timeout=15):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    value = check()
                    if value:
                        return value
                    time.sleep(0.05)
                raise AssertionError("timed out")

            def stream(room, cookie):
                page = request(f"/rooms/{room}", cookie=cookie)[2]
                tag = next(tag for tag in re.findall(r"<turbo-cable-stream-source[^>]+>", page) if 'channel="RoomMessagesChannel"' in tag)
                signed = html.unescape(re.search(r'signed-stream-name="([^"]+)"', tag)[1])
                return json.dumps({"channel": "RoomMessagesChannel", "signed_stream_name": signed})

            try:
                for _ in range(100):
                    try:
                        if request("/up")[0] == 200:
                            break
                    except OSError:
                        time.sleep(.05)
                status, headers, _ = request("/first_run", {"user[name]": "Webhook tester", "user[email_address]": "hooks@example.test",
                                                            "user[password]": "test password"})
                assert status == 302
                cookie = headers["set-cookie"].split(";", 1)[0]

                # Bots and their webhook URLs, through the account forms.
                names = {"echo": ("Echo bot", f"{hooks}/reply"), "direct": ("Direct bot", f"{hooks}/html"),
                         "slow": ("Slow bot", f"{hooks}/slow"), "broken": ("Broken bot", f"{hooks}/error"),
                         "closed": ("Closed bot", "http://127.0.0.1:9/hook/5"), "json": ("Json bot", f"{hooks}/json"),
                         "empty": ("Empty bot", f"{hooks}/empty"), "png": ("Png bot", f"{hooks}/png"),
                         "stream": ("Stream bot", f"{hooks}/stream"), "invalid": ("Invalid bot", f"{hooks}/invalid"),
                         "video": ("Video bot", f"{hooks}/avi"),
                         "silent": ("Silent bot", "")}
                bots = {}
                for label, (name, url) in names.items():
                    assert request("/account/bots", {"user[name]": name, "user[webhook_url]": url}, cookie)[0] == 303
                    bots[label] = rows("SELECT id FROM users WHERE name=? AND role=2", name)[0][0]
                    assert rows("SELECT url FROM webhooks WHERE user_id=?", bots[label]) == ([(url,)] if url else [])
                echo = bots["echo"]
                form = request(f"/account/bots/{echo}/edit", cookie=cookie)[2]
                assert f'value="{hooks}/reply"' in form and 'name="user[webhook_url]"' in form
                assert request(f"/account/bots/{bots['silent']}", {"user[name]": "Silent bot", "user[webhook_url]": f"{hooks}/reply"}, cookie)[0] == 303
                assert rows("SELECT url FROM webhooks WHERE user_id=?", bots["silent"]) == [(f"{hooks}/reply",)]
                assert request(f"/account/bots/{bots['silent']}", {"user[name]": "Silent bot", "user[webhook_url]": " "}, cookie)[0] == 303
                assert rows("SELECT count(*) FROM webhooks WHERE user_id=?", bots["silent"]) == [(0,)]
                token = rows("SELECT bot_token FROM users WHERE id=?", echo)[0][0]
                listing = request("/account/bots", cookie=cookie)[2]
                assert f"/rooms/1/{echo}-{token}/messages" in listing
                print("PASS: bot forms store, change and delete webhook URLs; bot keys are <id>-<token>")

                # Both bot key forms post as the bot; bot posts mentioning nobody deliver no webhook.
                assert request(f"/rooms/1/{echo}-{token}/messages", raw="Posted by key")[0] == 201
                assert request(f"/rooms/1/{token}/messages", raw="Posted by token")[0] == 201
                assert request(f"/rooms/1/{echo}-{token[:-1]}x/messages", raw="Wrong key")[0] != 201
                assert [body for _, body in bot_messages(echo)] == ["Posted by key", "Posted by token"]

                # The mentions prompt lists the room's users, bots included, with their attachable SGIDs.
                prompt = request(f"/autocompletable/users?room_id=1&filter={quote('Echo')}", cookie=cookie)
                assert prompt[0] == 200 and prompt[1]["content-type"].startswith("text/html"), prompt[:2]
                assert prompt[2].count("<lexxy-prompt-item") == 1 and f'sgid="{sgid(secret, echo)}"' in prompt[2], prompt[2]
                assert request("/autocompletable/users?room_id=999", cookie=cookie)[0] == 404
                print("PASS: the mentions prompt signs SGIDs as Rails does")

                live = WebSocket(port, cookie)
                sockets.append(live)
                assert live.subscribe(stream(1, cookie)) == "confirm_subscription"

                # A message mentioning a bot: the payload, then the reply in the database and live.
                body = f"<p>Hi {mention(sgid(secret, echo))} how are you? &lt;3</p>"
                started = time.monotonic()
                status, _, posted = request("/rooms/1/messages", {"message[body]": body, "message[client_message_id]": "mention-1"}, cookie)
                assert status == 200 and 'class="mention"' in posted, posted
                assert time.monotonic() - started < 2
                message = rows("SELECT id FROM messages WHERE client_message_id='mention-1'")[0][0]
                stored = rows("SELECT body FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?", message)[0][0]
                assert stored == (f'<p>Hi <action-text-attachment sgid="{sgid(secret, echo)}" '
                                  'content-type="application/vnd.campfire.mention"></action-text-attachment> how are you? &lt;3</p>'), stored
                assert rows("SELECT body FROM message_search_index WHERE rowid=?", message) == [("Hi @Echo bot how are you? <3",)]
                delivery = receiver.wait("/reply")[0]
                assert delivery["headers"]["Content-Type"] == "application/json"
                assert delivery["json"] == {
                    "user": {"id": 1, "name": "Webhook tester"},
                    "room": {"id": 1, "name": "All Talk", "path": f"/rooms/1/{echo}-{token}/messages"},
                    "message": {"id": message, "body": {"html": stored, "plain": "Hi  how are you? <3"}, "path": f"/rooms/1/@{message}"},
                }, delivery["json"]
                assert list(delivery["json"]) == ["user", "room", "message"]
                assert b"\\u003cp\\u003eHi \\u003caction-text-attachment" in delivery["raw"], delivery["raw"]
                reply = live.publication("Pong")
                assert "<b>bold</b> &amp; more" in reply and "Echo bot" in reply, reply
                assert wait_for(lambda: bot_messages(echo)[2:]) == [(1, "Pong <b>bold</b> &amp; more")]
                print("PASS: a mention delivers the Rails payload and the text reply is stored and published")

                # A direct room with a bot: every message goes to it, and an HTML reply is sanitized.
                with sqlite3.connect(database) as db:
                    now = "2026-11-01 00:00:00.000000"
                    direct = db.execute("INSERT INTO rooms(type,creator_id,created_at,updated_at) VALUES('Rooms::Direct',1,?,?)", (now, now)).lastrowid
                    for user in (1, bots["direct"]):
                        db.execute("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,'everything',?,?)", (direct, user, now, now))
                direct_live = WebSocket(port, cookie)
                sockets.append(direct_live)
                assert direct_live.subscribe(stream(direct, cookie)) == "confirm_subscription"
                assert request(f"/rooms/{direct}/messages", {"message[body]": "Hello direct", "message[client_message_id]": "direct-1"}, cookie)[0] == 200
                payload = receiver.wait("/html")[0]["json"]
                direct_token = rows("SELECT bot_token FROM users WHERE id=?", bots["direct"])[0][0]
                assert payload["room"] == {"id": direct, "name": None, "path": f"/rooms/{direct}/{bots['direct']}-{direct_token}/messages"}, payload
                assert payload["message"]["body"] == {"html": "Hello direct", "plain": "Hello direct"}
                reply = direct_live.publication("Direct")
                assert "<em>reply</em>" in reply and "<script>" not in reply, reply
                assert wait_for(lambda: bot_messages(bots["direct"])) == [(direct, "<p>Direct <em>reply</em></p>")]
                # A message another bot posts through the bot API reaches the direct room's bot too.
                with sqlite3.connect(database) as db:
                    db.execute("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,'everything',?,?)", (direct, echo, now, now))
                assert request(f"/rooms/{direct}/{echo}-{token}/messages", raw="Bot to bot")[0] == 201
                bot_delivery = receiver.wait("/html", 2)[1]["json"]
                assert bot_delivery["user"] == {"id": echo, "name": "Echo bot"} and bot_delivery["message"]["body"]["plain"] == "Bot to bot", bot_delivery
                assert wait_for(lambda: bot_messages(bots["direct"])[1:]) == [(direct, "<p>Direct <em>reply</em></p>")]
                # An uploaded file has no rich text: the payload's plain text is its filename (plain_text_body).
                # The echo bot, a member too, gets it as well.
                echoes = len(receiver.of("/reply"))
                body, kind = multipart([("message[attachment]", ("notes v2.txt", "text/plain", b"some notes")),
                                        ("message[client_message_id]", "direct-file")])
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
                conn.request("POST", f"/rooms/{direct}/messages", body, {"Cookie": cookie, "Content-Type": kind, "Accept": "text/vnd.turbo-stream.html"})
                response = conn.getresponse(); response.read(); conn.close()
                assert response.status == 200, response.status
                file_delivery = receiver.wait("/html", 3)[2]["json"]
                assert file_delivery["message"]["body"] == {"html": None, "plain": "notes v2.txt"}, file_delivery
                assert receiver.wait("/reply", echoes + 1)[-1]["json"]["message"]["body"]["plain"] == "notes v2.txt"
                print("PASS: a direct room's bot gets every message, a bot API post included, and its HTML reply is sanitized, stored and published")

                # Messages that mention no bot, or only their own creator, deliver nothing.
                before = len(receiver.requests)
                assert request("/rooms/1/messages", {"message[body]": "Plain message", "message[client_message_id]": "plain-1"}, cookie)[0] == 200
                assert request("/rooms/1/messages", {"message[body]": f"Me {mention(sgid(secret, 1))}", "message[client_message_id]": "self-1"}, cookie)[0] == 200
                forged = sgid(secret + "x", echo)
                assert request("/rooms/1/messages", {"message[body]": f"Forged {mention(forged)}", "message[client_message_id]": "forged-1"}, cookie)[0] == 200

                # A slow endpoint never holds the POST; after 7 seconds the bot says so.
                started = time.monotonic()
                assert request("/rooms/1/messages", {"message[body]": f"Wake {mention(sgid(secret, bots['slow']))}", "message[client_message_id]": "slow-1"}, cookie)[0] == 200
                assert time.monotonic() - started < 2
                slow_sent = receiver.wait("/slow")[0]["at"]
                # Failing endpoints, a closed port, a JSON answer and an empty one never delay posts. As in Rails, any
                # answer but a 200 text one is an attachment reply, whatever its status; an empty text answer posts an empty message.
                failing = " ".join(mention(sgid(secret, bots[label])) for label in ("broken", "closed", "json", "empty"))
                started = time.monotonic()
                assert request("/rooms/1/messages", {"message[body]": f"Fail {failing}", "message[client_message_id]": "fail-1"}, cookie)[0] == 200
                assert time.monotonic() - started < 2
                receiver.wait("/error"); receiver.wait("/json"); receiver.wait("/empty")
                for i in range(50):
                    assert request("/rooms/1/messages", {"message[body]": f"Load {i}", "message[client_message_id]": f"load-{i}"}, cookie)[0] == 200
                assert time.monotonic() - started < 10
                timed_out = live.publication("Failed to respond within 7 seconds", timeout=20)
                assert "Slow bot" in timed_out
                assert 6.5 < time.monotonic() - slow_sent < 12
                assert bot_messages(bots["slow"]) == [(1, "Failed to respond within 7 seconds")]
                time.sleep(2.5)  # the slow endpoint's late answer arrives and is ignored
                for label in ("broken", "closed", "json"):
                    assert bot_messages(bots[label]) == [], label
                assert bot_messages(bots["empty"]) == [(1, "")]
                for label in ("closed", "empty"):
                    assert bot_attachments(bots[label]) == [], label
                [(room, name, kind, key)] = bot_attachments(bots["broken"])
                assert (room, name, kind, blob_bytes(key)) == (1, "attachment.text", "text/plain", b"boom")
                [(room, name, kind, key)] = bot_attachments(bots["json"])
                assert (room, name, kind, blob_bytes(key)) == (1, "attachment.json", "application/json", b'{"reply":"no"}')
                assert bot_messages(bots["slow"]) == [(1, "Failed to respond within 7 seconds")]
                paths = [r["path"] for r in receiver.requests[before:]]
                assert sorted(paths) == ["/empty", "/error", "/json", "/slow"], paths
                assert request("/up")[0] == 200 and server.poll() is None
                log.flush()
                text = log_path.read_text()
                assert f"Bot webhook for bot {bots['closed']}" in text and "error 111" in text, text
                print("PASS: slow, failing and closed endpoints never delay posts; a timeout replies as Rails does")

                # Attachment replies: an image is stored, published and thumbnailed; an unregistered type is named
                # "attachment."; an invalid type posts nothing.
                replying = " ".join(mention(sgid(secret, bots[label])) for label in ("png", "stream", "invalid"))
                assert request("/rooms/1/messages", {"message[body]": f"Files {replying}", "message[client_message_id]": "files-1"}, cookie)[0] == 200
                published = live.publication("attachment.png")
                assert "Png bot" in published and "message__attachment" in published, published
                [(room, name, kind, key)] = wait_for(lambda: bot_attachments(bots["png"]))
                assert (room, name, kind, blob_bytes(key)) == (1, "attachment.png", "image/png", png(40, 30))
                assert rows("SELECT body FROM message_search_index WHERE rowid=(SELECT max(id) FROM messages WHERE creator_id=?)", bots["png"]) == [("attachment.png",)]
                assert wait_for(lambda: rows("SELECT count(*) FROM active_storage_variant_records v JOIN active_storage_blobs b ON b.id=v.blob_id WHERE b.key=?", key)[0][0])
                [(room, name, kind, key)] = wait_for(lambda: bot_attachments(bots["stream"]))
                assert (room, name, kind, blob_bytes(key)) == (1, "attachment.", "application/octet-stream", b"\x00\x01binary")
                receiver.wait("/invalid")
                time.sleep(1)
                assert bot_attachments(bots["invalid"]) == [] and bot_messages(bots["invalid"]) == []
                log.flush()
                assert f"Bot webhook for bot {bots['invalid']}" in log_path.read_text() and "invalid media type image" in log_path.read_text()
                print("PASS: attachment replies are stored, published and thumbnailed as Rails names and types them; an invalid type posts nothing")

                # A video reply is analyzed and previewed (create_with_attachment!) before it is published, so its
                # broadcast already has the video's size.
                assert request("/rooms/1/messages", {"message[body]": f"Clip {mention(sgid(secret, bots['video']))}", "message[client_message_id]": "clip-1"}, cookie)[0] == 200
                published = live.publication("<video ")
                assert 'style="width: 32.0px; aspect-ratio: 1.7777777777777777;"><video ' in published, published
                [(room, name, kind, key)] = bot_attachments(bots["video"])
                assert (room, name, kind) == (1, "attachment.", "video/x-msvideo"), (name, kind)
                assert rows("SELECT metadata FROM active_storage_blobs WHERE key=?", key) == [('{"identified":true,"width":64.0,"height":36.0,"duration":0.3,"display_aspect_ratio":[16,9],"audio":false,"video":true,"analyzed":true}',)]
                assert rows("SELECT p.filename FROM active_storage_blobs b JOIN active_storage_attachments a ON a.record_type='ActiveStorage::Blob' AND a.name='preview_image' AND a.record_id=b.id JOIN active_storage_blobs p ON p.id=a.blob_id WHERE b.key=?", key) == [("attachment.jpg",)]
                print("PASS: a video reply is analyzed and previewed before it is published")
            except BaseException:
                log.flush()
                print(log_path.read_text()[-4000:], file=sys.stderr)
                raise
            finally:
                for connection in sockets:
                    connection.close()
                server.terminate()
                server.wait(timeout=10)
                receiver.shutdown()


if __name__ == "__main__":
    main()
