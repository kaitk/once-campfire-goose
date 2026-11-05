#!/usr/bin/env python3
"""Differential checks of sign-in, first run, joining, session transfers, sign-out, the unsupported-browser
page, version headers and HTTPS handling against the Rails reference image: the same requests to Rails and
to this server, compared by status, redirect, headers and parsed HTML. Needs Docker and the reference image:

    python3 compare_ui_auth.py once-campfire-goose:auth-app [--reference once-campfire-verification:reference-a05ee90]
"""
import argparse
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
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import urlencode

import compare_db
from compare_rendering import CanonicalHTML

ENV = {"RAILS_ENV": "production", "SKIP_TELEMETRY": "true", "APP_VERSION": "parity", "GIT_REVISION": "parity",
       "WEB_CONCURRENCY": "1", "RAILS_MAX_THREADS": "5", "JOB_CONCURRENCY": "1", "RAILS_LOG_LEVEL": "warn",
       "VAPID_PUBLIC_KEY": "BMDitqKbDeHt7gjBIOc_2l6bwZ4Y5UZi6SU_7ORnq2MIEbivQZ1IEXQjHmZVHcCdG9aOdmReHSvze3U9acZOU64=",
       "VAPID_PRIVATE_KEY": "-I8znb1TdZ4jD6gknSl2RgygFR54o62UiQkwoh3WzXI="}
MODERN = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
OLD = "Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:115.0) Gecko/20100101 Firefox/115.0"
APPLE_MESSAGES = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 facebookexternalhit/1.1 Twitterbot/1.0"


class App:
    def __init__(self, image, secret, work, ssl):
        self.image, self.work, self.secret = image, work, secret
        self.name = "campfire-auth-" + uuid.uuid4().hex[:10]
        for folder in ("db", "files", "logs"):
            (work / folder).mkdir(parents=True); os.chmod(work / folder, 0o777)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0)); self.port = probe.getsockname()[1]
        env = dict(ENV, SECRET_KEY_BASE=secret, HTTP_PORT="3000", TARGET_PORT="3001")
        if not ssl: env["DISABLE_SSL"] = "true"
        (work / "env").write_text("".join(f"{k}={v}\n" for k, v in env.items()))
        command = ["docker", "run", "-d", "--name", self.name, "-p", f"127.0.0.1:{self.port}:3000", "--env-file", str(work / "env")]
        for folder in ("db", "files", "logs"): command += ["-v", f"{work / folder}:/rails/storage/{folder}"]
        subprocess.run(command + [image], check=True, stdout=subprocess.DEVNULL)
        for _ in range(900):
            try:
                if Client(self).request("/up")[0] == 200: break
            except (OSError, http.client.HTTPException): pass
            time.sleep(.1)
        else: raise RuntimeError(f"{image} did not start")

    def sql(self, query, *args):
        return compare_db.query(self.work, self.name, query, *args)

    def close(self):
        subprocess.run(["docker", "rm", "-f", self.name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Client:
    """A browser: its cookies."""
    def __init__(self, app, agent=MODERN):
        self.app, self.agent, self.cookies = app, agent, {}

    def request(self, path, data=None, headers=None, agent=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.app.port, timeout=60)
        fields = {"Sec-Fetch-Site": "same-origin", "Host": f"127.0.0.1:{self.app.port}", "User-Agent": agent or self.agent}
        if self.cookies: fields["Cookie"] = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
        if data is not None:
            fields["Content-Type"] = "application/x-www-form-urlencoded"
            data = urlencode(data)
        fields.update(headers or {})
        connection.request("GET" if data is None else "POST", path, data, fields)
        response = connection.getresponse()
        for cookie in response.msg.get_all("Set-Cookie") or []:
            name, _, value = cookie.split(";", 1)[0].partition("=")
            if value: self.cookies[name] = value
            else: self.cookies.pop(name, None)
        result = response.status, response.msg, response.read().decode("utf8", "replace")
        connection.close()
        return result


def transfer_id(app, user):
    """User#transfer_id: generates_token_for :transfer, expiring in 4 hours, bound to the last 10 characters of
    the bcrypt salt. app.message_verifier("active_record/token_for"): a PBKDF2-SHA256 key (1000 rounds, 64
    bytes) for that salt, an HMAC-SHA1 signature, URL-safe Base64."""
    digest = app.sql("SELECT password_digest FROM users WHERE id=?", user)[0][0]
    salt = digest[7:29]  # $2a$12$ then the 22-character salt
    expiry = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + 4 * 3600))
    serialized = json.dumps({"_rails": {"data": [user, salt[-10:]], "exp": expiry, "pur": "User\ntransfer\n14400"}}, separators=(",", ":")).encode()
    payload = base64.urlsafe_b64encode(serialized).rstrip(b"=")
    key = hashlib.pbkdf2_hmac("sha256", app.secret.encode(), b"active_record/token_for", 1000, 64)
    return payload.decode() + "--" + hmac.new(key, payload, hashlib.sha1).hexdigest()


