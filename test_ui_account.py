#!/usr/bin/env python3
"""Profile, account settings, custom styles, bots, transfer links and QR codes, as in Rails."""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import html
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urlencode

binary = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parent
SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
# RQRCode::QRCode.new(text).as_svg(viewbox: true, fill: :white, color: :black) in the Rails reference image
# (rqrcode 3.2.0, rqrcode_core 2.1.0): SHA-256 and length of the SVG.
QR_FIXTURES = {
    "http://127.0.0.1:3000/join/ABCD-EFGH-IJKL": ("5d9a0941c736a3c7d6b638f2a24099e4cc403ff1e1597af9dba799d959fd63d7", 39516),
    "HELLO 123": ("b7b5f7c389fdd4602c5d60efea3075410fdc14858e93e9f898dd053b7bcbea5b", 13611),
    "0123456789": ("5f16c593572fa0fae17c743b0224055d54d0187c1e165ce9544e9973038560e6", 13271),
    "a": ("94c7a7086d2f2384a47dbd8c9438fe5eb010337b3c20eb775864e9fe9f092598", 13377),
    "x" * 300: ("49fc4c2a7028f6dbedbdd08cc8c7649eedec851f07cb6c8ecc51c40ec4d39eaf", 238756),
}


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


def png():
    import zlib, struct
    raw = b"".join(b"\x00" + b"\xff\x00\x00" * 4 for _ in range(4))
    chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


