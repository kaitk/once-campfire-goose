#!/usr/bin/env python3
"""Sign-in, first run, join, sign-out, HTTPS deployments, version headers and browser checks, as in Rails."""

import base64
import hashlib
import hmac
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
import zlib
from urllib.parse import urlencode

MODERN = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
OLD_FIREFOX = "Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:115.0) Gecko/20100101 Firefox/115.0"
APPLE_MESSAGES = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 facebookexternalhit/1.1 Twitterbot/1.0"

# User-Agents and whether Rails' allow_browser (the useragent gem) blocks them, from the Rust port's
# vectors/campfire_user_agents.json, which the gem produced.
USER_AGENTS = [
    ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15', True),
    ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 (KHTML, like Gecko) Version/9.0.1 Safari/601.2.4 facebookexternalhit/1.1 Facebot Twitterbot/1.0', True),
    ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/abc Safari/605.1.15', True),
    ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 (KHTML, like Gecko) Version/9.0.1 Safari/601.2.4 facebooKexternalhit/1.1 Facebot Twitterbot/1.0', True),
    ('Mozilla/5.0 (Macintosh; U; PPC Mac OS X; en) AppleWebKit/125.2 (KHTML, like Gecko) Safari/125.8', True),
    ('Mozilla/5.0 (X11; CrOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0', True),
    ('Opera/8.0 (Windows NT 5.1; U; en)', True),
    ('Opera/9.64 (X11; Linux i686; U; en) Presto/2.1.1', True),
    ('Mozilla/5.0 (Linux; Android 12; HarmonyOS; NOH-AN00; HMSCore 6.13.0.302) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.5735.196 HuaweiBrowser/15.0.4.312 Mobile Safari/537.36', True),
    ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2beta Safari/605.1.15', True),
    ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1.2 Safari/605.1.15', True),
    ('Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Mobile Safari/537.36 OPR/91.0.0.0', True),
    ('Mozilla/5.0 (Linux; Android 13; SAMSUNG SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/23.0 Chrome/115.0.0.0 Mobile Safari/537.36', True),
    ('Mozilla/5.0 (Linux; U; Android 13; en-us; 2201117TG Build/TKQ1.221114.001) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/112.0.5615.136 Mobile Safari/537.36 XiaoMi/MiuiBrowser/14.5.1-gn', True),
    ('Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)', True),
    ('Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 EdgiOS/124.2478.50 Mobile/15E148 Safari/605.1.15', True),
    ('Mozilla/5.0 (iPad; CPU OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/119.0.6045.169 Mobile/15E148 Safari/604.1', True),
    ('Mozilla/5.0 (Windows; U; Windows NT 6.1; en-US) AppleWebKit/534.57.2 (KHTML, like Gecko) Version/5.1.7 Safari/534.57.2', True),
    ('Mozilla/5.0 (Windows NT 5.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/49.0.2623.112 Safari/537.36', True),
    ('Mozilla/5.0 (Windows; U; Windows NT 5.1; en-US; rv:1.8.1.20) Gecko/20081217 Firefox/2.0.0.20', True),
    ('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1 OPT/5.0.3', True),
    ('Opera/9.80 (Macintosh; Intel Mac OS X 10.6.8; U; en) Presto/2.9.168 Version/11.52', True),
    ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 (KHTML, like Gecko) Version/9.0.1 Safari/601.2.4 facebookexternalhit/1.1 Facebot Twitterbot/1.0', True),
    ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_9_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.113 Safari/537.36', True),
    ('chrome/200', False),
    ('Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/121.0.6167.66 Mobile/15E148 Safari/604.1', False),
    ('AppleCoreMedia/1.0.0.12F69 (Apple TV; U; CPU OS 8_3 like Mac OS X; en_us)', False),
    ('NSPlayer/12.00.9200.16384 WMFSDK/12.00.9200.16384', False),
    ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.71 Safari/537.36', False),
    ('Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)', False),
    ('"""', False),
    ('Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A.240805.005; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/140.0.0.0 Mobile Safari/537.36 Hotwire Native Android; Turbo Native Android; bridge-components: [form menu overflow];', False),
    ('Mozilla/5.0 (PLAYSTATION 3 4.75) AppleWebKit/531.22.8 (KHTML, like Gecko)', False),
    ('Mozilla/5.0,(compatible; Googlebot/2.1)', False),
    ('NSPlayer/10.0.0.3802 WMFSDK/10.0', False),
    ('Go-http-client/1.1', False),
    ('()', False),
    ('Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36', False),
    ('Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Vivaldi/6.5', False),
    ('Mozilla/5.0+(compatible; UptimeRobot/2.0; http://www.uptimerobot.com/)', False),
    ('Mozilla/5.0 (compatible; YandexBot/3.0; +http://yandex.com/bots)', False),
    ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Vivaldi/7.6.3797.52', False),
    ('Safari/17.2 Version/17.2', False),
    ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Vivaldi/6.5.3206.53', False),
    ('Windows-Media-Player', False),
    ('12345', False),
    ('NSPlayer/9.0.0.2980 WMFSDK/9.0', False),
    ('X/1.0 ,gzip(gfe)', False),
]