def canonical(page, app, replacements):
    """Parsed HTML with this app's URL and per-run values neutral."""
    for old, new in replacements: page = page.replace(old, new)
    page = re.sub(r"/account/logo\?v=\d+", "/account/logo?v=VERSION", page)
    events = CanonicalHTML(page, f"http://127.0.0.1:{app.port}").events
    return [repr(e).replace(f"https://127.0.0.1:{app.port}", "https://SERVER") for e in events]


def response_facts(app, result, signed_in):
    status, headers, page = result
    location = (headers.get("Location") or "").replace(f"127.0.0.1:{app.port}", "SERVER")
    # Rails writes its session cookie on nearly every response, this server only when it holds something:
    # compare the session_token cookie, and whether every cookie is secure.
    lines = headers.get_all("Set-Cookie") or []
    token = [("set" if line.split(";", 1)[0] != "session_token=" else "deleted") + ("; secure" if "; secure" in line.lower() else "")
             for line in lines if line.startswith("session_token=")]
    # Rails signs the session cookie again on every request; this server, as Rust's, only when it changes.
    if signed_in: token = [t for t in token if not t.startswith("set")]
    return {"status": status, "location": location, "x-version": headers.get("X-Version"), "x-rev": headers.get("X-Rev"),
            "hsts": headers.get("Strict-Transport-Security"), "session_token": token}