with tempfile.TemporaryDirectory(prefix="campfire-account-") as directory:
    work = Path(directory)
    database = work / "production.sqlite3"
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0)); port = probe.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    env = dict(os.environ, DATABASE_PATH=str(database), STORAGE_PATH=str(work / "files"), SECRET_KEY_BASE=secrets.token_hex(64),
               HTTP_PORT=str(port), APP_VERSION="9.8.7", DISABLE_SSL="true")
    with (work / "server.log").open("w+") as log:
        server = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log, cwd=root)

        def request(path, data=None, cookie="", method=None, headers=None, kind="application/x-www-form-urlencoded"):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            fields = {"Sec-Fetch-Site": "same-origin", "Host": f"127.0.0.1:{port}", "User-Agent": SAFARI}
            if cookie: fields["Cookie"] = cookie
            body = None
            if data is not None:
                body = urlencode(data) if isinstance(data, (dict, list)) else data
                fields["Content-Type"] = kind
            fields.update(headers or {})
            connection.request(method or ("GET" if data is None else "POST"), path, body, fields)
            response = connection.getresponse()
            fields = {}
            for key, value in response.getheaders():
                key = key.lower()
                # Each Set-Cookie on a line of its own, in order.
                fields[key] = fields[key] + "\n" + value if key == "set-cookie" and key in fields else value
            result = response.status, fields, response.read()
            connection.close()
            return result

        def page(path, cookie):
            status, headers, body = request(path, cookie=cookie)
            assert status == 200, (path, status, body[:300])
            return body.decode()

        def sql(query, *args):
            with sqlite3.connect(database, timeout=10) as db:
                return db.execute(query, args).fetchall()

        def cookie_of(headers):
            return headers["set-cookie"].split(";", 1)[0]

        def flash_of(headers):
            # The notice a redirect leaves in the encrypted session cookie, as the next page shows it.
            match = re.search(r"_campfire_session=[^;]+", headers.get("set-cookie", ""))
            if not match: return None
            shown = re.search(r'role="alert" aria-atomic="true">([^<]*)</span>', request("/users/me/profile", cookie=f"{admin}; {match[0]}")[2].decode())
            return html.unescape(shown[1]) if shown else None

        try:
            for _ in range(200):
                if server.poll() is not None: raise AssertionError("server exited during startup")
                try:
                    if request("/up")[0] == 200: break
                except ConnectionRefusedError: time.sleep(.05)
            else: raise AssertionError("server did not start")

            # QrCodeController#show needs no session; the SVG is RQRCode's, module for module.
            for text, (digest, size) in QR_FIXTURES.items():
                status, headers, body = request("/qr_code/" + base64.urlsafe_b64encode(text.encode()).decode())
                assert status == 200 and headers["content-type"] == "image/svg+xml; charset=utf-8", (text, status, headers)
                assert headers["cache-control"] == "max-age=31556952, public", headers
                assert (hashlib.sha256(body).hexdigest(), len(body)) == (digest, size), (text, len(body), body[:200])
            assert request("/qr_code/" + base64.urlsafe_b64encode(b"HELLO 123").decode().rstrip("="))[0] == 200
            assert request("/qr_code/%21%21")[0] == 500
            assert request("/qr_code/" + base64.urlsafe_b64encode(b"x" * 3000).decode())[0] == 500
            assert request("/qr_code/YQ==", "x=1")[0] == 404
            print("PASS: QR codes without a session, matching RQRCode's SVG")

            status, headers, _ = request("/first_run", {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test", "user[password]": "admin password"})
            assert status == 302
            admin = cookie_of(headers)
            admin_id = sql("SELECT id FROM users WHERE role=1")[0][0]
            code = sql("SELECT join_code FROM accounts")[0][0]
            status, headers, _ = request(f"/join/{code}", {"user[name]": "Bob Member", "user[email_address]": "bob@example.test", "user[password]": "member password"})
            assert status == 302
            member = cookie_of(headers)
            member_id = sql("SELECT id FROM users WHERE email_address='bob@example.test'")[0][0]
            room = sql("SELECT id FROM rooms ORDER BY id LIMIT 1")[0][0]
            assert request("/rooms/directs", {"user_ids[]": member_id}, admin)[0] in (302, 303)
            direct = sql("SELECT id FROM rooms WHERE type='Rooms::Direct'")[0][0]

            # users/profiles/show: the log out button, every field, the room bells and the transfer link.
            profile = page("/users/me/profile", admin)
            assert '<form data-controller="sessions" action="/session" accept-charset="UTF-8" method="post"><input type="hidden" name="_method" value="delete" />' in profile
            assert 'data-sessions-target="pushSubscriptionEndpoint"' in profile and 'data-action="sessions#logout:prevent"' in profile and ">Log out<" in profile
            assert 'name="user[password]"' in profile and 'autocomplete="new-password"' in profile and 'value="ada@example.test"' in profile
            assert "Install Campfire as a web app." in profile and "Add to Dock" in profile
            assert '<input class="input txt-large" autocomplete="current-password" placeholder="Current password" maxlength="72" size="72" type="password" name="user[password_challenge]" id="user_password_challenge" />' in profile
            assert profile.index("Enter your current password") < profile.index('name="user[password_challenge]"') < profile.index('name="user[password]"')
            assert f'<turbo-frame id="involvement_rooms_open_{room}">' in profile and f'action="/rooms/{room}/involvement?involvement=everything"' in profile
            assert f'<turbo-frame id="involvement_rooms_direct_{direct}">' in profile and "<strong>Bob Member</strong>" in profile
            assert profile.index("<strong>All Talk</strong>") < profile.index('<hr class="separator full-width"') < profile.index("<strong>Bob Member</strong>")
            transfer = re.search(r'value="(http://[^"]+/session/transfers/([^"]+))" id="session_transfer_url"', profile)
            payload, _ = transfer[2].split("--")
            claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))["_rails"]
            expiry = datetime.strptime(claims["exp"], "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
            admin_digest = sql("SELECT password_digest FROM users WHERE id=?", admin_id)[0][0]
            assert claims["data"] == [admin_id, admin_digest[19:29]] and claims["pur"] == "User\ntransfer\n14400", claims
            assert re.fullmatch(r"[A-Za-z0-9_-]+--[0-9a-f]{40}", transfer[2]), transfer[2]
            assert abs(expiry - datetime.now(timezone.utc) - timedelta(hours=4)) < timedelta(minutes=1), expiry
            qr = "/qr_code/" + base64.urlsafe_b64encode(transfer[1].encode()).decode()
            assert f'data-lightbox-target="image" data-action="lightbox#open" data-lightbox-url-value="{qr}" href="{qr}"' in profile
            assert request(qr)[0] == 200
            # The link signs in, as Rails' transfer link does.
            assert "session_token=" in request(transfer[1].replace(base, ""), {"_method": "put"})[1].get("set-cookie", "")
            assert page(f"/users/{member_id}/profile", admin).count('value="ada@example.test"') == 1
            assert request("/users/me/profile", {"user[name]": "x"}, admin)[0] == 404
            assert request("/users/me/profile/edit", cookie=admin)[0] == 404
            # The user page's transfer QR opens in the lightbox too.
            user_page = page(f"/users/{member_id}", admin)
            assert 'data-action="lightbox#open"' in user_page and "/qr_code/" in user_page and "/qr\"" not in user_page
            print("PASS: profile page with log out, password, room bells, install help and a four-hour transfer link")

            # Users::ProfilesController#update: name, email, password and bio; the flash shows once.
            status, headers, _ = request("/users/me/profile", [("_method", "patch"), ("user[name]", "Ada Lovelace"), ("user[email_address]", "ada2@example.test"), ("user[bio]", "Counts")], admin)
            assert status == 302 and headers["location"] == f"{base}/users/me/profile" and flash_of(headers) == "✓", (status, headers)
            assert sql("SELECT name,email_address,bio FROM users WHERE id=?", admin_id) == [("Ada Lovelace", "ada2@example.test", "Counts")]
            flash = re.search(r"_campfire_session=[^;]+", headers["set-cookie"])[0]
            status, headers, body = request("/users/me/profile", cookie=f"{admin}; {flash}")
            assert 'role="alert" aria-atomic="true">✓</span>' in body.decode() and "_campfire_session=;" in headers["set-cookie"]
            assert 'class="flash"' not in page("/users/me/profile", admin)
            # No validations: an invalid address or an empty name is saved; a taken address fails the unique index.
            assert request("/users/me/profile", [("_method", "patch"), ("user[email_address]", "not an email")], admin)[0] == 302
            assert sql("SELECT email_address FROM users WHERE id=?", admin_id) == [("not an email",)]
            assert request("/users/me/profile", [("_method", "patch"), ("user[email_address]", "bob@example.test"), ("user[name]", "Taken")], admin)[0] == 500
            assert sql("SELECT email_address,name FROM users WHERE id=?", admin_id) == [("not an email", "Ada Lovelace")]
            assert request("/users/me/profile", [("_method", "patch"), ("user[name]", "")], admin)[0] == 302
            assert sql("SELECT name FROM users WHERE id=?", admin_id) == [("",)]
            digest = sql("SELECT password_digest FROM users WHERE id=?", admin_id)[0][0]
            assert request("/users/me/profile", [("_method", "patch"), ("user[password]", ""), ("user[name]", "Ada Admin"), ("user[email_address]", "ada@example.test")], admin)[0] == 302
            assert sql("SELECT password_digest FROM users WHERE id=?", admin_id)[0][0] == digest
            signed_in = lambda password: "session_token=" in request("/session", {"email_address": "ada@example.test", "password": password})[1].get("set-cookie", "")
            # A new password needs the current one; a refused change saves nothing, the name included.
            for challenge, alert in ((None, "Enter your current password to change it."), ("", "Enter your current password to change it."),
                                     ("not it", "That isn't your current password.")):
                fields = [("_method", "patch"), ("user[name]", "Nameless"), ("user[password]", "p" * 80)] + ([("user[password_challenge]", challenge)] if challenge is not None else [])
                status, headers, _ = request("/users/me/profile", fields, admin)
                assert status == 302 and headers["location"] == f"{base}/users/me/profile" and flash_of(headers) == alert, (challenge, status, headers)
                assert "session_token=" not in headers.get("set-cookie", "")
            assert sql("SELECT name,password_digest FROM users WHERE id=?", admin_id) == [("Ada Admin", digest)]
            # Only a password change asks for it.
            assert request("/users/me/profile", [("_method", "patch"), ("user[bio]", "Counts"), ("user[password_challenge]", "not it")], admin)[0] == 302
            assert sql("SELECT bio FROM users WHERE id=?", admin_id) == [("Counts",)]
            # The change ends every session and push subscription, and the transfer links made before.
            elsewhere = cookie_of(request("/session", {"email_address": "ada@example.test", "password": "admin password"})[1])
            assert request("/users/me/profile", cookie=elsewhere)[0] == 200
            with sqlite3.connect(database, timeout=10) as db:
                db.execute("INSERT INTO push_subscriptions(user_id,endpoint,p256dh_key,auth_key,created_at,updated_at) VALUES(?,'https://fcm.googleapis.com/x','k','a',datetime(),datetime())", (admin_id,))
            old_link = re.search(r'value="http://[^"]+(/session/transfers/[^"]+)" id="session_transfer_url"', page("/users/me/profile", admin))[1]
            status, headers, _ = request("/users/me/profile", [("_method", "put"), ("user[password]", "p" * 80), ("user[password_challenge]", "admin password")], admin)
            assert status == 302 and headers["location"] == f"{base}/users/me/profile", (status, headers)
            fresh = cookie_of(headers)
            assert fresh.startswith("session_token=") and fresh != admin
            assert request("/users/me/profile", cookie=admin)[0] == 302 and request("/users/me/profile", cookie=elsewhere)[0] == 302
            admin = fresh
            assert flash_of(headers) == "✓"
            assert sql("SELECT count(*) FROM sessions WHERE user_id=?", admin_id) == [(1,)]
            assert sql("SELECT count(*) FROM push_subscriptions WHERE user_id=?", admin_id) == [(0,)]
            assert request(old_link, {"_method": "put"})[0] == 400
            new_link = re.search(r'value="http://[^"]+(/session/transfers/[^"]+)" id="session_transfer_url"', page("/users/me/profile", admin))[1]
            assert "session_token=" in request(new_link, {"_method": "put"})[1].get("set-cookie", "")
            assert signed_in("p" * 80) and not signed_in("admin password")
            # rate_limit to: 10 per address, of updates that send a current password.
            limited = {"X-Forwarded-For": "203.0.113.60"}
            wrong = [("_method", "patch"), ("user[password]", "q"), ("user[password_challenge]", "wrong")]
            alerts = [flash_of(request("/users/me/profile", wrong, admin, headers=limited)[1]) for _ in range(11)]
            assert alerts == ["That isn't your current password."] * 10 + ["Too many attempts. Try again in a few minutes."], alerts
            assert flash_of(request("/users/me/profile", [("_method", "patch"), ("user[password]", "q")], admin, headers=limited)[1]) == "Enter your current password to change it."
            assert flash_of(request("/users/me/profile", wrong, admin, headers={"X-Forwarded-For": "203.0.113.61"})[1]) == "That isn't your current password."
            assert request("/users/me/profile", [("_method", "patch"), ("name", "x")], admin)[0] == 400
            assert request("/users/me/profile", [("_method", "patch"), ("user[name]", "x")], admin, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
            body, kind = multipart([("_method", "patch"), ("user[name]", "Ada Admin"), ("user[avatar]", ("me.png", "image/png", png()))])
            status, headers, _ = request("/users/me/profile", body, admin, kind=kind)
            assert status == 302 and flash_of(headers) == "It may take up to 30 minutes to change everywhere.", headers
            assert sql("SELECT count(*) FROM active_storage_attachments WHERE record_type='User' AND record_id=?", admin_id) == [(1,)]
            print("PASS: profile updates with Rails' parameters, notices and failures")

            # accounts/edit, for administrators and members.
            account = page("/account/edit", admin)
            for needle in ('href="/account/bots"', 'href="/account/custom_styles/edit"', 'name="account[settings][restrict_room_creation_to_administrators]"',
                           'value="true"', "Must be admin to create new rooms", 'action="/account.1"', "Show join link QR code", "Copy join link",
                           "Share join link", "Regenerate join link", '<span class="version-badge">9.8.7</span>', f'href="/rooms/{room}"'):
                assert needle in account, needle
            invite = re.search(r'id="invite_url" value="([^"]+)"', account)[1]
            assert invite == f"{base}/join/{code}" and "/qr_code/" + base64.urlsafe_b64encode(invite.encode()).decode() in account
            account = page("/account/edit", member)
            assert '<figure class="account-logo avatar txt-xx-large center">' in account and '<h1 class="flex-item-grow txt-x-large">Campfire</h1>' in account
            assert "Show join link QR code" in account and "Regenerate join link" not in account and "account[settings]" not in account and "/account/bots" not in account
            assert "version-badge" in account
            assert request("/account", cookie=admin)[0] == 404 and request("/account", {"account[name]": "x"}, admin)[0] == 404
            print("PASS: account settings page for administrators and members")

            # AccountsController#update: the name, the room creation setting and Rails' parameter failures.
            status, headers, _ = request("/account.1", [("_method", "patch"), ("account[name]", "Fire & <Ice>")], admin)
            assert status == 302 and headers["location"] == f"{base}/account/edit" and flash_of(headers) == "✓", headers
            assert sql("SELECT name,settings FROM accounts") == [("Fire & <Ice>", '{"restrict_room_creation_to_administrators":false}')]
            assert request("/account", [("_method", "put"), ("account[settings][restrict_room_creation_to_administrators]", "true")], admin)[0] == 302
            assert sql("SELECT settings FROM accounts") == [('{"restrict_room_creation_to_administrators":true}',)]
            assert request("/rooms/closeds/new", cookie=member)[0] == 403
            account = page("/account/edit", admin)
            assert 'value="false" type="hidden" name="account[settings][restrict_room_creation_to_administrators]"' in account and '<input type="checkbox" class="switch__input" checked="checked" data-action="change-&gt;form#submit">' in account
            assert request("/account", [("_method", "put"), ("account[settings][colour]", "red")], admin)[0] == 500
            assert request("/account", [("_method", "patch"), ("name", "x")], admin)[0] == 400
            assert request("/account", [("_method", "patch"), ("account[name]", "Bob's")], member)[0] == 403
            assert request("/account", [("_method", "put"), ("account[settings][restrict_room_creation_to_administrators]", "false")], admin)[0] == 302
            assert sql("SELECT settings,name FROM accounts") == [('{"restrict_room_creation_to_administrators":false}', "Fire & <Ice>")]
            assert request("/rooms/closeds/new", cookie=member)[0] == 200
            body, kind = multipart([("_method", "patch"), ("account[logo]", ("logo.png", "image/png", png()))])
            status, headers, _ = request("/account", body, admin, kind=kind)
            assert status == 302 and flash_of(headers) == "✓"
            assert sql("SELECT count(*) FROM active_storage_attachments WHERE record_type='Account'") == [(1,)]
            assert "Delete logo" in page("/account/edit", admin)
            print("PASS: account updates with the name, settings and logo")

            # Accounts::CustomStylesController: the CSS reaches every page unescaped, as custom_styles_tag emits it.
            assert request("/account/custom_styles/edit", cookie=member)[0] == 403
            styles = page("/account/custom_styles/edit", admin)
            assert f'action="{base}/account/custom_styles"' in styles and "Custom CSS" in styles and 'name="account[custom_styles]"' in styles
            css = "body > main { color: \"red\"; } a[href^='x'] { }"
            status, headers, _ = request("/account/custom_styles", [("_method", "patch"), ("account[custom_styles]", css)], admin)
            assert status == 302 and headers["location"] == f"{base}/account/custom_styles/edit" and flash_of(headers) == "✓"
            assert f'<style data-turbo-track="reload">{css}</style>' in page("/users/me/profile", member)
            assert "body &gt; main { color: &quot;red&quot;; }" in page("/account/custom_styles/edit", admin)
            assert f'<style data-turbo-track="reload">{css}</style>' in page("/users/me/push_subscriptions", member)
            assert request("/account/custom_styles", [("_method", "patch"), ("x", "y")], admin)[0] == 400
            assert request("/account/custom_styles", [("_method", "patch"), ("account[custom_styles]", "x")], member)[0] == 403
            print("PASS: custom styles page and update")

            # Accounts::BotsController and Accounts::Bots::KeysController.
            assert request("/account/bots", cookie=member)[0] == 403 and request("/account/bots/new", cookie=member)[0] == 403
            new = page("/account/bots/new", admin)
            assert 'enctype="multipart/form-data" action="/account/bots"' in new and 'name="user[avatar]"' in new and "default-bot-avatar" in new
            status, headers, _ = request("/account/bots", [("user[name]", "Hooky"), ("user[webhook_url]", "https://example.test/hook")], admin)
            assert status == 302 and headers["location"] == f"{base}/account/bots" and flash_of(headers) is None
            bot, token = sql("SELECT id,bot_token FROM users WHERE name='Hooky'")[0]
            assert re.fullmatch(r"[A-Za-z0-9]{12}", token), token
            assert sql("SELECT room_id,involvement FROM memberships WHERE user_id=?", bot) == [(room, "mentions")]
            body, kind = multipart([("user[name]", "Pic"), ("user[webhook_url]", ""), ("user[avatar]", ("bot.png", "image/png", png()))])
            assert request("/account/bots", body, admin, kind=kind)[0] == 302
            pic = sql("SELECT id FROM users WHERE name='Pic'")[0][0]
            assert sql("SELECT url FROM webhooks WHERE user_id=?", pic) == [("",)]
            assert sql("SELECT count(*) FROM active_storage_attachments WHERE record_type='User' AND record_id=?", pic) == [(1,)]
            assert "/rails/active_storage/blobs/redirect/" in page(f"/account/bots/{pic}/edit", admin)
            # A bot in a direct room and one in no room at all.
            with sqlite3.connect(database, timeout=10) as db:
                db.execute("INSERT INTO memberships(room_id,user_id,created_at,updated_at) VALUES(?,?,datetime(),datetime())", (direct, bot))
                db.execute("DELETE FROM memberships WHERE user_id=?", (pic,)); db.commit()
            bots = page("/account/bots", admin)
            assert bots.count("<fieldset") == 1 and "Edit Pic" in bots and "Edit Hooky" in bots
            url = f"{base}/rooms/{room}/{bot}-{token}/messages"
            assert f"curl -d &#39;Hello!&#39; {url}" in bots or f"curl -d &#x27;Hello!&#x27; {url}" in bots or f"curl -d 'Hello!' {url}" in bots
            assert f"curl -F &quot;attachment=@/path/to/file&quot; {url}" in bots and "curl command for posting attachments" in bots
            edit = page(f"/account/bots/{bot}/edit", admin)
            assert f'action="/account/bots/{bot}"' in edit and 'aria-label="Delete this chat bot"' in edit and f'action="/account/bots/{bot}/key"' in edit
            assert 'value="https://example.test/hook"' in edit
            assert request(f"/account/bots/{bot}", cookie=admin)[0] == 404
            status, headers, _ = request(f"/account/bots/{bot}", [("_method", "patch"), ("user[name]", "Hooky 2"), ("user[webhook_url]", "")], admin)
            assert status == 302 and headers["location"] == f"{base}/account/bots"
            assert sql("SELECT name FROM users WHERE id=?", bot) == [("Hooky 2",)] and sql("SELECT count(*) FROM webhooks WHERE user_id=?", bot) == [(0,)]
            assert request(f"/account/bots/{bot}/key", [("_method", "put")], member)[0] == 403
            status, headers, _ = request(f"/account/bots/{bot}/key", [("_method", "patch")], admin)
            assert status == 302 and headers["location"] == f"{base}/account/bots"
            fresh = sql("SELECT bot_token FROM users WHERE id=?", bot)[0][0]
            assert fresh != token and re.fullmatch(r"[A-Za-z0-9]{12}", fresh)
            assert request(f"/account/bots/{bot}", [("_method", "delete")], member)[0] == 403
            status, headers, _ = request(f"/account/bots/{bot}", [("_method", "delete")], admin)
            assert status == 302 and headers["location"] == f"{base}/account/bots"
            assert sql("SELECT status FROM users WHERE id=?", bot) == [(1,)]
            assert sql("SELECT r.type FROM memberships m JOIN rooms r ON r.id=m.room_id WHERE m.user_id=?", bot) == [("Rooms::Direct",)]
            assert "Hooky" not in page("/account/bots", admin) and request(f"/account/bots/{bot}/edit", cookie=admin)[0] == 404
            assert request(f"/account/bots/{bot}/key", [("_method", "patch")], admin)[0] == 404
            assert request("/account/bots", [("x", "y")], admin)[0] == 400
            print("PASS: bots created, listed, edited, re-keyed and deleted as Rails does")

            # Users::PushSubscriptionsController#index in the application layout.
            push = page("/users/me/push_subscriptions", admin)
            assert "Push Notification Subscriptions" in push and '<nav id="nav">' in push and "<title>Push notification subscriptions</title>" in push
            print("PASS: push subscriptions page in the layout")
        finally:
            server.terminate()
            try: server.wait(timeout=5)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
            if sys.exc_info()[0]:
                log.seek(0); sys.stderr.write(log.read()[-4000:])
