#!/usr/bin/env python3
"""Differential checks of the rooms area against the Rails reference image: open room and Ping pages,
room creation rules, open/closed conversion, deletion, room scoping, autocomplete and the sidebar.
The same requests, with the same secret, go to Rails and to this server; pages are compared as parsed
HTML (compare_rendering.CanonicalHTML), redirects by status and Location, JSON as values, and the
rooms and memberships as stored. Needs Docker and the reference image:

    python3 compare_ui_rooms.py once-campfire-goose:rooms-app [--reference once-campfire-verification:reference-90b3300]

The suite doesn't run it (the test build has no Rails).
"""
import argparse
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import socket
import sqlite3
import subprocess
import struct
import sys
import tempfile
import threading
import time
from urllib.parse import urlencode
import uuid

from compare_rendering import CanonicalHTML

ENV = {"RAILS_ENV": "production", "DISABLE_SSL": "true", "SKIP_TELEMETRY": "true", "APP_VERSION": "parity", "GIT_REVISION": "parity",
       "WEB_CONCURRENCY": "1", "RAILS_MAX_THREADS": "5", "JOB_CONCURRENCY": "1", "RAILS_LOG_LEVEL": "warn"}


class Server:
    def __init__(self, image, secret, work):
        self.image, self.work, self.secret = image, work, secret
        for folder in ("db", "files", "logs"):
            (work / folder).mkdir(parents=True, exist_ok=True); os.chmod(work / folder, 0o777)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0)); self.port = probe.getsockname()[1]
        self.start()

    def start(self):
        self.name = "campfire-rooms-" + uuid.uuid4().hex[:10]
        env = self.work / "env"
        env.write_text("".join(f"{k}={v}\n" for k, v in dict(ENV, SECRET_KEY_BASE=self.secret, HTTP_PORT="3000", TARGET_PORT="3001").items()))
        command = ["docker", "run", "-d", "--name", self.name, "-p", f"127.0.0.1:{self.port}:3000", "--env-file", str(env)]
        for folder in ("db", "files", "logs"): command += ["-v", f"{self.work / folder}:/rails/storage/{folder}"]
        subprocess.run(command + [self.image], check=True, stdout=subprocess.DEVNULL)
        probe = Client(self)
        for _ in range(600):
            try:
                if probe.request("/up")[0] == 200: return
            except (OSError, http.client.HTTPException): pass
            time.sleep(.1)
        raise RuntimeError(f"{self.image} did not start")

    def stop(self):
        subprocess.run(["docker", "stop", "-t", "20", self.name], stdout=subprocess.DEVNULL)
        logs = subprocess.run(["docker", "logs", self.name], capture_output=True, text=True)
        with (self.work / "server.log").open("a") as log: log.write(logs.stdout + logs.stderr)
        subprocess.run(["docker", "rm", "-f", self.name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # The database is read and written only while the container is stopped: a bind mount shares no WAL index.
    def sql(self, query, *args):
        with sqlite3.connect(self.work / "db/production.sqlite3", timeout=10) as db:
            return db.execute(query, args).fetchall()


class Client:
    def __init__(self, server):
        self.server, self.cookies, self.csrf = server, {}, ""

    @property
    def base(self):
        return f"http://127.0.0.1:{self.server.port}"

    def request(self, path, data=None, method=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.port, timeout=60)
        fields = {"Sec-Fetch-Site": "same-origin", "Host": f"127.0.0.1:{self.server.port}"}
        if self.cookies: fields["Cookie"] = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
        if data is not None:
            if isinstance(data, (dict, list)): data = urlencode(data, doseq=True)
            fields["Content-Type"] = "application/x-www-form-urlencoded"
            # Rails' forgery protection, from the last page's csrf-token; this server ignores it.
            if self.csrf: fields["X-CSRF-Token"] = self.csrf
        fields.update(headers or {})
        connection.request(method or ("GET" if data is None else "POST"), path, data, fields)
        response = connection.getresponse()
        for cookie in response.msg.get_all("Set-Cookie") or []:
            name, _, value = cookie.split(";", 1)[0].partition("=")
            if "max-age=0" in cookie.lower() or not value: self.cookies.pop(name, None)
            else: self.cookies[name] = value
        result = response.status, {k.lower(): v for k, v in response.getheaders()}, response.read().decode("utf8", "replace")
        token = re.search(r'<meta name="csrf-token" content="([^"]*)"', result[2])
        if token: self.csrf = token[1]
        connection.close()
        return result


class Listener:
    """A cable connection subscribed to a client's sidebar streams, collecting the turbo streams it is sent."""
    def __init__(self, client):
        self.messages, self.sock = [], socket.create_connection(("127.0.0.1", client.server.port), timeout=30)
        cookie = "; ".join(f"{k}={v}" for k, v in client.cookies.items())
        self.sock.sendall((f"GET /cable HTTP/1.1\r\nHost: 127.0.0.1:{client.server.port}\r\nOrigin: {client.base}\r\n"
                           "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                           "Sec-WebSocket-Protocol: actioncable-v1-json\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                           f"Cookie: {cookie}\r\n\r\n").encode())
        head = b""
        while not head.endswith(b"\r\n\r\n"): head += self.take(1)
        assert head.startswith(b"HTTP/1.1 101"), head
        page = client.request("/users/me/sidebar")[2]
        pending = set()
        for name in re.findall(r'<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name="([^"]+)"', page):
            identifier = json.dumps({"channel": "Turbo::StreamsChannel", "signed_stream_name": name})
            pending.add(identifier); self.send({"command": "subscribe", "identifier": identifier})
        while pending:
            message = self.receive()
            if message.get("type") == "confirm_subscription": pending.discard(message["identifier"])
        self.thread = threading.Thread(target=self.run, daemon=True); self.thread.start()

    def take(self, size):
        data = bytearray()
        while len(data) < size:
            part = self.sock.recv(size - len(data))
            if not part: raise EOFError
            data.extend(part)
        return bytes(data)

    def send(self, value):
        data = json.dumps(value).encode(); mask = secrets.token_bytes(4)
        size = bytes([0x80 | len(data)]) if len(data) < 126 else b"\xfe" + struct.pack("!H", len(data))
        self.sock.sendall(b"\x81" + size + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))

    def receive(self):
        result = bytearray()
        while True:
            op, size = self.take(2)
            if size == 126: size = struct.unpack("!H", self.take(2))[0]
            elif size == 127: size = struct.unpack("!Q", self.take(8))[0]
            result.extend(self.take(size))
            if op & 0x80: return json.loads(result)

    def run(self):
        try:
            while True:
                message = self.receive().get("message")
                if isinstance(message, str): self.messages.append(message)
        except (OSError, EOFError, ValueError): pass

    def close(self):
        time.sleep(1)
        self.sock.close(); self.thread.join(5)
        return self.messages


def normalize(text, base):
    text = text.replace(base, "http://SERVER")
    text = re.sub(r'<meta name="csrf-(?:param|token)" content="[^"]*" ?/?>', "", text)
    text = re.sub(r'<input type="hidden" name="authenticity_token" value="[^"]*"[^>]*>', "", text)
    text = re.sub(r'(?:data-sorted-list-number|data-message-timestamp|data-message-updated-at)="\d+"', "TIME", text)
    text = re.sub(r"/users/[^/\"]+/avatar\?v=\d+", "/users/AVATAR/avatar?v=VERSION", text)
    text = re.sub(r"/users/[^/\"]+/avatar\b", "/users/AVATAR/avatar", text)
    text = re.sub(r'signed-stream-name="[^"]*"', 'signed-stream-name="SIGNED"', text)
    text = re.sub(r'(sgid=")[^"]*', r"\1SGID", text)
    return text


def page_events(text, base):
    return CanonicalHTML(normalize(text, base), "http://unused.invalid").events


def body_of(text, base):
    """The page's <body>, which is what the rooms area renders; the layout head is the views' and assets' concern."""
    events = page_events(text, base)
    start = next((i for i, e in enumerate(events) if e[:2] == ("start", "body")), 0)
    title = next((events[i + 1] for i, e in enumerate(events) if e[:2] == ("start", "title")), None)
    return [title] + events[start:]


def scenario(server):
    """The requests both servers answer, as (label, kind, value) records."""
    out = []
    admin, bob, cara = Client(server), Client(server), Client(server)

    def record(label, response, kind="page", client=None):
        status, headers, body = response
        base = (client or admin).base
        if os.environ.get("DUMP"):
            folder = Path(os.environ["DUMP"]) / server.image.replace("/", "_").replace(":", "_"); folder.mkdir(parents=True, exist_ok=True)
            (folder / (re.sub(r"[^a-z0-9]+", "_", label) + ".html")).write_text(f"{status} {headers.get('location', '')}\n{body}")
        location = headers.get("location", "")
        if location: location = location.replace(base, "http://SERVER")
        if kind == "page":
            value = (status, location, body_of(body, base) if status == 200 else None)
        elif kind == "fragment":
            value = (status, location, (body_of(body, base) if "<body" in body else page_events(body, base)) if status == 200 else None)
        elif kind == "json":
            value = (status, json.loads(normalize(body, base)) if status == 200 else None,
                     headers.get("x-total-count"), normalize(headers.get("link", ""), base))
        else:
            value = (status, location)
        out.append((label, kind, value))
        # Rails' "Room not found or inaccessible" alert shows on the next page; this server keeps no flash.
        if location == "http://SERVER/": (client or admin).request("/users/me/sidebar")
        return response

    def room_of(response):
        tail = response[1].get("location", "").rstrip("/").rsplit("/", 1)[-1]
        return int(tail) if tail.isdigit() else 0

    admin.request("/first_run")
    assert admin.request("/first_run", {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test", "user[password]": "admin password 123"})[0] in (302, 303)
    code = re.search(r"/join/([A-Za-z0-9-]+)", admin.request("/account/edit")[2])[1]
    for client, name, email in ((bob, "Bob Builder", "bob@example.test"), (cara, "cara member", "cara@example.test")):
        client.request(f"/join/{code}")
        assert client.request(f"/join/{code}", {"user[name]": name, "user[email_address]": email, "user[password]": "member password 123"})[0] in (302, 303)
    admin.request("/account/bots/new")
    assert admin.request("/account/bots", {"user[name]": "Robo Bot", "user[webhook_url]": ""})[0] in (302, 303)
    # Both servers number a fresh database's users in the order they were made.
    ids = {"ada": 1, "bob": 2, "cara": 3, "robo": 4}
    record("sidebar cara few users", cara.request("/users/me/sidebar"), "fragment", cara)
    # Enough people for the filter field, the placeholders' limit and a second page of suggestions.
    for n in range(18):
        extra = Client(server)
        extra.request(f"/join/{code}")
        assert extra.request(f"/join/{code}", {"user[name]": f"Extra {'zyxwvutsrqponmlkji'[n]}{n:02}", "user[email_address]": f"extra{n}@example.test", "user[password]": "member password 123"})[0] in (302, 303)

    listeners = {"admin": Listener(admin), "bob": Listener(bob)}

    # Open rooms: new, create, show, edit (administrator and member), update and conversion.
    record("opens/new", admin.request("/rooms/opens/new"))
    created = record("opens#create", admin.request("/rooms/opens", {"room[name]": "Lounge"}), "redirect")
    lounge = room_of(created)
    record("opens#show", admin.request(f"/rooms/opens/{lounge}"), "redirect")
    record("opens/edit admin", admin.request(f"/rooms/opens/{lounge}/edit"))
    record("opens/edit member", bob.request(f"/rooms/opens/{lounge}/edit"), client=bob)
    record("opens#update member", bob.request(f"/rooms/opens/{lounge}", {"_method": "patch", "room[name]": "Mine"}), "redirect", bob)
    record("opens#update no room", admin.request(f"/rooms/opens/{lounge}", {"_method": "patch"}), "redirect")
    record("opens#update", admin.request(f"/rooms/opens/{lounge}", {"_method": "patch", "room[name]": "Lounge <2>"}), "redirect")
    record("opens#create member", bob.request("/rooms/opens", {"room[name]": "Bob's"}), "redirect", bob)
    record("opens#create no room", admin.request("/rooms/opens", {"other": "x"}), "redirect")
    record("closeds/edit of open", admin.request(f"/rooms/closeds/{lounge}/edit"))
    record("closeds/new", admin.request("/rooms/closeds/new"))
    record("closeds#update of open", admin.request(f"/rooms/closeds/{lounge}", {"_method": "patch", "room[name]": "Closed lounge", "user_ids[]": [ids["ada"], ids["bob"]]}), "redirect")
    record("opens/edit of closed", admin.request(f"/rooms/opens/{lounge}/edit"))
    record("opens#update of closed", admin.request(f"/rooms/opens/{lounge}", {"_method": "patch", "room[name]": "Open again"}), "redirect")
    secret = room_of(bob.request("/rooms/closeds", {"room[name]": "Bob only", "user_ids[]": [ids["bob"]]}))
    record("opens/edit not a member", admin.request(f"/rooms/opens/{secret}/edit"), "redirect")
    record("opens#update not a member", admin.request(f"/rooms/opens/{secret}", {"_method": "patch", "room[name]": "Taken"}), "redirect")
    record("opens#show not a member", admin.request(f"/rooms/opens/{secret}"), "redirect")
    record("opens/edit missing", admin.request("/rooms/opens/999999/edit"), "redirect")

    # Pings.
    record("directs/new", admin.request("/rooms/directs/new"), "fragment")
    ping = record("directs#create", admin.request("/rooms/directs", {"user_ids[]": [ids["bob"]]}), "redirect")
    direct = room_of(ping)
    record("directs#create again", admin.request(f"/rooms/directs?user_ids%5B%5D={ids['bob']}", {}), "redirect")
    record("directs/edit", admin.request(f"/rooms/directs/{direct}/edit"))
    record("directs#show", admin.request(f"/rooms/directs/{direct}"), "redirect")
    record("opens/edit of direct", admin.request(f"/rooms/opens/{direct}/edit"), "redirect")
    record("opens#update of direct", admin.request(f"/rooms/opens/{direct}", {"_method": "patch", "room[name]": "Promoted"}), "redirect")
    record("closeds/edit of direct", admin.request(f"/rooms/closeds/{direct}/edit"), "redirect")
    record("directs/edit of open", admin.request(f"/rooms/directs/{lounge}/edit"), "redirect")
    record("directs#destroy of open", admin.request(f"/rooms/directs/{lounge}", {"_method": "delete"}), "redirect")
    record("directs#create bot", admin.request("/rooms/directs", {"user_ids[]": [ids["robo"]]}), "redirect")
    self_ping = record("directs#create self", admin.request("/rooms/directs", {}), "redirect")
    record("directs/edit self", admin.request(f"/rooms/directs/{room_of(self_ping)}/edit"))
    group = room_of(record("directs#create group", admin.request("/rooms/directs", {"user_ids[]": [ids["bob"], ids["cara"]]}), "redirect"))
    record("directs/edit group", admin.request(f"/rooms/directs/{group}/edit"))
    record("sidebar admin", admin.request("/users/me/sidebar"), "fragment")
    record("sidebar cara", cara.request("/users/me/sidebar"), "fragment", cara)
    record("directs#destroy member", bob.request(f"/rooms/directs/{group}", {"_method": "delete"}), "redirect", bob)
    record("directs#destroy again", admin.request(f"/rooms/directs/{group}", {"_method": "delete"}), "redirect")
    record("users/show bot", admin.request(f"/users/{ids['robo']}"))

    # Autocomplete, as the Ping and mentions inputs ask for it.
    for label, path, accept in (("all", "/autocompletable/users", "application/json"), ("query", "/autocompletable/users?query=b", "application/json"),
                                ("filter", "/autocompletable/users?filter=CARA&query=b", "application/json"),
                                ("room", f"/autocompletable/users?room_id={lounge}", "application/json"),
                                ("page 2", "/autocompletable/users?query=e&page=2", "application/json"),
                                ("page 1 of 2", "/autocompletable/users.json?query=e&zeta=1", "*/*"),
                                ("html accept", "/autocompletable/users?query=b", "text/html, application/json")):
        record(f"autocomplete {label}", admin.request(path, headers={"Accept": accept}), "fragment" if accept.startswith("text/html") else "json")
    record("autocomplete prompt", admin.request(f"/autocompletable/users?room_id={lounge}&filter=a"), "fragment")
    record("autocomplete prompt all", admin.request("/autocompletable/users?filter=o"), "fragment")
    record("autocomplete prompt missing room", admin.request("/autocompletable/users?room_id=999999"), "redirect")

    # Deleting rooms: an open room from its edit page, by a member and by its creator.
    doomed = room_of(bob.request("/rooms/opens", {"room[name]": "Doomed"}))
    record("rooms#destroy member", cara.request(f"/rooms/{doomed}", {"_method": "delete"}), "redirect", cara)
    record("rooms#destroy creator", bob.request(f"/rooms/{doomed}", {"_method": "delete"}), "redirect", bob)

    # The sidebar streams' broadcasts, in order, as parsed HTML.
    for name, listener in listeners.items():
        out.append((f"broadcasts to {name}", "rows", [page_events(m, admin.base) for m in listener.close()]))

    # Room creation restricted to administrators: the account setting, written while the server is stopped.
    server.stop()
    server.sql("UPDATE accounts SET settings=?", json.dumps({"restrict_room_creation_to_administrators": True}))
    server.start()
    record("opens/new restricted", bob.request("/rooms/opens/new"), "redirect", bob)
    record("opens#create restricted", bob.request("/rooms/opens", {"room[name]": "Nope"}), "redirect", bob)
    record("closeds/new restricted", bob.request("/rooms/closeds/new"), "redirect", bob)
    record("opens/new restricted admin", admin.request("/rooms/opens/new"))
    record("opens/edit member restricted", bob.request(f"/rooms/opens/{lounge}/edit"), client=bob)
    server.stop()
    out.append(("rooms", "rows", server.sql("SELECT id,name,type,creator_id FROM rooms ORDER BY id")))
    out.append(("memberships", "rows", server.sql("SELECT room_id,user_id,involvement FROM memberships ORDER BY room_id,user_id")))
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--reference", default="once-campfire-verification:reference-90b3300")
    parser.add_argument("--only", help="run against one image and print its records")
    args = parser.parse_args()
    secret = secrets.token_hex(64)
    results = {}
    with tempfile.TemporaryDirectory(prefix="campfire-compare-rooms-") as directory:
        images = (("rails", args.reference), ("goose", args.image))
        if args.only: images = [(label, image) for label, image in images if label == args.only]
        for label, image in images:
            server = Server(image, secret, Path(directory) / label)
            try:
                results[label] = scenario(server)
            finally:
                subprocess.run(["docker", "rm", "-f", server.name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                log = Path(directory) / label / "server.log"
                if log.exists() and os.environ.get("SHOW_LOGS"): print(log.read_text()[-4000:])
        if args.only:
            for label, kind, value in results[args.only]:
                print(label, kind, json.dumps(value, ensure_ascii=False)[:3000])
            return
    failures = 0
    for (label, kind, a), (other, _, b) in zip(results["rails"], results["goose"]):
        assert label == other
        if a == b:
            print(f"PASS: {label} ({kind})")
            continue
        failures += 1
        if kind in ("page", "fragment") and a[2] is not None and b[2] is not None and a[:2] == b[:2]:
            x, y = a[2], b[2]
            at = next(i for i, (p, q) in enumerate(zip(x + [None], y + [None])) if p != q)
            print(f"FAIL: {label} differs at event {at} of {len(x)}/{len(y)}\n  rails: {x[at:at + 4]}\n  goose: {y[at:at + 4]}")
        elif kind == "rows" and label.startswith("broadcasts"):
            at = next(i for i, (p, q) in enumerate(zip(a + [None], b + [None])) if p != q)
            print(f"FAIL: {label}: {len(a)}/{len(b)} broadcasts, differing at {at}\n  rails: {str(a[at:at + 1])[:1500]}\n  goose: {str(b[at:at + 1])[:1500]}")
        else:
            print(f"FAIL: {label}\n  rails: {str(a)[:1500]}\n  goose: {str(b)[:1500]}")
    print(f"{len(results['rails']) - failures} of {len(results['rails'])} match Rails")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
