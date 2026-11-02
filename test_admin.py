#!/usr/bin/env python3
"""Account administration, bans, the account logo, the PWA routes and push subscription storage."""
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import html
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlencode

binary = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parent
CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"


def asset(name):
    manifest = json.loads((root / "views/assets.json").read_text())
    return (root / "assets/reference" / manifest[name]["path"]).read_bytes()


class WebSocket:
    """Just enough of an ActionCable client to receive a publication."""
    def __init__(self, port, cookie):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=15)
        self.sock.sendall((f"GET /cable HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\n"
                           f"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nCookie: {cookie}\r\n\r\n").encode())
        head = b""
        while not head.endswith(b"\r\n\r\n"): head += self.take(1)
        assert head.startswith(b"HTTP/1.1 101"), head
        assert self.receive()["type"] == "welcome"

    def take(self, size):
        data = bytearray()
        while len(data) < size:
            part = self.sock.recv(size - len(data)); assert part, "WebSocket EOF"; data.extend(part)
        return bytes(data)

    def receive(self):
        result = bytearray()
        while True:
            op, size = self.take(2)
            if size == 126: size = struct.unpack("!H", self.take(2))[0]
            elif size == 127: size = struct.unpack("!Q", self.take(8))[0]
            result.extend(self.take(size))
            if op & 0x80: return json.loads(result)

    def subscribe(self, identifier):
        data = json.dumps({"command": "subscribe", "identifier": identifier}).encode()
        mask = secrets.token_bytes(4)
        size = bytes([0x80 | len(data)]) if len(data) < 126 else b"\xfe" + struct.pack("!H", len(data))
        self.sock.sendall(b"\x81" + size + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))
        while True:
            message = self.receive()
            if message.get("identifier") == identifier and "type" in message: return message["type"]

    def publication(self):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            message = self.receive()
            if isinstance(message.get("message"), str): return message["message"]
        raise TimeoutError("publication did not arrive")


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