def png(width, height):
    rows = b"".join(b"\x00" + bytes([200, 40, 40]) * width for _ in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def multipart(fields):
    boundary = "----campfire" + secrets.token_hex(8)
    body = b""
    for name, value in fields:
        body += f"--{boundary}\r\n".encode()
        if isinstance(value, tuple):
            filename, kind, data = value
            body += f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\nContent-Type: {kind}\r\n\r\n'.encode() + data + b"\r\n"
        else:
            body += f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode() + value.encode() + b"\r\n"
    return body + f"--{boundary}--\r\n".encode(), f"multipart/form-data; boundary={boundary}"


def transfer_id(secret, user, digest, purpose="User\ntransfer\n14400", hours=4):
    """User#transfer_id: generate_token_for(:transfer), as Rails writes it: [id, the bcrypt salt's last 10
    characters], expiring in 4 hours, signed with HMAC-SHA1 under app.message_verifier("active_record/token_for")."""
    expiry = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + hours * 3600))
    serialized = json.dumps({"_rails": {"data": [user, digest[7:29][-10:]], "exp": expiry, "pur": purpose}}, separators=(",", ":")).encode()
    payload = base64.urlsafe_b64encode(serialized).rstrip(b"=")
    key = hashlib.pbkdf2_hmac("sha256", secret.encode(), b"active_record/token_for", 1000, 64)
    return payload.decode() + "--" + hmac.new(key, payload, hashlib.sha1).hexdigest()


def old_transfer_id(secret, user):
    """The signed id transfer links carried before generates_token_for: no longer accepted, as in Rails."""
    expiry = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + 4 * 3600))
    serialized = json.dumps({"_rails": {"data": user, "exp": expiry, "pur": "user/transfer"}}, separators=(",", ":")).encode()
    payload = base64.urlsafe_b64encode(serialized).rstrip(b"=")
    key = hashlib.pbkdf2_hmac("sha256", secret.encode(), b"active_record/signed_id", 1000, 64)
    return payload.decode() + "--" + hmac.new(key, payload, hashlib.sha256).hexdigest()


