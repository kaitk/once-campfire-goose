#!/usr/bin/env python3
"""Differential checks of the profile, account settings, custom styles, bots and QR codes against the Rails
reference image: the same requests, with the same secret, to Rails and to this server, compared by status,
redirect, flash and page markup as parsed HTML. Needs Docker and the reference image:

    python3 compare_ui_account.py once-campfire-goose:account-app [--reference once-campfire-verification:reference-a05ee90] [--keep DIR]
"""
import argparse
import base64
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import socket
import sqlite3
import subprocess
import tempfile
import time
from urllib.parse import urlencode
import uuid

from compare_rendering import CanonicalHTML
from test_uploads import multipart, png

ENV = {"RAILS_ENV": "production", "DISABLE_SSL": "true", "SKIP_TELEMETRY": "true", "APP_VERSION": "parity", "GIT_REVISION": "parity",
       "WEB_CONCURRENCY": "1", "RAILS_MAX_THREADS": "5", "JOB_CONCURRENCY": "1", "RAILS_LOG_LEVEL": "warn"}
SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"


class Server:
    def __init__(self, image, secret, work):
        self.work = work
        self.name = "campfire-account-" + uuid.uuid4().hex[:10]
        for folder in ("db", "files", "logs"):
            (work / folder).mkdir(parents=True); os.chmod(work / folder, 0o777)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0)); self.port = probe.getsockname()[1]
        env = work / "env"
        env.write_text("".join(f"{k}={v}\n" for k, v in dict(ENV, SECRET_KEY_BASE=secret, HTTP_PORT="3000", TARGET_PORT="3001").items()))
        command = ["docker", "run", "-d", "--name", self.name, "-p", f"127.0.0.1:{self.port}:3000", "--env-file", str(env)]
        for folder in ("db", "files", "logs"): command += ["-v", f"{work / folder}:/rails/storage/{folder}"]
        subprocess.run(command + [image], check=True, stdout=subprocess.DEVNULL)
        for _ in range(600):
            try:
                if Client(self).request("/up")[0] == 200: break
            except (OSError, http.client.HTTPException): pass
            time.sleep(.1)
        else: raise RuntimeError(f"{image} did not start")

    def sql(self, query, *args):
        with sqlite3.connect(self.work / "db/production.sqlite3", timeout=10) as db:
            return db.execute(query, args).fetchall()

    def close(self):
        logs = subprocess.run(["docker", "logs", self.name], capture_output=True, text=True)
        (self.work / "server.log").write_text(logs.stdout + logs.stderr)
        subprocess.run(["docker", "rm", "-f", self.name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Client:
    def __init__(self, server):
        self.server, self.cookies = server, {}

    def request(self, path, data=None, method=None, headers=None, kind="application/x-www-form-urlencoded"):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.port, timeout=60)
        fields = {"Sec-Fetch-Site": "same-origin", "Host": f"127.0.0.1:{self.server.port}", "User-Agent": SAFARI}
        if self.cookies: fields["Cookie"] = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
        body = None
        if data is not None:
            body = urlencode(data) if isinstance(data, (dict, list)) else data
            fields["Content-Type"] = kind
        fields.update(headers or {})
        connection.request(method or ("GET" if data is None else "POST"), path, body, fields)
        response = connection.getresponse()
        for cookie in response.msg.get_all("Set-Cookie") or []:
            name, _, value = cookie.split(";", 1)[0].partition("=")
            if "max-age=0" in cookie.lower() or "expires=thu, 01 jan 1970" in cookie.lower(): self.cookies.pop(name, None)
            else: self.cookies[name] = value
        result = response.status, {k.lower(): v for k, v in response.getheaders()}, response.read()
        connection.close()
        return result


def body_of(page):
    """The title and the page from <nav> on."""
    start = page.find('<nav id="nav">')
    title = re.search(r"<title>.*?</title>", page, re.S)
    return (title[0] if title else "") + (page[start:] if start >= 0 else page)


# The head (stylesheets, importmap, CSP meta) is the shared layout's: it is compared on these pages only, as
# a row of its own, so that one head difference doesn't stand in front of every page's body differences.
HEAD_PAGES = ("profile", "account edit", "bots", "custom styles")


def head_of(page):
    head = re.search(r"<head>.*?</head>", page, re.S)
    return head[0] if head else ""


def normalize(text, server):
    text = re.sub(r'(/session/transfers/)[^"/<\s]+', r"\1TRANSFER", text)
    text = re.sub(r'/qr_code/[A-Za-z0-9_=-]+', "/qr_code/QR", text)
    text = re.sub(r'(/join/)[A-Za-z0-9-]+', r"\1CODE", text)
    text = re.sub(r'/users/[A-Za-z0-9_=-]{20,}--[0-9a-f]+/avatar', "/users/AVATAR/avatar", text)
    text = re.sub(r'(\?v=)\d+', r"\1VERSION", text)
    text = re.sub(r'/rails/active_storage/blobs/redirect/[^"]+', "/rails/active_storage/blobs/redirect/BLOB", text)
    text = re.sub(r'(/messages/|/\d+-)[A-Za-z0-9]{12}(/messages)', r"\1KEY\2", text)
    text = re.sub(r'(/rooms/\d+/\d+-)[A-Za-z0-9]{12}', r"\1KEY", text)
    return text.replace(f"127.0.0.1:{server.port}", "SERVER")


def scenario(server):
    """Runs the same steps against a server; returns [(label, status, location, markup)]."""
    results = []
    ada, bob = Client(server), Client(server)

    def record(label, response, client=None, page=True):
        status, headers, body = response
        location = headers.get("location", "")
        # Rails redirects to absolute URLs.
        location = re.sub(r"^https?://[^/]+", "ABSOLUTE:", location)
        text = body.decode("utf8", "replace")
        if page and status == 200 and "text/html" in headers.get("content-type", ""):
            if label in HEAD_PAGES: results.append((label + " head", status, "", normalize(head_of(text), server)))
            text = body_of(text)
        elif status != 200: text = ""
        results.append((label, status, location, normalize(text, server)))
        return response

    def follow(label, client, response):
        record(label, response)
        status, headers, _ = response
        if status in (301, 302, 303):
            record(label + " (followed)", client.request(re.sub(r"^https?://[^/]+", "", headers["location"])))

    ada.request("/first_run")
    status, _, _ = ada.request("/first_run", {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test", "user[password]": "admin password 123"})
    assert status in (302, 303), status
    # A bind mount shares no WAL index with the container, so state is read through pages, and ids are the
    # first ones each table hands out.
    code = re.search(r'/join/([A-Za-z0-9-]+)"', ada.request("/account/edit")[2].decode())[1]
    bob.request(f"/join/{code}")
    status, _, _ = bob.request(f"/join/{code}", {"user[name]": "Bob Member", "user[email_address]": "bob@example.test", "user[password]": "member password 123"})
    assert status in (302, 303), status
    bob_id, room = 2, 1
    ada.request(f"/rooms/{room}")
    ada.request("/rooms/directs", {"user_ids[]": bob_id})

    # The profile, and its updates.
    record("profile", ada.request("/users/me/profile"))
    record("profile by id", ada.request(f"/users/{bob_id}/profile"))
    token = re.search(r"/session/transfers/([^\"]+)\"", ada.request("/users/me/profile")[2].decode())[1]
    payload = token.split("--")[0]
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))["_rails"]
    # generates_token_for :transfer: data is [id, the last 10 characters of the bcrypt salt], signed with HMAC-SHA1.
    # The salt is random per run, so its length and alphabet are compared, not its value.
    ident, salt = claims["data"] if isinstance(claims["data"], list) and len(claims["data"]) == 2 else (claims["data"], "")
    results.append(("transfer claims", 200, "", repr((sorted(claims), ident, len(salt), bool(re.fullmatch(r"[./A-Za-z0-9]{10}", salt)),
                                                       claims["pur"], len(claims["exp"]), len(token.split("--")[1])))))
    follow("profile name and bio", ada, ada.request("/users/me/profile", [("_method", "patch"), ("user[name]", "Ada Lovelace"), ("user[bio]", "Counts <things> & more")]))
    follow("profile email", ada, ada.request("/users/me/profile", [("_method", "patch"), ("user[email_address]", "ada2@example.test")]))
    follow("profile invalid email", ada, ada.request("/users/me/profile", [("_method", "patch"), ("user[email_address]", "not an email")]))
    record("profile duplicate email", ada.request("/users/me/profile", [("_method", "patch"), ("user[email_address]", "bob@example.test")]))
    record("profile after duplicate", ada.request("/users/me/profile"))
    follow("profile email restored", ada, ada.request("/users/me/profile", [("_method", "patch"), ("user[email_address]", "ada@example.test")]))
    follow("profile blank password", ada, ada.request("/users/me/profile", [("_method", "patch"), ("user[password]", "")]))
    signin = Client(server)
    signin.request("/session/new")
    # Sessions are the sign-in area's: only whether the password worked is compared here.
    results.append(("sign in with unchanged password", signin.request("/session", {"email_address": "ada@example.test", "password": "admin password 123"})[0], "", ""))
    # Changing the password asks for the current one, and a refused change saves nothing, the name included.
    follow("profile password without the current one", ada, ada.request("/users/me/profile", [("_method", "patch"), ("user[name]", "Ada Nameless"), ("user[password]", "new password 456")]))
    follow("profile password with a wrong current one", ada, ada.request("/users/me/profile", [("_method", "patch"), ("user[name]", "Ada Wrong"), ("user[password]", "new password 456"), ("user[password_challenge]", "not it")]))
    record("profile after the refused changes", ada.request("/users/me/profile"))
    follow("profile password", ada, ada.request("/users/me/profile", [("_method", "patch"), ("user[name]", "Ada Admin"), ("user[password]", "new password 456"), ("user[password_challenge]", "admin password 123")]))
    signin = Client(server)
    signin.request("/session/new")
    # Sessions are the sign-in area's: only whether the password worked is compared here.
    results.append(("sign in with new password", signin.request("/session", {"email_address": "ada@example.test", "password": "new password 456"})[0], "", ""))
    record("profile empty name", ada.request("/users/me/profile", [("_method", "patch"), ("user[name]", "")]))
    record("profile with empty name", ada.request("/users/me/profile"))
    follow("profile name restored", ada, ada.request("/users/me/profile", [("_method", "patch"), ("user[name]", "Ada Admin")]))
    follow("profile long password", ada, ada.request("/users/me/profile", [("_method", "patch"), ("user[password]", "x" * 80), ("user[password_challenge]", "new password 456")]))
    signin = Client(server)
    signin.request("/session/new")
    # Sessions are the sign-in area's: only whether the password worked is compared here.
    results.append(("sign in with long password", signin.request("/session", {"email_address": "ada@example.test", "password": "x" * 80})[0], "", ""))
    follow("profile password restored", ada, ada.request("/users/me/profile", [("_method", "patch"), ("user[password]", "new password 456"), ("user[password_challenge]", "new password 456")]))
    record("profile post", ada.request("/users/me/profile", [("user[name]", "Posted")]))
    record("profile edit", ada.request("/users/me/profile/edit"))
    record("profile delete", ada.request("/users/me/profile", [("_method", "delete")]))
    record("profile without user", ada.request("/users/me/profile", [("_method", "patch"), ("name", "x")]))
    record("profile as member", bob.request("/users/me/profile"))

    # Account settings.
    record("account edit", ada.request("/account/edit"))
    record("account edit member", bob.request("/account/edit"))
    record("account show", ada.request("/account"))
    follow("account name", ada, ada.request("/account", [("_method", "patch"), ("account[name]", "Fire & <Ice>")]))
    follow("account name with format", ada, ada.request("/account.1", [("_method", "patch"), ("account[name]", "Fire & <Ice>")]))
    record("account create", ada.request("/account", [("account[name]", "Posted")]))
    follow("account restrict rooms", ada, ada.request("/account", [("_method", "put"), ("account[settings][restrict_room_creation_to_administrators]", "true")]))
    results.append(("room creation as member", bob.request("/rooms/closeds/new")[0], "", ""))
    record("account edit restricted", ada.request("/account/edit"))
    record("account unknown setting", ada.request("/account", [("_method", "put"), ("account[settings][colour]", "red")]))
    record("account without params", ada.request("/account", [("_method", "patch"), ("name", "x")]))
    record("account update member", bob.request("/account", [("_method", "patch"), ("account[name]", "Bob's")]))
    follow("account unrestrict rooms", ada, ada.request("/account", [("_method", "put"), ("account[settings][restrict_room_creation_to_administrators]", "false")]))
    results.append(("room creation as member again", bob.request("/rooms/closeds/new")[0], "", ""))
    follow("join code", ada, ada.request("/account/join_code", {}))
    follow("role update", ada, ada.request(f"/account/users/{bob_id}", [("_method", "patch"), ("user[role]", "member"), ("user[role]", "administrator")]))
    record("users stream", ada.request("/account/users?page=1", headers={"Accept": "text/vnd.turbo-stream.html, text/html"}), page=False)
    follow("role update back", ada, ada.request(f"/account/users/{bob_id}", [("_method", "patch"), ("user[role]", "member")]))
    body, kind = multipart([("_method", "patch"), ("account[logo]", ("logo.png", "image/png", png(64, 64)))])
    follow("logo upload", ada, ada.request("/account.1", body, kind=kind))
    status, headers, page = ada.request("/account/edit")
    logo = re.search(r'<form class="button_to" method="post" action="(/account/logo[^"]*)"', page.decode())
    follow("logo delete", ada, ada.request(logo[1].replace("&amp;", "&"), [("_method", "delete")]))

    # Custom styles.
    record("custom styles", ada.request("/account/custom_styles/edit"))
    record("custom styles member", bob.request("/account/custom_styles/edit"))
    css = "body > main { color: \"red\"; } a[href^='x'] { }"
    follow("custom styles update", ada, ada.request("/account/custom_styles", [("_method", "patch"), ("account[custom_styles]", css)]))
    status, headers, page = ada.request("/users/me/profile")
    results.append(("custom styles on profile", status, "", re.search(r"<style[^>]*>.*?</style>", page.decode(), re.S)[0]))
    record("custom styles without params", ada.request("/account/custom_styles", [("_method", "patch"), ("x", "y")]))

    # Bots.
    record("bots", ada.request("/account/bots"))
    record("bots member", bob.request("/account/bots"))
    record("bot new", ada.request("/account/bots/new"))
    follow("bot create", ada, ada.request("/account/bots", [("user[name]", "Hooky"), ("user[webhook_url]", "https://example.test/hook")]))
    follow("bot create plain", ada, ada.request("/account/bots", [("user[name]", "Plain")]))
    bot, plain = 3, 4
    record("bot edit", ada.request(f"/account/bots/{bot}/edit"))
    follow("bot update", ada, ada.request(f"/account/bots/{bot}", [("_method", "patch"), ("user[name]", "Hooky 2"), ("user[webhook_url]", "")]))
    record("bot edit after update", ada.request(f"/account/bots/{bot}/edit"))
    keys = lambda: re.findall(rf"/{bot}-([A-Za-z0-9]{{12}})/messages", ada.request("/account/bots")[2].decode())
    before = keys()
    follow("bot key reset", ada, ada.request(f"/account/bots/{bot}/key", [("_method", "patch")]))
    after = keys()
    results.append(("bot key changed", 200, "", repr(bool(before) and bool(after) and set(before).isdisjoint(after))))
    record("bot key reset member", bob.request(f"/account/bots/{bot}/key", [("_method", "put")]))
    record("bot show", ada.request(f"/account/bots/{bot}"))
    follow("bot delete", ada, ada.request(f"/account/bots/{plain}", [("_method", "delete")]))
    record("bot edit deleted", ada.request(f"/account/bots/{plain}/edit"))
    record("bot delete member", bob.request(f"/account/bots/{bot}", [("_method", "delete")]))
    body, kind = multipart([("user[name]", "Pic"), ("user[webhook_url]", ""), ("user[avatar]", ("bot.png", "image/png", png(64, 64)))])
    follow("bot create with avatar", ada, ada.request("/account/bots", body, kind=kind))
    record("bot edit with avatar", ada.request("/account/bots/5/edit"))
    record("user page", ada.request(f"/users/{bob_id}"))

    # QR codes are public.
    anonymous = Client(server)
    for url in ("http://example.test/join/ABCD-EFGH-IJKL", "https://campfire.example.com/session/transfers/eyJfcmFpbHMiOnsiZGF0YSI6MSwiZXhwIjoiMjAyNi0xMS0wM1QxMjowMDowMC4wMDBaIiwicHVyIjoidXNlci90cmFuc2ZlciJ9fQ==--0123456789abcdef0123456789abcdef01234567", "a", "HELLO 123", "0123456789"):
        status, headers, body = anonymous.request("/qr_code/" + base64.urlsafe_b64encode(url.encode()).decode())
        results.append((f"qr code {url[:20]}", status, headers.get("content-type", "") + " " + headers.get("cache-control", ""), body.decode()))
    status, headers, body = anonymous.request("/qr_code/" + base64.urlsafe_b64encode(b"unpadded").decode().rstrip("="))
    results.append(("qr code unpadded", status, headers.get("content-type", ""), body.decode()))
    record("qr code invalid", anonymous.request("/qr_code/%21%21"))

    # Push subscriptions (the development page).
    record("push subscriptions", ada.request("/users/me/push_subscriptions"))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--reference", default="once-campfire-verification:reference-a05ee90")
    parser.add_argument("--keep", type=Path)
    parser.add_argument("--only", choices=("rails", "goose"))
    args = parser.parse_args()
    secret = secrets.token_hex(64)
    results = {}
    with tempfile.TemporaryDirectory(prefix="campfire-compare-account-") as directory:
        for label, image in (("rails", args.reference), ("goose", args.image)):
            if args.only and args.only != label: continue
            server = Server(image, secret, Path(directory) / label)
            try: results[label] = scenario(server)
            finally:
                server.close()
                if args.keep:
                    (args.keep / label).mkdir(parents=True, exist_ok=True)
                    (args.keep / label / "server.log").write_text((server.work / "server.log").read_text())
        if args.keep:
            for label, steps in results.items():
                for i, (name, status, location, text) in enumerate(steps):
                    (args.keep / label / f"{i:02d} {re.sub(r'[^A-Za-z0-9 ()]', '_', name)}.txt").write_text(f"{status} {location}\n{text}")
    if len(results) < 2: return
    failures = 0
    for (name, status, location, text), (_, status2, location2, text2) in zip(results["rails"], results["goose"]):
        if (status, location) != (status2, location2):
            failures += 1; print(f"FAIL: {name}: rails {status} {location!r}, goose {status2} {location2!r}"); continue
        if name.startswith("qr code") or "<" not in text:
            if text == text2: print(f"PASS: {name}: {status} {location}")
            else: failures += 1; print(f"FAIL: {name}\n  rails: {text[:300]!r}\n  goose: {text2[:300]!r}")
            continue
        a, b = CanonicalHTML(text, "http://unused.invalid").events, CanonicalHTML(text2, "http://unused.invalid").events
        if a == b: print(f"PASS: {name}: {status} {location} ({len(a)} HTML events)")
        else:
            at = next(i for i, (p, q) in enumerate(zip(a + [None], b + [None])) if p != q)
            failures += 1; print(f"FAIL: {name} differs at event {at}\n  rails: {a[max(0, at - 1):at + 3]}\n  goose: {b[max(0, at - 1):at + 3]}")
    print(f"{len(results['rails']) - failures} of {len(results['rails'])} steps match Rails")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
