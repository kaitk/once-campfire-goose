#!/usr/bin/env python3
"""Boosts, the bot API, room involvement/settings/destroy, closed rooms, user pages and clearing searches:
statuses, authorization, persisted writes, rollback and the live turbo-stream broadcasts."""
import gzip
import html
import http.client
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
import time
from urllib.parse import urlencode


class WebSocket:
    def __init__(self, port, cookie):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=15)
        self.sock.sendall((f"GET /cable HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\n"
                           f"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nOrigin: http://127.0.0.1:{port}\r\nCookie: {cookie}\r\n\r\n").encode())
        head = b""
        while not head.endswith(b"\r\n\r\n"):
            head += self.take(1)
        assert head.startswith(b"HTTP/1.1 101"), head
        assert self.receive()["type"] == "welcome"
        self.skipped = []

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
            message = self.receive()
            body = message.get("message")
            if isinstance(body, str) and all(needle in body for needle in needles):
                return body
            if isinstance(body, str):
                self.skipped.append(body)
        raise TimeoutError(f"no publication with {needles}")


def stream_identifiers(page):
    found = {}
    for tag in re.findall(r"<turbo-cable-stream-source[^>]+>", page):
        channel = re.search(r'channel="([^"]+)"', tag)[1]
        signed = html.unescape(re.search(r'signed-stream-name="([^"]+)"', tag)[1])
        found.setdefault(channel, []).append(json.dumps({"channel": channel, "signed_stream_name": signed}))
    return found


binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="campfire-routes-") as directory:
    work = Path(directory)
    database = work / "production.sqlite3"
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = dict(os.environ, DATABASE_PATH=str(database), SECRET_KEY_BASE=secrets.token_hex(64), HTTP_PORT=str(port))
    base = f"http://127.0.0.1:{port}"
    with (work / "server.log").open("w+") as log:
        server = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        sockets = []

        def request(path, data=None, cookie="", method=None, headers=None, raw=False):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
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

        def execute(sql, *args):
            with sqlite3.connect(database, timeout=10) as db:
                db.execute(sql, args)

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
            assert status == 302
            admin = headers["set-cookie"].split(";", 1)[0]
            code = query("SELECT join_code FROM accounts")[0][0]
            status, headers, _ = request(f"/join/{code}", {"user[name]": "Bob Member", "user[email_address]": "bob@example.test", "user[password]": "member password"})
            assert status == 302
            member = headers["set-cookie"].split(";", 1)[0]
            admin_id, member_id = (query("SELECT id FROM users WHERE email_address=?", email)[0][0] for email in ("ada@example.test", "bob@example.test"))
            room = 1
            status, _, body = request(f"/rooms/{room}/messages", {"message[body]": "Boost me", "message[client_message_id]": "route-test-1"}, admin)
            assert status == 200
            message = query("SELECT id FROM messages WHERE client_message_id='route-test-1'")[0][0]

            # Live readers: the member's room stream and both of their sidebar streams.
            # Action Cable's allow_request_origin?: an upgrade without this server's Origin is refused with 404.
            for origin in ("", "Origin: http://evil.test\r\n", "Origin: https://127.0.0.1:%d\r\n" % port):
                with socket.create_connection(("127.0.0.1", port), timeout=10) as raw:
                    raw.sendall((f"GET /cable HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n{origin}Upgrade: websocket\r\nConnection: Upgrade\r\n"
                                 f"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nCookie: {member}\r\n\r\n").encode())
                    answer = raw.recv(4096)
                    assert answer.startswith(b"HTTP/1.1 404") and answer.endswith(b"Page not found"), (origin, answer)
            reader = WebSocket(port, member)
            sockets.append(reader)
            room_page = request(f"/rooms/{room}", cookie=member)[2]
            # Without VAPID keys, tag.meta leaves out the nil content, as Rails' layout does.
            assert '<meta name="vapid-public-key">' in room_page, room_page[:600]
            reader.subscribe(stream_identifiers(room_page)["RoomMessagesChannel"][0])
            for identifier in stream_identifiers(request("/users/me/sidebar", cookie=member)[2])["Turbo::StreamsChannel"]:
                reader.subscribe(identifier)
            # The administrator's sidebar streams, which must not carry the member's own or other rooms' changes.
            watcher = WebSocket(port, admin)
            sockets.append(watcher)
            for identifier in stream_identifiers(request("/users/me/sidebar", cookie=admin)[2])["Turbo::StreamsChannel"]:
                watcher.subscribe(identifier)

            # Boosts: index and new pages, frames for Turbo-Frame requests.
            status, headers, body = request(f"/messages/{message}/boosts", cookie=member)
            assert status == 200 and body.startswith("<!DOCTYPE html>") and f'id="boosting_message_{message}"' in body, (status, body[:300])
            assert f'href="/messages/{message}/boosts/new"' in body
            status, _, body = request(f"/messages/{message}/boosts/new", cookie=member, headers={"Turbo-Frame": f"new_boost_message_{message}"})
            assert status == 200 and body.startswith("<html>") and f'id="new_boost_message_{message}"' in body
            assert 'name="boost[content]"' in body and f'action="/messages/{message}/boosts"' in body and "Bob Member" in body
            assert request(f"/messages/{message}/boosts")[0] == 302
            assert request(f"/messages/999999/boosts", cookie=member)[0] == 404
            before = query("SELECT updated_at FROM messages WHERE id=?", message)[0][0]
            cached = request(f"/rooms/{room}", cookie=admin)[2]
            assert "boost_" not in cached.split(f'id="boosts_message_{message}"')[1].split("</div>")[0]
            assert request(f"/messages/{message}/boosts", {"boost[content]": "👍"}, member, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
            assert request(f"/messages/{message}/boosts", {"other": "x"}, member)[0] == 400
            assert query("SELECT count(*) FROM boosts")[0][0] == 0
            status, headers, _ = request(f"/messages/{message}/boosts", {"boost[content]": "👍"}, member)
            assert status == 302 and headers["location"] == f"{base}/messages/{message}/boosts", (status, headers)
            boost, content, booster = query("SELECT id,content,booster_id FROM boosts WHERE message_id=?", message)[0]
            assert (content, booster) == ("👍", member_id)
            assert query("SELECT updated_at FROM messages WHERE id=?", message)[0][0] > before
            published = reader.expect('action="append"', f'target="boosts_message_{message}"')
            assert f'id="boost_{boost}"' in published and 'maintain_scroll="true"' in published and "👍" in published
            body = request(f"/rooms/{room}", cookie=admin)[2]
            assert f'id="boost_{boost}"' in body, "a write must clear the cached room page"
            body = request(f"/messages/{message}/boosts", cookie=admin, headers={"Turbo-Frame": f"boosting_message_{message}"})[2]
            assert f'id="boost_{boost}"' in body and f'data-boost-delete-booster-id-value="{member_id}"' in body
            assert request(f"/messages/{message}/boosts/{boost}", {"_method": "delete"}, admin)[0] == 404
            assert request(f"/messages/{message}/boosts/{boost}", cookie=member)[0] == 404
            assert request(f"/messages/{message}/boosts/{boost}", {"_method": "patch", "boost[content]": "x"}, member)[0] == 404
            # A failed write rolls back the boost and the touches.
            execute("CREATE TRIGGER fail_boost BEFORE INSERT ON boosts BEGIN SELECT RAISE(ABORT,'test rollback'); END")
            touched = query("SELECT updated_at FROM messages WHERE id=?", message)[0][0]
            assert request(f"/messages/{message}/boosts", {"boost[content]": "🔥"}, admin)[0] == 500
            assert query("SELECT count(*) FROM boosts")[0][0] == 1
            assert query("SELECT updated_at FROM messages WHERE id=?", message)[0][0] == touched
            execute("DROP TRIGGER fail_boost")
            status, _, body = request(f"/messages/{message}/boosts/{boost}", {"_method": "delete"}, member)
            assert status == 204 and body == ""
            assert query("SELECT count(*) FROM boosts")[0][0] == 0
            assert reader.expect(f'<turbo-stream action="remove" target="boost_{boost}">')
            print("PASS: boost pages, frames, create/destroy with live append/remove, booster-only deletion, origin checks, rollback and cache invalidation")

            # Involvement: the bell's frame cycles through the levels; invisibility leaves and rejoins the sidebar.
            status, _, body = request(f"/rooms/{room}/involvement", cookie=member, headers={"Turbo-Frame": f"involvement_rooms_open_{room}"})
            assert status == 200 and f'id="involvement_rooms_open_{room}"' in body
            assert f'action="/rooms/{room}/involvement?involvement=everything"' in body and 'class="btn mentions"' in body
            status, headers, _ = request(f"/rooms/{room}/involvement?involvement=everything", {"_method": "put"}, member)
            assert status == 302 and headers["location"] == f"{base}/rooms/{room}/involvement"
            assert query("SELECT involvement FROM memberships WHERE room_id=? AND user_id=?", room, member_id)[0][0] == "everything"
            assert 'class="btn everything"' in request(f"/rooms/{room}/involvement", cookie=member)[2]
            assert request(f"/rooms/{room}/involvement?involvement=invisible", method="PUT", cookie=member, headers={"Content-Length": "0"})[0] == 302
            assert reader.expect(f'<turbo-stream action="remove" target="list_rooms_open_{room}">')
            assert "All Talk" not in request("/users/me/sidebar", cookie=member)[2].split('id="shared_rooms"')[1]
            assert request(f"/rooms/{room}/involvement", {"_method": "put", "involvement": "mentions"}, member)[0] == 302
            assert 'id="list_rooms_open_1"' in reader.expect('action="prepend"', 'target="shared_rooms"')
            assert request(f"/rooms/{room}/involvement?involvement=bogus", {"_method": "put"}, member)[0] == 500
            assert request(f"/rooms/{room}/involvement?involvement=nothing", {"_method": "put"}, member, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
            assert query("SELECT involvement FROM memberships WHERE room_id=? AND user_id=?", room, member_id)[0][0] == "mentions"
            assert request(f"/rooms/{room}/settings", cookie=member)[0] == 500
            print("PASS: involvement frame and updates, sidebar remove/prepend on the user's stream, invalid values and origin checks")

            # Closed rooms.
            status, _, body = request("/rooms/closeds/new", cookie=member)
            assert status == 200 and "<title>New chat room</title>" in body and 'value="New room"' in body
            assert f'<input type="hidden" name="user_ids[]" value="{member_id}" />' in body and f'name="user_ids[]" value="{admin_id}"' in body
            execute("UPDATE accounts SET settings='{\"restrict_room_creation_to_administrators\":true}'")
            assert request("/rooms/closeds/new", cookie=member)[0] == 403
            assert request("/rooms/closeds", {"room[name]": "Denied", "user_ids[]": [member_id]}, member)[0] == 403
            assert request("/rooms/closeds/new", cookie=admin)[0] == 200
            execute("UPDATE accounts SET settings='{}'")
            assert request("/rooms/closeds", {"user_ids[]": [member_id]}, member)[0] == 400
            status, headers, _ = request("/rooms/closeds", {"room[name]": "Secret <club>", "user_ids[]": [member_id, 999999]}, member)
            assert status == 302
            closed = query("SELECT id FROM rooms WHERE name='Secret <club>' AND type='Rooms::Closed'")[0][0]
            assert headers["location"] == f"{base}/rooms/{closed}"
            assert query("SELECT user_id,involvement FROM memberships WHERE room_id=?", closed) == [(member_id, "mentions")]
            assert f'id="list_rooms_closed_{closed}"' in reader.expect('action="prepend"', "Secret &lt;club&gt;")
            status, headers, _ = request(f"/rooms/closeds/{closed}", cookie=member)
            assert status == 302 and headers["location"] == f"{base}/rooms/{closed}" and f"last_room={closed}" in headers["set-cookie"]
            assert request(f"/rooms/closeds/{closed}", cookie=admin)[2] == "Redirecting" and request(f"/rooms/closeds/{closed}", cookie=admin)[1]["location"] == f"{base}/"
            assert request(f"/rooms/{closed}", cookie=admin)[1]["location"] == f"{base}/"
            status, _, body = request(f"/rooms/closeds/{closed}/edit", cookie=member)
            assert status == 200 and "Edit settings for Secret &lt;club&gt;" in body and 'name="_method" value="patch"' in body
            assert f'value="{member_id}" class="switch__input" checked="checked"' in body and f'action="{base}/rooms/{closed}"' in body
            status, headers, _ = request(f"/rooms/closeds/{closed}", {"_method": "patch", "room[name]": "Renamed club", "user_ids[]": [member_id, admin_id]}, member)
            assert status == 302 and headers["location"] == f"{base}/rooms/{closed}"
            assert sorted(query("SELECT user_id FROM memberships WHERE room_id=?", closed)) == sorted([(member_id,), (admin_id,)])
            assert 'Renamed club' in reader.expect('action="replace"', f'target="list_rooms_closed_{closed}"')
            assert request(f"/rooms/{closed}", cookie=admin)[0] == 200
            status, headers, _ = request("/rooms/closeds", {"room[name]": "Admin club", "user_ids[]": [admin_id, member_id]}, admin)
            admin_closed = int(headers["location"].rsplit("/", 1)[1])
            assert f'id="list_rooms_closed_{admin_closed}"' in watcher.expect('action="prepend"', "Admin club")
            assert not [body for body in watcher.skipped if "Secret" in body or "list_rooms_open_1" in body], watcher.skipped
            assert [body for body in watcher.skipped if "Renamed club" in body], "a granted member receives the update"
            body = request(f"/rooms/closeds/{admin_closed}/edit", cookie=member)[2]
            assert 'name="room[name]"' not in body and "user_ids[]" not in body and 'name="_method" value="delete"' not in body
            assert request(f"/rooms/closeds/{admin_closed}", {"_method": "patch", "room[name]": "Nope"}, member)[0] == 403
            assert request(f"/rooms/closeds/{closed}", {"_method": "patch"}, member)[0] == 400
            assert query("SELECT name FROM rooms WHERE id=?", admin_closed)[0][0] == "Admin club"
            print("PASS: closed room new/create/show/edit/update, creation restriction, grants and revocations, member-only broadcasts and admin rules")

            # Destroying a room: members only, its creator or an administrator.
            assert request(f"/rooms/{admin_closed}", {"_method": "delete"}, member)[0] == 403
            request(f"/rooms/{closed}/messages", {"message[body]": "Doomed", "message[client_message_id]": "doomed-1"}, member)
            doomed = query("SELECT id FROM messages WHERE client_message_id='doomed-1'")[0][0]
            assert request(f"/messages/{doomed}/boosts", {"boost[content]": "bye"}, admin)[0] == 302
            assert request(f"/rooms/{closed}", {"_method": "delete"}, member, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
            status, headers, _ = request(f"/rooms/{closed}", {"_method": "delete"}, member)
            assert status == 302 and headers["location"] == f"{base}/"
            assert reader.expect(f'<turbo-stream action="remove" target="list_rooms_closed_{closed}">')
            # Room#destroy_later takes the memberships at once; Room::DestroyJob deletes the messages, then the room.
            assert query("SELECT count(*) FROM memberships WHERE room_id=?", closed)[0][0] == 0
            for _ in range(200):
                if query("SELECT count(*) FROM rooms WHERE id=?", closed)[0][0] == 0: break
                time.sleep(.05)
            for table, column in (("rooms", "id"), ("memberships", "room_id"), ("messages", "room_id")):
                assert query(f"SELECT count(*) FROM {table} WHERE {column}=?", closed)[0][0] == 0
            assert query("SELECT count(*) FROM boosts WHERE message_id=?", doomed)[0][0] == 0
            assert query("SELECT count(*) FROM message_search_index WHERE rowid=?", doomed)[0][0] == 0
            assert request(f"/rooms/{closed}", {"_method": "delete"}, member)[1]["location"] == f"{base}/"
            assert request(f"/rooms/{admin_closed}", method="DELETE", cookie=admin, headers={"Content-Length": "0"})[0] == 302
            for _ in range(200):
                if query("SELECT count(*) FROM rooms WHERE id=?", admin_closed)[0][0] == 0: break
                time.sleep(.05)
            # Room::DestroyJob reset the former members' connections; the browser connects again.
            reader.sock.settimeout(15)
            try:
                while True: reader.receive()
            except (AssertionError, OSError, ValueError): pass
            reader = WebSocket(port, member)
            sockets.append(reader)
            reader.subscribe(stream_identifiers(request(f"/rooms/{room}", cookie=member)[2])["RoomMessagesChannel"][0])
            for identifier in stream_identifiers(request("/users/me/sidebar", cookie=member)[2])["Turbo::StreamsChannel"]:
                reader.subscribe(identifier)
            print("PASS: room destroy authorization, cascading deletion and live sidebar removal")

            # User pages and clearing searches.
            status, _, body = request(f"/users/{admin_id}", cookie=member)
            assert status == 200 and "<title>Ada Admin</title>" in body and "mailto:" not in body and "/users/me/profile" not in body
            assert f'action="/rooms/directs?user_ids%5B%5D={admin_id}"' in body and "/ban" not in body
            status, _, body = request(f"/users/{member_id}", cookie=admin)
            assert status == 200 and 'href="mailto:bob@example.test"' in body and f'action="/users/{member_id}/ban"' in body
            assert "/session/transfers/" in body and "Share to get them back into their account" in body
            assert '/users/me/profile' in request(f"/users/{admin_id}", cookie=admin)[2]
            assert request("/users/999999", cookie=member)[0] == 404
            assert request(f"/users/{admin_id}")[0] == 302
            status, headers, _ = request(f"/rooms/directs?user_ids%5B%5D={admin_id}", {}, member)
            assert status == 302
            execute("INSERT INTO searches(user_id,query,created_at,updated_at) VALUES (?,'one','2026-01-01','2026-01-01'),(?,'two','2026-01-01','2026-01-01'),(?,'kept','2026-01-01','2026-01-01')", member_id, member_id, admin_id)
            assert request("/searches/clear", {"_method": "delete"}, member, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
            assert request("/searches/clear", cookie=member)[0] == 404
            status, headers, _ = request("/searches/clear", {"_method": "delete"}, member)
            assert status == 302 and headers["location"] == f"{base}/searches"
            assert query("SELECT user_id,query FROM searches") == [(admin_id, "kept")]
            assert request("/searches/clear", method="DELETE", cookie=admin, headers={"Content-Length": "0"})[0] == 302
            # Rack::MethodOverride: `_method` in a multipart body, else X-HTTP-Method-Override, when it names an HTTP method.
            execute("INSERT INTO searches(user_id,query,created_at,updated_at) VALUES (?,'one','2026-01-01','2026-01-01')", member_id)
            boundary = "----override"
            multipart = f"--{boundary}\r\nContent-Disposition: form-data; name=\"_method\"\r\n\r\ndelete\r\n--{boundary}--\r\n"
            assert request("/searches/clear", multipart, member, raw=True, headers={"Content-Type": f"multipart/form-data; boundary={boundary}", "Sec-Fetch-Site": "same-origin"})[0] == 302
            assert query("SELECT count(*) FROM searches")[0][0] == 0
            execute("INSERT INTO searches(user_id,query,created_at,updated_at) VALUES (?,'two','2026-01-01','2026-01-01')", member_id)
            assert request("/searches/clear", {"_method": "bogus"}, member)[0] != 302 and query("SELECT count(*) FROM searches")[0][0] == 1
            assert request("/searches/clear", {}, member, headers={"X-HTTP-Method-Override": "DELETE"})[0] == 302
            # set_messages runs before clear, its words quoted for MATCH: an FTS5 operator is searched for as a word.
            execute("INSERT INTO searches(user_id,query,created_at,updated_at) VALUES (?,'three','2026-01-01','2026-01-01')", member_id)
            assert request("/searches/clear?q=AND", {"_method": "delete"}, member)[0] == 302 and query("SELECT count(*) FROM searches")[0][0] == 0
            execute("INSERT INTO searches(user_id,query,created_at,updated_at) VALUES (?,'four','2026-01-01','2026-01-01')", member_id)
            assert request("/searches/clear?q=a-b", {"_method": "delete"}, member)[0] == 302 and query("SELECT count(*) FROM searches")[0][0] == 0
            assert query("SELECT count(*) FROM searches")[0][0] == 0
            assert query("SELECT count(*) FROM searches")[0][0] == 0
            print("PASS: user pages with administrator-only details, direct pings from the page, and clearing only one's own searches")

            # Bot API.
            assert request("/account/bots", {"user[name]": "Route bot"}, admin)[0] == 302
            bot_id, token = query("SELECT id,bot_token FROM users WHERE role=2")[0]
            key = f"{bot_id}-{token}"
            assert f"/rooms/{room}/{key}/messages" in html.unescape(request("/account/bots", cookie=admin)[2])
            text = {"Content-Type": "text/plain"}
            assert request(f"/rooms/{room}/{key}/messages", "   ", raw=True, headers=text)[0] == 422
            status, headers, _ = request(f"/rooms/{room}/{key}/messages", "Hello <from> bot", raw=True, headers=text)
            assert status == 201
            bot_message = query("SELECT id FROM messages WHERE creator_id=?", bot_id)[0][0]
            assert headers["location"] == f"{base}/messages/{bot_message}"
            # The body is HTML: the unknown <from> element and what it holds go when it's rendered, as in Rails.
            reader.expect(f'data-message-id="{bot_message}"', "Hello")
            status, headers, body = request(f"/rooms/{room}/{key}/messages")
            items = json.loads(body)
            assert status == 200 and headers["content-type"].startswith("application/json") and headers["x-total-count"] == "2"
            assert [item["id"] for item in items] == [message, bot_message] and "link" not in headers
            assert items[1]["creator"] == {"id": bot_id, "name": "Route bot", "role": "bot", "avatar_url": items[1]["creator"]["avatar_url"]}
            assert items[1]["creator"]["avatar_url"].startswith(f"{base}/users/") and items[1]["url"] == f"{base}/rooms/{room}/messages/{bot_message}"
            assert items[1]["body"]["plain_text"] == "Hello  bot" and "from" not in items[1]["body"]["html"]
            assert "\\u003c" in body and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z", items[0]["created_at"])
            for i in range(45):
                execute("INSERT INTO messages(room_id,creator_id,client_message_id,created_at,updated_at) VALUES (?,?,?,?,?)",
                        room, admin_id, f"page-{i}", f"2000-01-01 00:00:{i:02}.000000", "2000-01-01 00:00:00")
            status, headers, body = request(f"/rooms/{room}/{key}/messages")
            page = [item["id"] for item in json.loads(body)]
            assert len(page) == 40 and page[-1] == bot_message and headers["x-total-count"] == "47"
            assert headers["link"] == f'<{base}/rooms/{room}/{key}/messages?before={page[0]}>; rel="next"'
            status, headers, body = request(f"/rooms/{room}/{key}/messages?before={page[0]}")
            older = [item["id"] for item in json.loads(body)]
            assert len(older) == 7 and "link" not in headers
            status, headers, body = request(f"/rooms/{room}/{key}/messages?after={older[0]}")
            assert len(json.loads(body)) == 40 and headers["link"].endswith('>; rel="next"') and "?after=" in headers["link"]
            assert request(f"/rooms/{room}/{key}/messages?before=999999")[0] == 404
            status, _, body = request(f"/rooms/{room}/{key}/messages/{bot_message}", "Edited by bot", method="PUT", raw=True, headers=text)
            assert status == 200 and json.loads(body)["body"]["plain_text"] == "Edited by bot"
            assert query("SELECT body FROM message_search_index WHERE rowid=?", bot_message)[0][0] == "Edited by bot"
            reader.expect('action="replace"', "Edited by bot")
            assert request(f"/rooms/{room}/{key}/messages/{message}", "Hijack", method="PATCH", raw=True, headers=text)[0] == 403
            assert query("SELECT body FROM message_search_index WHERE rowid=?", message)[0][0] == "Boost me"
            assert request(f"/rooms/{room}/{key}/messages/999999", "x", method="PATCH", raw=True, headers=text)[0] == 404
            assert request(f"/rooms/{room}/{key}/messages/{message}/boosts", "", raw=True, headers=text)[0] == 422
            status, _, body = request(f"/rooms/{room}/{key}/messages/{message}/boosts", "🎉", raw=True, headers=text)
            bot_boost = json.loads(body)
            assert status == 201 and bot_boost["content"] == "🎉" and bot_boost["booster"]["id"] == bot_id
            assert bot_boost["message"] == {"id": message, "url": f"{base}/rooms/{room}/messages/{message}"}
            reader.expect(f'target="boosts_message_{message}"', "🎉")
            assert request(f"/rooms/{room}/{key}/messages/{message}/boosts/{bot_boost['id']}", method="DELETE")[0] == 204
            assert request(f"/rooms/{room}/{key}/messages/{message}/boosts/{bot_boost['id']}", method="DELETE")[0] == 404
            assert request(f"/rooms/{room}/{key}/messages/{bot_message}", method="DELETE")[0] == 204
            assert query("SELECT count(*) FROM messages WHERE id=?", bot_message)[0][0] == 0
            reader.expect(f'<turbo-stream action="remove" target="message_')
            assert request(f"/rooms/{room}/{bot_id}-wrong/messages")[0] == 302
            assert request(f"/rooms/{room}/{key}/messages", "x", raw=True, headers=text, method="PUT")[0] == 404
            request("/rooms/closeds", {"room[name]": "No bots", "user_ids[]": [admin_id]}, admin)
            botless = query("SELECT id FROM rooms WHERE name='No bots'")[0][0]
            assert request(f"/rooms/{botless}/{key}/messages")[0] == 404
            assert request(f"/rooms/{botless}/{key}/messages", "x", raw=True, headers=text)[0] == 404
            execute("UPDATE users SET status=1 WHERE id=?", bot_id)
            assert request(f"/rooms/{room}/{key}/messages")[0] == 302
            print("PASS: bot API index/pagination/create/update/destroy and boosts, Rails JSON, keys, ownership and room membership")

            # Refresh, as Rooms::RefreshesController renders it: the first 40 messages created since `since`
            # appended, then the last 40 others updated since replaced, in created order.
            ids = []
            for i in range(47):
                assert request(f"/rooms/{room}/messages", {"message[body]": f"Refresh {i:02d}.", "message[client_message_id]": f"refresh-{i}"}, admin)[0] == 200
                ids.append(query("SELECT id FROM messages WHERE client_message_id=?", f"refresh-{i}")[0][0])
            # 0 is an older message edited since; 1 was created 456 microseconds after `since` (new, as in Rails);
            # 2-46 a second apart after it, so 41-46 are past the first page of new messages.
            execute("UPDATE messages SET created_at='2030-12-31 23:59:59.000000', updated_at='2031-01-01 00:01:00.000000' WHERE id=?", ids[0])
            execute("UPDATE messages SET created_at='2031-01-01 00:00:00.500456', updated_at='2031-01-01 00:00:00.500456' WHERE id=?", ids[1])
            for i in range(2, 47):
                at = f"2031-01-01 00:00:{i:02d}.000000"
                execute("UPDATE messages SET created_at=?, updated_at=? WHERE id=?", at, at, ids[i])
            since = 1924992000500  # 2031-01-01 00:00:00.500 UTC
            turbo = {"Accept": "text/vnd.turbo-stream.html"}
            status, headers, body = request(f"/rooms/{room}/refresh?since={since}", cookie=admin, headers=turbo)
            assert status == 200 and headers["content-type"].startswith("text/vnd.turbo-stream.html"), (status, headers)
            appended, rest = body.split("\n</template></turbo-stream>\n", 1)
            assert appended.startswith('<turbo-stream action="append" target="') and '"><template>\n  ' in appended, body[:300]
            assert re.findall(r"Refresh (\d\d)\.", appended) == [f"{i:02d}" for i in range(1, 41)]
            replaces = re.findall(r'  <turbo-stream action="replace" target="[^"]+"><template>.*?</template></turbo-stream>\n', rest, re.S)
            assert "".join(replaces) == rest and len(replaces) == 7, rest[:300]
            for line, i in zip(replaces, [0, 41, 42, 43, 44, 45, 46]):
                assert re.findall(r"Refresh (\d\d)\.", line) == [f"{i:02d}"], line[:200]
            assert request(f"/rooms/{room}/refresh?since=4102444800000", cookie=admin, headers=turbo)[2] == "\n"
            only_edits = request(f"/rooms/{room}/refresh?since=1924992050000", cookie=admin, headers=turbo)[2]
            assert only_edits.startswith("\n  <turbo-stream action=\"replace\"") and re.findall(r"Refresh (\d\d)\.", only_edits) == ["00"], only_edits[:200]
            print("PASS: refresh appends the first 40 new messages and replaces the last 40 other updated ones, as Rails renders them")
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read(), file=sys.stderr)
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