class Server:
    def __init__(self, binary, work, ssl):
        self.work, self.database = work, work / "production.sqlite3"
        self.storage = work / "storage"
        self.storage.mkdir()
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0)); self.port = probe.getsockname()[1]
        self.secret = secrets.token_hex(64)
        env = dict(os.environ, DATABASE_PATH=str(self.database), STORAGE_PATH=str(self.storage), SECRET_KEY_BASE=self.secret,
                   HTTP_PORT=str(self.port), APP_VERSION="test-version", GIT_REVISION="test-revision")
        env.pop("DISABLE_SSL", None)
        if not ssl: env["DISABLE_SSL"] = "true"
        self.log = (work / "server.log").open("w+")
        self.process = subprocess.Popen([str(binary)], env=env, stdout=self.log, stderr=self.log, cwd=Path(__file__).resolve().parent)
        for _ in range(300):
            if self.process.poll() is not None: raise AssertionError("server exited")
            try:
                if self.request("/up")[0] == 200: break
            except OSError: time.sleep(.05)
        else: raise AssertionError("server did not start")
        self.base = f"{'https' if ssl else 'http'}://127.0.0.1:{self.port}"

    def request(self, path, data=None, cookie="", headers=None, method=None, kind="application/x-www-form-urlencoded", agent=MODERN):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        fields = {"Sec-Fetch-Site": "same-origin", "User-Agent": agent.encode()}
        if cookie: fields["Cookie"] = cookie
        if data is not None:
            fields["Content-Type"] = kind
            if isinstance(data, dict): data = urlencode(data)
        fields.update(headers or {})
        connection.request(method or ("GET" if data is None else "POST"), path, data, fields)
        response = connection.getresponse()
        result = response.status, response.msg, response.read().decode("utf8", "replace")
        connection.close()
        return result

    def sql(self, query, *args):
        with sqlite3.connect(self.database, timeout=10) as db:
            return db.execute(query, args).fetchall()

    def close(self):
        self.process.terminate()
        try: self.process.wait(timeout=5)
        except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()

    def dump_log(self):
        self.log.seek(0); print(self.log.read(), file=sys.stderr)


def cookies_of(headers):
    out = {}
    for line in headers.get_all("Set-Cookie") or []:
        name, _, value = line.split(";", 1)[0].partition("=")
        out[name] = (value, line)
    return out


def session_cookie(headers):
    value, _ = cookies_of(headers)["session_token"]
    return "session_token=" + value


def version_headers(headers):
    return headers.get("X-Version"), headers.get("X-Rev")


