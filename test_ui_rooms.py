#!/usr/bin/env python3
"""Open room and Ping pages, room creation rules, sidebar broadcasts and autocomplete, as in Rails."""
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

    def quiet(self, *needles, seconds=1.0):
        """True when no publication with every needle arrives within the time."""
        self.sock.settimeout(seconds)
        try:
            while True:
                body = self.receive().get("message")
                if isinstance(body, str) and all(needle in body for needle in needles):
                    return False
        except (socket.timeout, TimeoutError):
            return True
        finally:
            self.sock.settimeout(15)


def stream_identifiers(page):
    found = []
    for tag in re.findall(r"<turbo-cable-stream-source[^>]+>", page):
        signed = html.unescape(re.search(r'signed-stream-name="([^"]+)"', tag)[1])
        found.append(json.dumps({"channel": "Turbo::StreamsChannel", "signed_stream_name": signed}))
    return found


binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="campfire-ui-rooms-") as directory:
    work = Path(directory)
    database = work / "production.sqlite3"
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = dict(os.environ, DATABASE_PATH=str(database), SECRET_KEY_BASE=secrets.token_hex(64), HTTP_PORT=str(port), STORAGE_PATH=str(work / "storage"))
    base = f"http://127.0.0.1:{port}"
    with (work / "server.log").open("w+") as log:
        server = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        sockets = []

        def request(path, data=None, cookie="", method=None, headers=None):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
            fields = {"Host": f"127.0.0.1:{port}", "Accept-Encoding": "gzip"}
            if cookie:
                fields["Cookie"] = cookie
            if data is not None:
                fields.update({"Content-Type": "application/x-www-form-urlencoded", "Sec-Fetch-Site": "same-origin"})
                data = urlencode(data, doseq=True)
            fields.update(headers or {})
            conn.request(method or ("GET" if data is None else "POST"), path, data.encode() if isinstance(data, str) else data, fields)
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

        def join(name, email):
            code = query("SELECT join_code FROM accounts")[0][0]
            status, headers, _ = request(f"/join/{code}", {"user[name]": name, "user[email_address]": email, "user[password]": "member password"})
            assert status == 302, status
            return headers["set-cookie"].split(";", 1)[0], query("SELECT id FROM users WHERE email_address=?", email)[0][0]

        def watch(cookie):
            ws = WebSocket(port, cookie)
            sockets.append(ws)
            for identifier in stream_identifiers(request("/users/me/sidebar", cookie=cookie)[2]):
                ws.subscribe(identifier)
            return ws

        def room_of(headers):
            return int(headers["location"].rsplit("/", 1)[1])

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
            admin_id = query("SELECT id FROM users WHERE email_address='ada@example.test'")[0][0]
            member, member_id = join("bob builder", "bob@example.test")
            other, other_id = join("Cara Member", "cara@example.test")
            assert request("/account/bots", {"user[name]": "Robo Bot", "user[webhook_url]": ""}, admin)[0] in (302, 303)
            bot_id = query("SELECT id FROM users WHERE role=2")[0][0]
            assert query("SELECT involvement FROM memberships WHERE user_id=?", bot_id) == [("mentions",)], "a bot joins open rooms as Rails' default involvement"
            admin_watch, member_watch = watch(admin), watch(member)

            # Rooms::OpensController#new: the people list, the switch to a closed room and its "+" entry point.
            status, _, body = request("/rooms/opens/new", cookie=admin)
            assert status == 200 and "<title>New chat room</title>" in body and 'action="/rooms/opens"' in body and 'value="New room"' in body
            assert 'href="/rooms/closeds/new"' in body and 'class="switch__input" checked="checked"' in body and "Give only some access to this room" in body
            for name in ("Ada Admin", "bob builder", "Cara Member", "Robo Bot"):
                assert f"<strong>{name}</strong>" in body, name
            assert body.count("check-") >= 5 and 'id="search"' not in body
            sidebar = request("/users/me/sidebar", cookie=admin)[2]
            assert 'href="/rooms/opens/new"' in sidebar
            assert 'href="/rooms/opens/new"' in request("/rooms/closeds/new", cookie=admin)[2]
            print("PASS: the new open room page lists everyone, switches to a closed room, and the sidebar's + reaches both")

            # create: every active user, bots included, in with mentions; the sidebar entry as users/sidebars/rooms/_shared.
            assert request("/rooms/opens", {"other": "x"}, admin)[0] == 400
            assert request("/rooms/opens", {"room[name]": "x"}, admin, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
            status, headers, _ = request("/rooms/opens", {"room[name]": "Lounge <1>"}, admin)
            lounge = room_of(headers)
            assert status == 302 and headers["location"] == f"{base}/rooms/{lounge}", (status, headers)
            assert query("SELECT type,creator_id FROM rooms WHERE id=?", lounge) == [("Rooms::Open", admin_id)]
            assert query("SELECT user_id,involvement FROM memberships WHERE room_id=? ORDER BY user_id", lounge) == [
                (admin_id, "mentions"), (member_id, "mentions"), (other_id, "mentions"), (bot_id, "mentions")]
            published = member_watch.expect('action="prepend"', 'target="shared_rooms"', "Lounge &lt;1&gt;")
            assert f'id="list_rooms_open_{lounge}"' in published and 'class="align-center gap room btn txt-nowrap"' in published
            assert f'data-room-id="{lounge}"' in published and 'data-sorted-list-name="Lounge &lt;1&gt;"' in published
            status, headers, _ = request(f"/rooms/opens/{lounge}", cookie=member)
            assert status == 302 and headers["location"] == f"{base}/rooms/{lounge}" and f"last_room={lounge}" in headers["set-cookie"]
            print("PASS: creating an open room grants everyone mentions and broadcasts the sidebar's room entry; show redirects")

            # edit: the creator and administrators administer it; other members get the read-only page.
            status, _, body = request(f"/rooms/opens/{lounge}/edit", cookie=admin)
            assert status == 200 and "Edit settings for Lounge &lt;1&gt;" in body and f'action="/rooms/opens/{lounge}"' in body and 'value="patch"' in body
            assert f'href="/rooms/closeds/{lounge}/edit"' in body and f'action="{base}/rooms/{lounge}"' in body and 'value="delete"' in body
            status, _, body = request(f"/rooms/opens/{lounge}/edit", cookie=member)
            assert status == 200 and '<h1 class="flex-item-grow txt-x-large">' in body and 'name="room[name]"' not in body
            assert "/rooms/closeds/" not in body and 'value="delete"' not in body and "Everyone" in body and "check-" not in body.split("<menu")[1].split("</menu>")[0]
            assert request(f"/rooms/opens/{lounge}", {"_method": "patch", "room[name]": "Mine"}, member)[0] == 403
            assert request(f"/rooms/opens/{lounge}", {"_method": "patch"}, admin)[0] == 400
            status, headers, _ = request(f"/rooms/opens/{lounge}", {"_method": "patch", "room[name]": "Lounge 2"}, admin)
            assert status == 302 and headers["location"] == f"{base}/rooms/{lounge}"
            published = member_watch.expect('action="replace"', f'target="list_rooms_open_{lounge}"')
            assert "Lounge 2" in published and 'class="align-center gap room btn txt-nowrap"' in published
            print("PASS: open room edit for administrators and the read-only page for members, update and its broadcast")

            # Converting: an open room closes with its chosen members, and opens again to everyone.
            status, _, body = request(f"/rooms/closeds/{lounge}/edit", cookie=admin)
            assert status == 200 and f'href="/rooms/opens/{lounge}/edit"' in body
            assert request(f"/rooms/closeds/{lounge}", {"_method": "patch", "room[name]": "Closed", "user_ids[]": [admin_id, member_id]}, admin)[0] == 302
            assert query("SELECT type FROM rooms WHERE id=?", lounge) == [("Rooms::Closed",)]
            assert sorted(query("SELECT user_id FROM memberships WHERE room_id=?", lounge)) == [(admin_id,), (member_id,)]
            execute("UPDATE memberships SET involvement='everything' WHERE room_id=? AND user_id=?", lounge, member_id)
            status, _, body = request(f"/rooms/opens/{lounge}/edit", cookie=admin)
            assert status == 200 and f'action="/rooms/opens/{lounge}"' in body and "<strong>Cara Member</strong>" in body
            assert request(f"/rooms/opens/{lounge}", {"_method": "patch", "room[name]": "Open again"}, admin)[0] == 302
            assert query("SELECT type,name FROM rooms WHERE id=?", lounge) == [("Rooms::Open", "Open again")]
            assert query("SELECT user_id,involvement FROM memberships WHERE room_id=? ORDER BY user_id", lounge) == [
                (admin_id, "mentions"), (member_id, "everything"), (other_id, "mentions"), (bot_id, "mentions")]
            assert request(f"/rooms/{lounge}", cookie=other)[0] == 200
            print("PASS: open rooms convert to closed ones and back, granting everyone access again")

            # Room creation restricted to administrators.
            execute("UPDATE accounts SET settings='{\"restrict_room_creation_to_administrators\":true}'")
            assert request("/rooms/opens/new", cookie=member)[0] == 403
            assert request("/rooms/opens", {"room[name]": "Denied"}, member)[0] == 403
            assert query("SELECT count(*) FROM rooms WHERE name='Denied'")[0][0] == 0
            assert request("/rooms/opens/new", cookie=admin)[0] == 200
            execute("UPDATE accounts SET settings='{}'")
            status, headers, _ = request("/rooms/opens", {"room[name]": "Bob's"}, member)
            bobs = room_of(headers)
            assert status == 302
            print("PASS: members can't create open rooms when creation is restricted to administrators")

            # Scoping: open-room routes reach neither direct rooms nor rooms the user isn't in.
            status, headers, _ = request("/rooms/closeds", {"room[name]": "Bob only", "user_ids[]": [member_id]}, member)
            secret_room = room_of(headers)
            status, headers, _ = request("/rooms/directs", {"user_ids[]": [member_id]}, admin)
            direct = room_of(headers)
            for path in (f"/rooms/opens/{secret_room}/edit", f"/rooms/opens/{direct}/edit", f"/rooms/opens/{secret_room}", "/rooms/opens/999999/edit"):
                status, headers, _ = request(path, cookie=admin)
                assert status == 302 and headers["location"] == f"{base}/", (path, status)
            for room in (secret_room, direct):
                status, headers, _ = request(f"/rooms/opens/{room}", {"_method": "patch", "room[name]": "Taken"}, admin)
                assert status == 302 and headers["location"] == f"{base}/"
            assert query("SELECT type,name FROM rooms WHERE id=?", direct) == [("Rooms::Direct", None)]
            assert query("SELECT name FROM rooms WHERE id=?", secret_room) == [("Bob only",)]
            assert request(f"/rooms/opens/{bobs}", {"_method": "delete"}, member)[0] == 500
            assert request(f"/rooms/closeds/{secret_room}", {"_method": "delete"}, member)[0] == 500
            assert request("/rooms/opens", cookie=admin)[1]["location"] == f"{base}/"
            assert request("/rooms", cookie=admin)[1]["location"] == f"{base}/rooms/{direct}"
            assert request(f"/rooms/{bobs}", {"_method": "patch"}, member)[0] == 404
            print("PASS: open-room routes are scoped to the user's open and closed rooms, as Rails' set_room is")

            # Deleting an open room from its edit page.
            status, headers, _ = request(f"/rooms/{bobs}", {"_method": "delete"}, other)
            assert status == 403
            status, headers, _ = request(f"/rooms/{bobs}", {"_method": "delete"}, member)
            assert status == 302 and headers["location"] == f"{base}/" and query("SELECT count(*) FROM rooms WHERE id=?", bobs)[0][0] == 0
            assert admin_watch.expect(f'<turbo-stream action="remove" target="list_rooms_open_{bobs}">')
            print("PASS: an open room's creator deletes it, and the sidebars drop it")

            # Pings: the new page, creation with its per-member sidebar entries, the settings page and deletion.
            status, _, body = request("/rooms/directs/new", cookie=admin)
            assert status == 200 and body.startswith("<!DOCTYPE html>") and 'id="direct_rooms_control"' in body and "Type names to ping someone…" in body
            status, _, body = request("/rooms/directs/new", cookie=admin, headers={"Turbo-Frame": "direct_rooms_control"})
            assert status == 200 and body.startswith("<html>") and 'data-autocomplete-url-value="/autocompletable/users"' in body and "remove-circle" in body
            status, headers, _ = request(f"/rooms/directs?user_ids%5B%5D={member_id}", {}, admin)
            assert status == 302 and headers["location"] == f"{base}/rooms/{direct}", "the same people find the same Ping"
            for watcher, needle in ((admin_watch, "bob"), (member_watch, "Ada")):
                published = watcher.expect('action="prepend"', 'target="direct_rooms"', f'id="list_rooms_direct_{direct}"')
                assert "Ping with" in published and needle in published and 'class="direct"' in published, published
            status, headers, _ = request(f"/rooms/directs?user_ids%5B%5D={bot_id}", {}, admin)
            assert status == 302
            bot_ping = room_of(headers)
            assert query("SELECT user_id,involvement FROM memberships WHERE room_id=? ORDER BY user_id", bot_ping) == [(admin_id, "everything"), (bot_id, "everything")]
            assert f'action="/rooms/directs?user_ids%5B%5D={bot_id}"' in request(f"/users/{bot_id}", cookie=admin)[2]
            status, headers, _ = request("/rooms/directs", {}, other)
            alone = room_of(headers)
            assert status == 302 and query("SELECT user_id FROM memberships WHERE room_id=?", alone) == [(other_id,)]
            status, headers, _ = request("/rooms/directs", {"user_ids[]": [member_id, other_id, 999999]}, admin)
            group = room_of(headers)
            assert sorted(query("SELECT user_id FROM memberships WHERE room_id=?", group)) == sorted([(admin_id,), (member_id,), (other_id,)])
            assert "BB+CM" in admin_watch.expect('target="direct_rooms"', f'id="list_rooms_direct_{group}"')
            status, _, body = request(f"/rooms/directs/{group}/edit", cookie=admin)
            assert status == 200 and "<title>Edit settings for bob builder and Cara Member</title>" in body
            assert "<strong>bob builder</strong>" in body and "<strong>Cara Member</strong>" in body and "<strong>Ada Admin</strong>" not in body
            assert f'action="{base}/rooms/directs/{group}"' in body and 'aria-label="Delete Ping"' in body
            status, _, body = request(f"/rooms/directs/{alone}/edit", cookie=other)
            assert status == 200 and "<title>Edit settings for Cara Member</title>" in body and "<strong>Cara Member</strong>" in body
            assert request(f"/rooms/directs/{lounge}/edit", cookie=admin)[1]["location"] == f"{base}/"
            assert request(f"/rooms/directs/{group}", cookie=admin)[0] == 500
            assert request(f"/rooms/directs/{group}", {"_method": "patch"}, admin)[0] == 404
            status, headers, _ = request(f"/rooms/directs/{lounge}", {"_method": "delete"}, admin)
            assert status == 302 and headers["location"] == f"{base}/" and query("SELECT count(*) FROM rooms WHERE id=?", lounge)[0][0] == 1
            status, headers, _ = request(f"/rooms/directs/{group}", {"_method": "delete"}, member)
            assert status == 302 and headers["location"] == f"{base}/" and query("SELECT count(*) FROM rooms WHERE id=?", group)[0][0] == 0
            assert admin_watch.expect(f'<turbo-stream action="remove" target="list_rooms_direct_{group}">')
            assert request(f"/rooms/directs/{group}", {"_method": "delete"}, admin)[1]["location"] == f"{base}/"
            print("PASS: Pings with anyone (bots and yourself included), per-member sidebar entries, the settings page and deletion")

            # Autocomplete, as Autocompletable::UsersController renders it.
            for n in range(20):
                join(f"Extra {n:02}", f"extra{n}@example.test")
            status, headers, body = request("/autocompletable/users", cookie=admin, headers={"Accept": "application/json"})
            users = json.loads(body)
            assert status == 200 and headers["content-type"] == "application/json; charset=utf-8" and len(users) == 20
            assert list(users[0]) == ["name", "value", "avatar_url", "sgid"]
            assert users[0]["name"] == "Ada Admin" and users[1]["name"] == "bob builder" and users[2]["name"] == "Cara Member"
            assert users[0]["avatar_url"].startswith(f"{base}/users/") and users[0]["sgid"].count("--") == 1
            assert headers["x-total-count"] == "24" and headers["link"] == f'<{base}/autocompletable/users?page=2>; rel="next"'
            status, headers, body = request("/autocompletable/users?query=e&page=1", cookie=admin, headers={"Accept": "application/json"})
            assert headers["x-total-count"] == "22" and headers["link"] == f'<{base}/autocompletable/users?page=2&query=e>; rel="next"'
            status, headers, body = request("/autocompletable/users.json?page=2", cookie=admin)
            assert [user["name"] for user in json.loads(body)] == ["Extra 17", "Extra 18", "Extra 19", "Robo Bot"] and "link" not in headers
            assert json.loads(request("/autocompletable/users.json?query=%3C", cookie=admin)[2]) == []
            execute("UPDATE users SET name='<b>Bob</b>' WHERE id=?", member_id)
            assert json.loads(request("/autocompletable/users.json?query=Bob", cookie=admin)[2])[0]["name"] == "&lt;b&gt;Bob&lt;/b&gt;"
            execute("UPDATE users SET name='bob builder' WHERE id=?", member_id)
            status, headers, body = request("/autocompletable/users?query=bob", cookie=admin)
            assert status == 200 and headers["content-type"].startswith("text/html") and body.count("<lexxy-prompt-item") == 1
            assert 'data-turbo-frame="_top"' in body and '<img aria-hidden="true"' in body
            assert request("/autocompletable/users?room_id=999999", cookie=admin)[0] == 404
            assert request("/autocompletable/users", cookie=admin, headers={"Accept": "image/png"})[0] == 406
            print("PASS: autocomplete JSON and prompt items with Rails' users, order, paging, fields and formats")

            # The sidebar's Ping placeholders: 20 less the people already in the user's Pings, counting the user twice.
            def placeholders(cookie):
                return len(re.findall(r'action="/rooms/directs\?user_ids%5B%5D=\d+"', request("/users/me/sidebar", cookie=cookie)[2]))
            fresh, _ = join("Fresh Face", "fresh@example.test")
            assert placeholders(fresh) == 19
            assert request("/rooms/directs", {"user_ids[]": [admin_id]}, fresh)[0] == 302
            assert placeholders(fresh) == 17
            print("PASS: the sidebar's Ping placeholders")
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read()[-6000:], file=sys.stderr)
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