with tempfile.TemporaryDirectory(prefix="campfire-admin-") as directory:
    work = Path(directory)
    database = work / "production.sqlite3"
    storage = work / "files"
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0)); port = probe.getsockname()[1]
    env = dict(os.environ, DATABASE_PATH=str(database), STORAGE_PATH=str(storage), SECRET_KEY_BASE=secrets.token_hex(64), HTTP_PORT=str(port))
    with (work / "server.log").open("w+") as log:
        server = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log, cwd=root)

        def request(path, data=None, cookie="", method=None, headers=None, kind="application/x-www-form-urlencoded"):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            fields = {"Sec-Fetch-Site": "same-origin", "Host": f"127.0.0.1:{port}"}
            if cookie: fields["Cookie"] = cookie
            body = None
            if data is not None:
                body = urlencode(data) if isinstance(data, (dict, list)) else data
                fields["Content-Type"] = kind
            fields.update(headers or {})
            connection.request(method or ("GET" if data is None else "POST"), path, body, fields)
            response = connection.getresponse()
            result = response.status, {k.lower(): v for k, v in response.getheaders()}, response.read()
            connection.close()
            return result

        def form(path, data, cookie, **options):
            return request(path, data, cookie, **options)

        def sql(query, *args):
            with sqlite3.connect(database, timeout=10) as db:
                return db.execute(query, args).fetchall()

        def write(query, *args):
            with sqlite3.connect(database, timeout=10) as db:
                db.execute(query, args); db.commit()

        def cookie_of(headers):
            return headers["set-cookie"].split(";", 1)[0]

        try:
            for _ in range(200):
                if server.poll() is not None: raise AssertionError("server exited during startup")
                try:
                    if request("/up")[0] == 200: break
                except ConnectionRefusedError: time.sleep(.05)
            else: raise AssertionError("server did not start")

            # The PWA routes and the stock logo need no account and no session.
            status, headers, body = request("/webmanifest.json")
            manifest = json.loads(body)
            assert status == 200 and headers["content-type"] == "application/json; charset=utf-8", (status, headers)
            assert manifest["name"] == "Campfire" and manifest["icons"][0]["src"] == "/account/logo?size=small", manifest
            assert manifest["shortcuts"][0]["icons"][0]["src"] == f"http://127.0.0.1:{port}/assets/add-f232d8a6.svg", manifest
            assert request("/webmanifest")[0] == 406
            assert request("/webmanifest", headers={"Accept": "*/*"})[0] == 200
            status, headers, body = request("/service-worker.js")
            assert status == 200 and headers["content-type"] == "text/javascript; charset=utf-8" and b"notificationclick" in body
            assert request("/service-worker")[0] == 406
            assert request("/service-worker", headers={"Accept": "text/javascript, */*"})[0] == 200
            stock, stock_small = asset("logos/app-icon.png"), asset("logos/app-icon-192.png")
            status, headers, body = request("/account/logo")
            assert status == 200 and body == stock and headers["content-type"] == "image/png", (status, headers)
            assert headers["cache-control"] == "max-age=300, public, stale-while-revalidate=604800"
            assert request("/account/logo?size=small")[2] == stock_small
            assert request("/account/logo", method="HEAD")[0] == 200
            print("PASS: manifest, service worker and stock logo without an account or session; format negotiation")

            status, headers, _ = request("/first_run", {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test", "user[password]": "admin password"})
            assert status == 303
            admin = cookie_of(headers)
            code = sql("SELECT join_code FROM accounts")[0][0]
            people = {}
            for name in ("Bob Member", "Cy Member"):
                email = name.split()[0].lower() + "@example.test"
                status, headers, _ = request(f"/join/{code}", {"user[name]": name, "user[email_address]": email, "user[password]": "member password"})
                assert status == 303, status
                people[name.split()[0].lower()] = (cookie_of(headers), sql("SELECT id FROM users WHERE email_address=?", email)[0][0])
            member, member_id = people["bob"]
            other, other_id = people["cy"]
            admin_id = sql("SELECT id FROM users WHERE role=1")[0][0]

            # Account name and logo versions reach the manifest; the logo's ETag revalidates.
            write("UPDATE accounts SET name='Fire & <Ice>'")
            manifest = json.loads(request("/webmanifest.json")[2])
            assert manifest["name"] == "Fire &amp; &lt;Ice&gt;" and re.fullmatch(r"/account/logo\?v=\d{14}", manifest["icons"][1]["src"]), manifest
            status, headers, _ = request("/account/logo")
            assert request("/account/logo", headers={"If-None-Match": headers["etag"]})[0] == 304

            # Accounts::UsersController#index is a turbo stream for anyone signed in.
            stream = {"Accept": "text/vnd.turbo-stream.html, text/html"}
            assert request("/account/users", headers=stream)[0] == 302
            assert request("/account/users", cookie=member)[0] == 406
            status, headers, body = request("/account/users", cookie=admin, headers=stream)
            page = body.decode()
            assert status == 200 and headers["content-type"].startswith("text/vnd.turbo-stream.html"), status
            assert page.startswith('<turbo-stream action="replace" target="next_page_container">') and "Bob Member" in page
            assert f'action="/account/users/{member_id}"' in page and f'id="role_user_{admin_id}" disabled="disabled"' in page
            assert "Delete Ada Admin" not in page and "Delete Bob Member" in page
            page = request("/account/users.turbo_stream?page=1", cookie=member)[2].decode()
            assert "Bob Member" in page and "role_user_" not in page and "Delete " not in page and "My settings" in page
            assert "Bob Member" not in request("/account/users.turbo_stream?page=2", cookie=member)[2].decode()
            page = request("/account/edit", cookie=admin)[2].decode()
            assert '<turbo-frame id="account_users">' in page and "Regenerate join link" in page and 'name="account[logo]"' in page
            assert page.count("Save changes") == 1
            page = request("/account/edit", cookie=member)[2].decode()
            assert '<turbo-frame id="account_users">' in page and "Regenerate join link" not in page and "account[logo]" not in page
            print("PASS: account users stream and settings page for administrators and members")

            # Role changes: the check box comes after its hidden default, and the last value wins.
            path = f"/account/users/{member_id}"
            promote = [("_method", "patch"), ("user[role]", "member"), ("user[role]", "administrator")]
            assert form(path, promote, other)[0] == 403
            assert form(path, promote, admin, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
            assert request(path, cookie="")[0] == 302
            status, headers, _ = form(path, promote, admin)
            assert status == 302 and headers["location"] == "/account/edit", (status, headers)
            assert sql("SELECT role FROM users WHERE id=?", member_id)[0][0] == 1
            assert form(path, [("_method", "patch"), ("user[role]", "member")], member)[0] == 302
            assert sql("SELECT role FROM users WHERE id=?", member_id)[0][0] == 0
            assert form(path, {"_method": "patch", "user[role]": "owner"}, admin)[0] == 302
            assert sql("SELECT role FROM users WHERE id=?", member_id)[0][0] == 0
            assert request(path, urlencode({"user[role]": "administrator"}), admin, method="PATCH")[0] == 302
            assert sql("SELECT role FROM users WHERE id=?", member_id)[0][0] == 1
            write("UPDATE users SET role=0 WHERE id=?", member_id)
            assert form(path, {"_method": "patch"}, admin)[0] == 400
            assert form("/account/users/999999", promote, admin)[0] == 404
            assert request(path, cookie=admin)[0] == 404
            print("PASS: role updates by administrators only, with Rails' parameter rules")

            # Accounts::JoinCodesController#create
            assert form("/account/join_code", {}, member)[0] == 403
            status, headers, _ = form("/account/join_code", {}, admin)
            assert status == 302 and headers["location"] == "/account/edit"
            fresh = sql("SELECT join_code FROM accounts")[0][0]
            assert fresh != code and re.fullmatch(r"[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}", fresh), fresh
            assert request(f"/join/{code}")[0] == 404 and request(f"/join/{fresh}")[0] == 200
            assert fresh in request("/account/edit", cookie=admin)[2].decode()
            print("PASS: join code regeneration")

            # Push subscriptions belong to the signed-in user; endpoints must be permitted push services.
            subscriptions = "/users/me/push_subscriptions"
            def subscribe(payload, cookie=member, **options):
                return request(subscriptions, json.dumps(payload), cookie, kind="application/json", headers={"User-Agent": CHROME, **options})
            valid = {"endpoint": "https://fcm.googleapis.com/fcm/send/abc", "p256dh_key": "p256", "auth_key": "auth"}
            for endpoint in ("http://fcm.googleapis.com/x", "https://evil.test/x", "https://fcm.googleapis.com:8443/x",
                             "https://fcm.googleapis.com.evil.test/x", "https://fcm.googleapis.com/a b", ""):
                assert subscribe({"push_subscription": dict(valid, endpoint=endpoint)})[0] == 422, endpoint
            assert subscribe({})[0] == 400
            assert subscribe({"push_subscription": valid}, **{"Sec-Fetch-Site": "cross-site"})[0] == 422
            assert subscribe({"push_subscription": valid}, cookie="")[0] == 302
            assert subscribe({"push_subscription": valid})[0] == 200
            assert subscribe({"push_subscription": valid})[0] == 200
            assert subscribe(dict(valid, endpoint="https://updates.push.services.mozilla.com/wpush/v2/x"))[0] == 200
            assert form(subscriptions, {"push_subscription[endpoint]": "https://web.push.apple.com:443/y"}, member)[0] == 200
            rows = sql("SELECT endpoint,p256dh_key,auth_key,user_agent FROM push_subscriptions WHERE user_id=? ORDER BY id", member_id)
            assert rows == [("https://fcm.googleapis.com/fcm/send/abc", "p256", "auth", CHROME),
                            ("https://updates.push.services.mozilla.com/wpush/v2/x", "p256", "auth", CHROME),
                            ("https://web.push.apple.com:443/y", None, None, None)], rows
            assert subscribe({"push_subscription": valid}, cookie=other)[0] == 200
            own = sql("SELECT id FROM push_subscriptions WHERE user_id=? ORDER BY id", member_id)[0][0]
            foreign = sql("SELECT id FROM push_subscriptions WHERE user_id=?", other_id)[0][0]
            status, _, body = request(subscriptions, cookie=member)
            page = body.decode()
            assert status == 200 and "Push Notification Subscriptions" in page and "Chrome 140.0.0.0 on Macintosh" in page
            assert f"/users/me/push_subscriptions/{own}/test_notifications" in page and f"/push_subscriptions/{foreign}" not in page
            assert request(subscriptions)[0] == 302
            status, headers, _ = form(f"{subscriptions}/{own}/test_notifications", {}, member)
            assert status == 302 and headers["location"] == subscriptions
            assert form(f"{subscriptions}/{foreign}/test_notifications", {}, member)[0] == 404
            assert form(f"{subscriptions}/{foreign}", {"_method": "delete"}, member)[0] == 302
            assert sql("SELECT count(*) FROM push_subscriptions WHERE id=?", foreign)[0][0] == 1
            status, headers, _ = form(f"{subscriptions}/{own}", {"_method": "delete"}, member)
            assert status == 302 and headers["location"] == subscriptions
            assert sql("SELECT count(*) FROM push_subscriptions WHERE id=?", own)[0][0] == 0
            assert request(f"{subscriptions}/{foreign}", cookie=other)[0] == 404
            print("PASS: push subscription index, create, endpoint validation, ownership and destroy")

            # The logo: uploading stores an Active Storage blob; a Rails-made variant is preferred.
            png = stock_small
            upload, kind = multipart([("_method", "patch"), ("account[logo]", ("logo.png", "image/png", png))])
            assert request("/account", upload, member, kind=kind)[0] == 403
            before = sql("SELECT updated_at FROM accounts")[0][0]
            status, headers, _ = request("/account", upload, admin, kind=kind)
            assert status == 302 and headers["location"] == "/account/edit", (status, headers)
            [(blob, key, filename, content_type, size, checksum, service)] = sql(
                "SELECT b.id,b.key,b.filename,b.content_type,b.byte_size,b.checksum,b.service_name FROM active_storage_blobs b "
                "JOIN active_storage_attachments a ON a.blob_id=b.id WHERE a.record_type='Account' AND a.name='logo'")
            file = storage / key[:2] / key[2:4] / key
            assert re.fullmatch(r"[a-z0-9]{28}", key) and file.read_bytes() == png and (filename, content_type, size, service) == ("logo.png", "image/png", len(png), "local")
            assert checksum == base64.b64encode(hashlib.md5(png).digest()).decode()
            assert sql("SELECT updated_at FROM accounts")[0][0] != before
            # The :large and :small variants are made with libvips (test_uploads.py checks their sizes).
            large, small = request("/account/logo")[2], request("/account/logo?size=small")[2]
            assert large.startswith(b"\x89PNG") and small.startswith(b"\x89PNG") and struct.unpack("!II", large[16:24]) == (192, 192)
            assert sorted(d for (d,) in sql("SELECT variation_digest FROM active_storage_variant_records WHERE blob_id=?", blob)) == ["EXATZfM7OVVC86CDh85TOsa8ZSw=", "ksXvpLsa7BuCVyHOwmQOKedbIbM="]
            variant_keys = [k for (k,) in sql("SELECT key FROM active_storage_blobs WHERE id<>?", blob)]
            assert "Delete logo" in request("/account/edit", cookie=admin)[2].decode()
            # A JPEG libvips can't read: Rails would fail the request; the stock icon is served instead.
            jpeg = b"\xff\xd8\xff\xe0" + b"jpeg"
            upload, kind = multipart([("_method", "patch"), ("account[logo]", ("photo.jpg", "image/jpeg", jpeg))])
            assert request("/account", upload, admin, kind=kind)[0] == 302
            assert not file.exists() and not any((storage / k[:2] / k[2:4] / k).exists() for k in variant_keys)
            assert sql("SELECT count(*) FROM active_storage_blobs")[0][0] == 1 and sql("SELECT count(*) FROM active_storage_variant_records")[0][0] == 0
            status, headers, body = request("/account/logo")
            assert body == stock and headers["content-type"] == "image/png"
            upload, kind = multipart([("_method", "patch"), ("account[logo]", ("notes.txt", "text/plain", b"not an image"))])
            assert request("/account", upload, admin, kind=kind)[0] == 302
            assert request("/account/logo")[2] == stock
            empty, kind = multipart([("_method", "patch"), ("account[logo]", ("", "application/octet-stream", b""))])
            assert request("/account", empty, admin, kind=kind)[0] == 302
            assert sql("SELECT content_type FROM active_storage_blobs")[0][0] == "text/plain"
            assert form("/account/logo", {"_method": "delete"}, member)[0] == 403
            [(key,)] = sql("SELECT key FROM active_storage_blobs")
            status, headers, _ = form("/account/logo?v=1", {"_method": "delete"}, admin)
            assert status == 302 and headers["location"] == "/account/edit"
            assert sql("SELECT count(*) FROM active_storage_attachments")[0][0] == 0 and sql("SELECT count(*) FROM active_storage_blobs")[0][0] == 0
            assert not (storage / key[:2] / key[2:4] / key).exists() and request("/account/logo")[2] == stock
            assert form("/account/logo", {"_method": "delete"}, admin)[0] == 302
            print("PASS: logo upload as an Active Storage blob, variants, replacement, non-images, destroy and authorization")

            # Users::BansController: a ban signs the user out, bans their public addresses and removes their messages.
            status, headers, _ = form("/rooms/opens", {"room[name]": "Second room"}, admin)
            assert status == 303, status
            rooms = [row[0] for row in sql("SELECT id FROM rooms WHERE type='Rooms::Open' ORDER BY id")]
            for index, room in enumerate(rooms):
                data = {"message[body]": f"Bob says {index}", "message[client_message_id]": f"bob-{index}"}
                assert request(f"/rooms/{room}/messages", data, member, headers={"Accept": "text/vnd.turbo-stream.html"})[0] == 200
            assert request(f"/rooms/{rooms[0]}/messages", {"message[body]": "Ada stays", "message[client_message_id]": "ada-0"}, admin)[0] == 200
            bob_message = sql("SELECT id FROM messages WHERE client_message_id='bob-0'")[0][0]
            write("INSERT INTO boosts(message_id,booster_id,content,created_at,updated_at) VALUES(?,?,'👍','2026-01-01','2026-01-01')", bob_message, admin_id)
            write("INSERT INTO sessions(user_id,token,ip_address,created_at,updated_at,last_active_at) VALUES(?,'bob-phone','8.8.8.8','2026-01-01','2026-01-01','2026-01-01')", member_id)
            write("INSERT INTO sessions(user_id,token,ip_address,created_at,updated_at,last_active_at) VALUES(?,'bob-laptop','2001:4860:4860::8888','2026-01-01','2026-01-01','2026-01-01')", member_id)
            write("INSERT INTO sessions(user_id,token,ip_address,created_at,updated_at,last_active_at) VALUES(?,'bob-tablet','8.8.8.8','2026-01-01','2026-01-01','2026-01-01')", member_id)
            ban = f"/users/{member_id}/ban"
            assert form(ban, {}, other)[0] == 403
            assert form(ban, {}, admin, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
            assert form("/users/999999/ban", {}, admin)[0] == 404
            for address in ("10.0.0.5", "127.0.0.1", "192.168.1.9", "172.20.0.1", "169.254.1.1", "::1", "fe80::1", "fd00::1", "::ffff:10.1.2.3", "not-an-ip"):
                write("INSERT INTO sessions(user_id,token,ip_address,created_at,updated_at,last_active_at) VALUES(?,'bob-private',?,'2026-01-01','2026-01-01','2026-01-01')", member_id, address)
                assert form(ban, {}, admin)[0] == 422, address
                write("DELETE FROM sessions WHERE token='bob-private'")
            assert sql("SELECT status FROM users WHERE id=?", member_id)[0][0] == 0 and sql("SELECT count(*) FROM bans")[0][0] == 0
            assert request("/rooms/" + str(rooms[0]), cookie=member)[0] == 200
            page = request("/users/me/sidebar", cookie=admin)[2].decode()
            streams = [html.unescape(name) for name in re.findall(r'channel="Turbo::StreamsChannel" signed-stream-name="([^"]+)"', page)]
            everyone = next(name for name in streams if base64.b64decode(name.split("--")[0]) == b'"rooms"')
            listener = WebSocket(port, admin)
            identifier = json.dumps({"channel": "Turbo::StreamsChannel", "signed_stream_name": everyone})
            assert listener.subscribe(identifier) == "confirm_subscription"
            status, headers, _ = form(ban, {}, admin)
            assert status == 302 and headers["location"] == f"/users/{member_id}", (status, headers)
            removals = listener.publication()
            assert removals == '<turbo-stream action="remove" target="message_bob-0"></turbo-stream><turbo-stream action="remove" target="message_bob-1"></turbo-stream>', removals
            listener.sock.close()
            assert sql("SELECT status FROM users WHERE id=?", member_id)[0][0] == 2
            assert sql("SELECT count(*) FROM sessions WHERE user_id=?", member_id)[0][0] == 0
            assert sorted(row[0] for row in sql("SELECT ip_address FROM bans WHERE user_id=?", member_id)) == ["2001:4860:4860::8888", "8.8.8.8"]
            assert sql("SELECT count(*) FROM messages WHERE creator_id=?", member_id)[0][0] == 0
            assert sql("SELECT count(*) FROM boosts")[0][0] == 0
            assert sql("SELECT count(*) FROM message_search_index WHERE body LIKE 'Bob says%'")[0][0] == 0
            assert sql("SELECT count(*) FROM action_text_rich_texts WHERE body LIKE '%Bob says%'")[0][0] == 0
            assert sql("SELECT count(*) FROM messages WHERE client_message_id='ada-0'")[0][0] == 1
            assert request(f"/rooms/{rooms[0]}", cookie=member)[0] == 302
            page = request("/account/edit", cookie=admin)[2].decode()
            assert 'class="flex align-center gap margin-none banned"' in page
            assert "Bob Member" not in request("/account/users.turbo_stream", cookie=admin)[2].decode()
            assert "Bob Member" not in request("/account/edit", cookie=other)[2].decode()
            status, headers, _ = form(ban, {"_method": "delete"}, admin)
            assert status == 302 and headers["location"] == f"/users/{member_id}"
            assert sql("SELECT status FROM users WHERE id=?", member_id)[0][0] == 0 and sql("SELECT count(*) FROM bans")[0][0] == 0
            assert form(ban, {"_method": "delete"}, other)[0] == 403
            status, headers, _ = request("/session", {"email_address": "bob@example.test", "password": "member password"})
            assert status == 302
            member = cookie_of(headers)
            print("PASS: bans by administrators: address validation, signed-out sessions, removed messages, unban")

            # Accounts::UsersController#destroy deactivates; direct rooms keep the membership.
            status, headers, _ = form("/rooms/directs", {"user_ids[]": str(other_id)}, admin)
            assert status == 303, status
            direct = sql("SELECT id FROM rooms WHERE type='Rooms::Direct'")[0][0]
            write("INSERT INTO searches(user_id,query,created_at,updated_at) VALUES(?,'coffee','2026-01-01','2026-01-01')", other_id)
            assert subscribe({"push_subscription": valid}, cookie=other)[0] == 200
            path = f"/account/users/{other_id}"
            assert form(path, {"_method": "delete"}, member)[0] == 403
            status, headers, _ = form(path, {"_method": "delete"}, admin)
            assert status == 302 and headers["location"] == "/account/edit"
            [(state, email)] = sql("SELECT status,email_address FROM users WHERE id=?", other_id)
            assert state == 1 and re.fullmatch(r"cy-deactivated-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}@example\.test", email), email
            for table in ("sessions", "searches", "push_subscriptions"):
                assert sql(f"SELECT count(*) FROM {table} WHERE user_id=?", other_id)[0][0] == 0, table
            assert [row[0] for row in sql("SELECT room_id FROM memberships WHERE user_id=?", other_id)] == [direct]
            assert request("/rooms/" + str(direct), cookie=other)[0] == 302
            assert form(path, {"_method": "delete"}, admin)[0] == 404
            assert form(path, {"_method": "patch", "user[role]": "administrator"}, admin)[0] == 404
            assert "Cy Member" not in request("/account/edit", cookie=admin)[2].decode()
            print("PASS: deactivation by administrators: sessions, searches, subscriptions and shared rooms removed")
        except BaseException:
            log.seek(0); print(log.read(), file=sys.stderr); raise
        finally:
            server.terminate()
            try: server.wait(timeout=5)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