def plain_http(binary, work):
    server = Server(binary, work, ssl=False)
    base = server.base
    try:
        # A fresh install: every page leads to the first run (request_authentication, ensure_user_exists).
        status, headers, _ = server.request("/")
        assert status == 302 and headers["Location"] == base + "/session/new", (status, dict(headers))
        assert "_campfire_session" in cookies_of(headers) and version_headers(headers) == ("test-version", "test-revision")
        status, headers, _ = server.request("/session/new")
        assert status == 302 and headers["Location"] == base + "/first_run"
        status, headers, page = server.request("/first_run")
        assert status == 200 and "<title>Set up Campfire</title>" in page and '<body class="signup"' in page
        assert 'enctype="multipart/form-data" action="/first_run"' in page and 'name="user[avatar]"' in page and "current-user-id" not in page
        assert 'href="/account/logo"' in page and "Enter your name" in page
        assert server.request("/first_run", {"other": "x"})[0] == 400
        print("PASS: first run is Rails' page, reached through sign-in")

        body, kind = multipart([("user[name]", "Ada Admin"), ("user[email_address]", "ada@example.test"), ("user[password]", "admin password"),
                                ("user[avatar]", ("me.png", "image/png", png(40, 30)))])
        status, headers, _ = server.request("/first_run", body, kind=kind)
        assert status == 302 and headers["Location"] == base + "/", (status, dict(headers))
        admin = session_cookie(headers)
        [(code,)] = server.sql("SELECT join_code FROM accounts")
        assert re.fullmatch(r"[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}", code), code
        assert server.sql("SELECT count(*) FROM active_storage_attachments WHERE record_type='User' AND name='avatar'") == [(1,)]
        assert server.request("/rooms/1", cookie=admin)[0] == 200
        status, headers, _ = server.request("/first_run")
        assert status == 302 and headers["Location"] == base + "/"
        status, headers, _ = server.request("/first_run", {"user[name]": "Again", "user[email_address]": "again@example.test", "user[password]": "x"})
        assert status == 302 and headers["Location"] == base + "/" and "session_token" not in cookies_of(headers)
        assert server.sql("SELECT count(*) FROM users") == [(1,)]
        print("PASS: first run creates the account with an xxxx-xxxx-xxxx join code and the avatar; repeats go to root")

        # Joining: require_unauthenticated_access, the join code, and a taken address to sign in.
        status, headers, _ = server.request(f"/join/{code}", cookie=admin)
        assert status == 302 and headers["Location"] == base + "/"
        status, headers, page = server.request(f"/join/{code}")
        assert status == 200 and "<title>Sign up</title>" in page and 'href="/session/new"' in page and f'action="/join/{code}"' in page
        assert 'href="mailto:&quot;Ada Admin&quot; &lt;ada@example.test&gt;"' in page and '<span class="version-badge">test-version</span>' in page
        status, headers, page = server.request("/join/wrong-code")
        assert status == 404 and page == "" and headers.get("X-Version") == "test-version"
        member = {"user[name]": "Bob Member", "user[email_address]": "bob@example.test", "user[password]": "member password"}
        status, headers, _ = server.request(f"/join/{code}", member)
        assert status == 302 and headers["Location"] == base + "/"
        bob = session_cookie(headers)
        status, headers, _ = server.request(f"/join/{code}", dict(member, **{"user[name]": "Other Bob"}))
        assert status == 302 and headers["Location"] == base + "/session/new?email_address=bob%40example.test"
        assert server.sql("SELECT count(*) FROM users") == [(2,)] and server.sql("SELECT count(*) FROM memberships") == [(2,)]
        print("PASS: join page, signed-in redirect, 404 for a wrong code, and a taken address goes to sign in")

        # Signing in: the page, the rejection, and the URL first asked for.
        status, headers, page = server.request("/session/new?email_address=bob%40example.test")
        assert status == 200 and "<title>Sign in</title>" in page and '<meta name="turbo-visit-control" content="reload">' in page
        assert f'action="{base}/session"' in page and 'value="bob@example.test"' in page and 'class="panel "' in page
        status, headers, _ = server.request("/rooms/1?x=1")
        assert status == 302 and headers["Location"] == base + "/session/new"
        rails_session = cookies_of(headers)["_campfire_session"][0]
        status, headers, page = server.request("/session", {"email_address": "bob@example.test", "password": "wrong"}, cookie="_campfire_session=" + rails_session)
        assert status == 401 and "Too many requests or unauthorized." in page and 'class="panel shake"' in page and 'value="bob@example.test"' in page
        status, headers, _ = server.request("/session", {"email_address": "bob@example.test", "password": "member password"}, cookie="_campfire_session=" + rails_session)
        assert status == 302 and headers["Location"] == base + "/rooms/1?x=1", (status, dict(headers))
        assert cookies_of(headers)["_campfire_session"][0] == "" and server.request("/rooms/1", cookie=session_cookie(headers))[0] == 200
        status, headers, _ = server.request("/session", {"email_address": "bob@example.test", "password": "member password"})
        assert status == 302 and headers["Location"] == base + "/"
        assert server.request("/session", {"email_address": "bob@example.test", "password": "member password"}, headers={"Origin": "http://evil.test"})[0] == 422
        assert server.request("/session", {"email_address": "bob@example.test", "password": "member password"}, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
        print("PASS: sign-in page, 401 with Rails' alert, return to the requested URL, forgery checks")

        # rate_limit to: 10, within: 3.minutes, by remote address.
        attacker = {"X-Forwarded-For": "203.0.113.50"}
        statuses = [server.request("/session", {"email_address": "bob@example.test", "password": "wrong"}, headers=attacker)[0] for _ in range(11)]
        assert statuses == [401] * 10 + [429], statuses
        status, _, page = server.request("/session", {"email_address": "bob@example.test", "password": "member password"}, headers=attacker)
        assert status == 429 and "Too many requests or unauthorized." in page
        assert server.request("/session", {"email_address": "bob@example.test", "password": "member password"}, headers={"X-Forwarded-For": "203.0.113.51"})[0] == 302
        print("PASS: sign-in is rate limited per address with Rails' 429 page")

        # Session transfers: the auto-submitting page, then a session, or 400.
        [(bob_id, bob_digest)] = server.sql("SELECT id,password_digest FROM users WHERE email_address='bob@example.test'")
        link = transfer_id(server.secret, bob_id, bob_digest)
        status, _, page = server.request(f"/session/transfers/{link}")
        assert status == 200 and f'<form data-controller="auto-submit" action="/session/transfers/{link}"' in page and 'name="_method" value="put"' in page
        status, headers, _ = server.request(f"/session/transfers/{link}", {"_method": "put"})
        assert status == 302 and headers["Location"] == base + "/" and server.request("/rooms/1", cookie=session_cookie(headers))[0] == 200
        assert server.request("/session/transfers/nope", {"_method": "put"})[0] == 400
        for refused in (transfer_id(server.secret, bob_id, bob_digest, "User\nother\n14400"), transfer_id(server.secret, bob_id, bob_digest, hours=-1),
                        transfer_id(server.secret, bob_id, "$2a$12$" + "x" * 53), old_transfer_id(server.secret, bob_id)):
            assert server.request(f"/session/transfers/{refused}", {"_method": "put"})[0] == 400
        print("PASS: session transfers sign in with a Rails transfer token and refuse others, old signed ids and other salts")

        # Signing out: the push subscription named, the session, the cookie.
        server_now = "2026-01-01 00:00:00"
        with sqlite3.connect(server.database) as db:
            db.execute("INSERT INTO push_subscriptions(user_id,endpoint,p256dh_key,auth_key,created_at,updated_at) VALUES(?,?,?,?,?,?)",
                       (bob_id, "https://push.example.test/1", "key", "auth", server_now, server_now))
        sessions_before = server.sql("SELECT count(*) FROM sessions WHERE user_id=?", bob_id)[0][0]
        status, headers, _ = server.request("/session", {"_method": "delete", "push_subscription_endpoint": "https://push.example.test/1"}, cookie=bob)
        assert status == 302 and headers["Location"] == base + "/"
        assert cookies_of(headers)["session_token"][0] == "" and "max-age=0" in cookies_of(headers)["session_token"][1]
        assert server.sql("SELECT count(*) FROM push_subscriptions") == [(0,)]
        assert server.sql("SELECT count(*) FROM sessions WHERE user_id=?", bob_id)[0][0] == sessions_before - 1
        assert server.request("/rooms/1", cookie=bob)[0] == 302
        status, headers, _ = server.request("/session", {"_method": "delete"})
        assert status == 302 and headers["Location"] == base + "/session/new"
        print("PASS: sign-out removes the push subscription and the session, and deletes the cookie")

        # AllowBrowser: Rails' unsupported-browser page, after authentication.
        status, headers, page = server.request("/session/new", agent=OLD_FIREFOX)
        assert status == 200 and "<title>Unsupported browser</title>" in page and "Upgrade to a supported web browser" in page
        assert page.count('class="browser flex flex-column"') == 4 and "<span> 17.2+</span>" in page
        assert "<title>Campfire</title>" in server.request("/session/new", agent=APPLE_MESSAGES)[2]
        assert server.request("/rooms/1", agent=OLD_FIREFOX)[0] == 302
        for _ in range(2): assert "Unsupported browser" not in server.request("/rooms/1", cookie=admin)[2]
        status, _, page = server.request("/rooms/1", cookie=admin, agent=OLD_FIREFOX)
        assert status == 200 and "Unsupported browser" in page
        assert "Unsupported browser" in server.request("/webmanifest.json", agent=OLD_FIREFOX)[2]
        wrong = [(agent, blocked) for agent, blocked in USER_AGENTS
                 if ("<title>Unsupported browser" in server.request("/session/new", agent=agent)[2] or
                     "<title>Campfire</title>" in server.request("/session/new", agent=agent)[2]) != blocked]
        assert not wrong, wrong
        print(f"PASS: unsupported browsers get Rails' page, after authentication; {len(USER_AGENTS)} User-Agents judged as the gem does")

        # VersionHeaders on ApplicationController responses only.
        assert version_headers(server.request("/rooms/1", cookie=admin)[1]) == ("test-version", "test-revision")
        assert version_headers(server.request("/webmanifest.json")[1]) == ("test-version", "test-revision")
        assert version_headers(server.request("/up")[1]) == (None, None)
        assert server.request("/up")[1].get("Strict-Transport-Security") is None
        print("PASS: X-Version and X-Rev on controller responses, not on the health check")

        # A TLS proxy in front: X-Forwarded-Proto makes the request HTTPS, and its Origin is accepted.
        proxy = {"X-Forwarded-Proto": "https", "Origin": f"https://127.0.0.1:{server.port}"}
        status, headers, _ = server.request("/rooms/2", headers=proxy)
        assert status == 302 and headers["Location"] == f"https://127.0.0.1:{server.port}/session/new"
        status, headers, _ = server.request("/session", {"email_address": "ada@example.test", "password": "admin password"}, headers=proxy)
        assert status == 302 and headers["Location"] == f"https://127.0.0.1:{server.port}/"
        assert server.request("/session", {"email_address": "ada@example.test", "password": "admin password"}, headers={"X-Forwarded-Proto": "https", "Origin": base})[0] == 422
        status, headers, _ = server.request("/rooms/2", headers={"X-Forwarded-Proto": "https", "X-Forwarded-Host": "chat.example.test"})
        assert headers["Location"] == "https://chat.example.test/session/new"
        page = server.request("/users/me/profile", cookie=admin, headers={"X-Forwarded-Proto": "https"})[2]
        assert f"http://127.0.0.1:{server.port}" not in page
        print("PASS: behind a TLS proxy, X-Forwarded-Proto and X-Forwarded-Host shape URLs and the origin check")
    except BaseException:
        server.dump_log(); raise
    finally:
        server.close()


def default_https(binary, work):
    # Without DISABLE_SSL, as Rails' production: assume_ssl and force_ssl.
    server = Server(binary, work, ssl=True)
    https, origin = server.base, {"Origin": server.base}
    try:
        status, headers, _ = server.request("/up")
        assert status == 200 and headers["Strict-Transport-Security"] == "max-age=63072000; includeSubDomains"
        status, headers, _ = server.request("/")
        assert status == 302 and headers["Location"] == https + "/session/new"
        assert all("; secure" in line for _, line in cookies_of(headers).values())
        fields = {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test", "user[password]": "admin password"}
        assert server.request("/first_run", fields, headers={"Origin": f"http://127.0.0.1:{server.port}"})[0] == 422
        assert server.request("/first_run", fields, headers={"Sec-Fetch-Site": ""})[0] == 422
        status, headers, _ = server.request("/first_run", fields, headers=origin)
        assert status == 302 and headers["Location"] == https + "/"
        admin = session_cookie(headers)
        assert "; secure" in cookies_of(headers)["session_token"][1]
        status, _, page = server.request("/session/new")
        assert f'action="{https}/session"' in page
        page = server.request("/users/me/profile", cookie=admin)[2]
        assert f"http://127.0.0.1:{server.port}" not in page
        status, headers, _ = server.request("/session", {"_method": "delete"}, cookie=admin, headers=origin)
        assert status == 302 and headers["Location"] == https + "/"
        print("PASS: by default, as Rails' production: HTTPS URLs, HSTS, secure cookies and HTTPS origins")
    except BaseException:
        server.dump_log(); raise
    finally:
        server.close()


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="campfire-auth-") as directory:
        (Path(directory) / "plain").mkdir(); (Path(directory) / "https").mkdir()
        plain_http(binary, Path(directory) / "plain")
        default_https(binary, Path(directory) / "https")


if __name__ == "__main__":
    main()