def scenario(app, ssl):
    """The same visits on either app: {name: (facts, canonical page or None)}."""
    results = {}
    def keep(name, result, page=False, replacements=(), signed_in=False):
        results[name] = (response_facts(app, result, signed_in), canonical(result[2], app, replacements) if page else None)
        return result

    visitor = Client(app)
    keep("root, no users", visitor.request("/"))
    keep("sign in, no users", visitor.request("/session/new"))
    keep("first run", visitor.request("/first_run"), page=True)
    origin = {"Origin": f"{'https' if ssl else 'http'}://127.0.0.1:{app.port}"}
    admin = Client(app); admin.request("/first_run")
    keep("first run create", admin.request("/first_run", {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test", "user[password]": "admin password"}, headers=origin))
    if ssl:
        reader = Client(app)
        keep("sign in page", reader.request("/session/new"), page=True)
        keep("unauthenticated room", reader.request("/rooms/1"))
        keep("sign in, returning", reader.request("/session", {"email_address": "ada@example.test", "password": "admin password"}, headers=origin))
        keep("sign out", reader.request("/session", {"_method": "delete"}, headers=origin), signed_in=True)
        keep("cross-origin sign in", Client(app).request("/session", {"email_address": "ada@example.test", "password": "admin password"},
                                                         headers={"Origin": f"http://127.0.0.1:{app.port}"}))
        return results
    keep("first run again", admin.request("/first_run"))
    keep("root, signed in", admin.request("/"), signed_in=True)
    acct = admin.request("/account/edit")[2]
    code = re.search(r"/join/([A-Za-z0-9-]+)", acct)[1]
    keep("join, signed in", admin.request(f"/join/{code}"), signed_in=True)
    guest = Client(app)
    keep("join page", guest.request(f"/join/{code}"), page=True, replacements=[(code, "CODE")])
    keep("join, wrong code", guest.request("/join/nope"))
    keep("join create", guest.request(f"/join/{code}", {"user[name]": "Bob", "user[email_address]": "bob@example.test", "user[password]": "bob password"}))
    again = Client(app); again.request(f"/join/{code}")
    keep("join, taken address", again.request(f"/join/{code}", {"user[name]": "Bob 2", "user[email_address]": "bob@example.test", "user[password]": "x"}))
    reader = Client(app)
    keep("sign in page", reader.request("/session/new"), page=True)
    keep("sign in page, address", reader.request("/session/new?email_address=bob%40example.test"), page=True)
    keep("unauthenticated room", reader.request("/rooms/1?x=1"))
    keep("sign in rejected", reader.request("/session", {"email_address": "bob@example.test", "password": "wrong"}), page=True)
    keep("sign in, returning", reader.request("/session", {"email_address": "bob@example.test", "password": "bob password"}))
    keep("sign out", reader.request("/session", {"_method": "delete"}), signed_in=True)
    keep("sign out, signed out", reader.request("/session", {"_method": "delete"}))
    traveller = Client(app)
    link = transfer_id(app, 2)
    keep("transfer page", traveller.request(f"/session/transfers/{link}"), page=True, replacements=[(link, "LINK")])
    keep("transfer", traveller.request(f"/session/transfers/{link}", {"_method": "put"}))
    stranger = Client(app); stranger.request("/session/transfers/nope")
    keep("transfer refused", stranger.request("/session/transfers/nope", {"_method": "put"}))
    old = Client(app, OLD)
    keep("unsupported browser", old.request("/session/new"), page=True)
    keep("unsupported browser, unauthenticated room", old.request("/rooms/1"))
    keep("apple messages", Client(app, APPLE_MESSAGES).request("/session/new"), page=True)
    keep("unsupported browser, signed in", admin.request("/rooms/1", agent=OLD), page=True, signed_in=True)
    flood = Client(app)
    flood.request("/session/new")
    for _ in range(12): last = flood.request("/session", {"email_address": "bob@example.test", "password": "wrong"}, headers={"X-Forwarded-For": "203.0.113.9"})
    keep("rate limited", last, page=True)
    proxy = Client(app)
    keep("behind a TLS proxy", proxy.request("/rooms/1", headers={"X-Forwarded-Proto": "https", "X-Forwarded-Host": "chat.example.test"}))
    keep("health check", proxy.request("/up"))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--reference", default="once-campfire-verification:reference-a05ee90")
    args = parser.parse_args()
    secret = secrets.token_hex(64)
    failures = 0
    with tempfile.TemporaryDirectory(prefix="campfire-compare-auth-") as directory:
        for ssl in (False, True):
            runs = {}
            for label, image in (("rails", args.reference), ("goose", args.image)):
                app = App(image, secret, Path(directory) / f"{label}-{ssl}", ssl)
                try: runs[label] = scenario(app, ssl)
                finally: app.close()
            for name, (facts, page) in runs["rails"].items():
                other, other_page = runs["goose"][name]
                same_facts, same_page = facts == other, page == other_page
                mode = "HTTPS" if ssl else "HTTP"
                if same_facts and same_page:
                    print(f"{mode} {name}: same" + (f" ({len(page)} HTML events)" if page else ""))
                    continue
                failures += 1
                print(f"{mode} {name}: DIFFERENT")
                if not same_facts: print("  rails", facts, "\n  goose", other)
                if not same_page:
                    from difflib import unified_diff
                    for line in list(unified_diff(page, other_page, "rails", "goose", lineterm="", n=1))[:30]: print("  ", line[:300])
    print("PASS" if failures == 0 else f"{failures} differences")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
