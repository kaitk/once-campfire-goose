#!/usr/bin/env python3
"""Differential checks of what Rails' middleware stack puts on responses, against the Rails reference
image: Rack::ETag's ETag and Cache-Control, Rack::ConditionalGet's 304s, Rack::Head, the
default_headers of a controller's response, and no Server field. The same requests, with the same
secret, go to Rails (behind Thruster) and to this server, and each response is compared by its status,
the form of its ETag (W/ and 32 hex digits) and, where the two bodies are byte for byte the same, its
value, its Cache-Control, whether it has a Last-Modified, the default headers, Server, and for a 304
or a HEAD its Content-Type and Content-Length. Needs Docker and the reference image:

    python3 compare_ui_etag.py once-campfire-goose:etag-app [--reference once-campfire-verification:reference-90b3300]

Where a page's body differs (Rails masks a new CSRF token into every page, so its page ETags differ
from one request to the next and its If-None-Match never matches them), only the form is compared.
"""
import argparse
import gzip
import hashlib
from pathlib import Path
import re
import secrets
import tempfile
from urllib.parse import urlencode

from compare_uploads import App
from test_uploads import multipart, png

DEFAULT_HEADERS = ("x-frame-options", "x-xss-protection", "x-content-type-options", "x-permitted-cross-domain-policies", "referrer-policy")
TURBO = {"Accept": "text/vnd.turbo-stream.html, text/html"}


def observe(app, path, data=None, kind="application/x-www-form-urlencoded", method=None, headers=None):
    status, fields, body = app.request(path, data, kind, method=method, headers=headers)
    plain = gzip.decompress(body) if fields.get("content-encoding") == "gzip" and body else body
    etag = fields.get("etag")
    seen = {"status": status,
            "etag": None if etag is None else ("W/<32 hex>" if re.fullmatch(r'W/"[0-9a-f]{32}"', etag) else etag),
            "cache-control": fields.get("cache-control"),
            "last-modified": "last-modified" in fields,
            "default headers": {k: fields[k] for k in DEFAULT_HEADERS if k in fields},
            "server": fields.get("server")}
    if status == 304 or method == "HEAD":
        seen["content-type"] = fields.get("content-type")
        seen["content-length"] = fields.get("content-length")
        seen["body"] = len(body)
    return seen, etag, hashlib.sha256(plain).hexdigest(), fields


def scenario(app):
    out = []

    def add(label, path, data=None, kind="application/x-www-form-urlencoded", method=None, headers=None):
        seen, etag, digest, fields = observe(app, path, data, kind, method, headers)
        out.append((label, seen, etag, digest))
        return etag, fields

    add("/up", "/up")
    etag, _ = add("/up gzip", "/up", headers={"Accept-Encoding": "gzip"})
    add("/up If-None-Match", "/up", headers={"If-None-Match": etag})
    add("/up HEAD", "/up", method="HEAD")
    add("/up HEAD If-None-Match", "/up", method="HEAD", headers={"If-None-Match": etag})
    add("root before the first run", "/")
    add("first run page", "/first_run")
    status, _, _ = app.request("/first_run", urlencode({"user[name]": "Ada Admin", "user[email_address]": "ada@example.test",
                                                        "user[password]": "admin password 123"}))
    assert status == 302, status
    add("root", "/")
    for n in range(3):
        add(f"post {n}", "/rooms/1/messages", urlencode({"message[body]": f"etag {n}", "message[client_message_id]": f"etag-{n}"}), headers=TURBO)
    add("room", "/rooms/1")
    etag, _ = add("room gzip", "/rooms/1", headers={"Accept-Encoding": "gzip"})
    add("room HEAD", "/rooms/1", method="HEAD")
    add("room If-None-Match list", "/rooms/1", headers={"If-None-Match": f'"other", {etag}'})
    add("room If-None-Match *", "/rooms/1", headers={"If-None-Match": "*"})
    add("room If-Modified-Since (no Last-Modified)", "/rooms/1", headers={"If-Modified-Since": "Wed, 01 Jan 2031 00:00:00 GMT"})
    etag, _ = add("refresh", "/rooms/1/refresh?since=1", headers={"Accept": "text/vnd.turbo-stream.html"})
    add("refresh If-None-Match", "/rooms/1/refresh?since=1", headers={"Accept": "text/vnd.turbo-stream.html", "If-None-Match": etag})
    add("refresh If-None-Match gzip", "/rooms/1/refresh?since=1", headers={"Accept": "text/vnd.turbo-stream.html", "If-None-Match": etag, "Accept-Encoding": "gzip"})
    add("refresh HEAD If-None-Match", "/rooms/1/refresh?since=1", method="HEAD", headers={"Accept": "text/vnd.turbo-stream.html", "If-None-Match": etag})
    add("refresh If-None-Match weak-stripped", "/rooms/1/refresh?since=1", headers={"Accept": "text/vnd.turbo-stream.html", "If-None-Match": etag[2:]})
    add("refresh If-None-Match list", "/rooms/1/refresh?since=1", headers={"Accept": "text/vnd.turbo-stream.html", "If-None-Match": f'"a", {etag}'})
    add("empty refresh", "/rooms/1/refresh?since=99999999999999", headers={"Accept": "text/vnd.turbo-stream.html"})
    _, fields = add("messages page", "/rooms/1/messages?before=3")
    add("messages page If-None-Match", "/rooms/1/messages?before=3", headers={"If-None-Match": fields["etag"]})
    add("messages page If-Modified-Since", "/rooms/1/messages?before=3", headers={"If-Modified-Since": fields["last-modified"]})
    add("messages page If-None-Match, stale If-Modified-Since", "/rooms/1/messages?before=3",
        headers={"If-None-Match": fields["etag"], "If-Modified-Since": "Mon, 01 Jan 2001 00:00:00 GMT"})
    add("messages page 204", "/rooms/1/messages?after=3")
    add("sidebar", "/users/me/sidebar")
    add("involvement", "/rooms/1/involvement")
    add("involvement update", "/rooms/1/involvement", urlencode({"involvement": "everything", "_method": "put"}))
    add("new room", "/rooms/opens/new")
    add("profile", "/users/me/profile")
    add("account edit", "/account/edit")
    add("bots", "/account/bots")
    add("searches", "/searches")
    add("search posted", "/searches", urlencode({"q": "etag"}))
    add("message edit", "/rooms/1/messages/1/edit")
    add("message delete", "/rooms/1/messages/2", urlencode({"_method": "delete"}), headers=TURBO)
    add("boosts", "/messages/1/boosts")
    etag, _ = add("service worker", "/service-worker.js")
    add("service worker If-None-Match", "/service-worker.js", headers={"If-None-Match": etag})
    add("service worker If-Modified-Since", "/service-worker.js", headers={"If-Modified-Since": "Wed, 01 Jan 2031 00:00:00 GMT"})
    etag, _ = add("webmanifest", "/webmanifest.json")
    add("webmanifest If-None-Match", "/webmanifest.json", headers={"If-None-Match": etag})
    etag, _ = add("qr code", "/qr_code/etag")
    add("qr code If-None-Match", "/qr_code/etag", headers={"If-None-Match": etag})
    add("qr code HEAD", "/qr_code/etag", method="HEAD")
    etag, _ = add("autocomplete JSON", "/autocompletable/users.json?query=a")
    add("autocomplete JSON If-None-Match", "/autocompletable/users.json?query=a", headers={"If-None-Match": etag})
    etag, _ = add("logo", "/account/logo")
    add("logo If-None-Match", "/account/logo", headers={"If-None-Match": etag})
    _, _, room = app.request("/rooms/1")
    avatar = re.search(rb'src="(/users/[^"/]+/avatar\?v=\d+)"', room)[1].decode()
    etag, _ = add("avatar", avatar)
    add("avatar If-None-Match", avatar, headers={"If-None-Match": etag})
    add("avatar of a bad token", "/users/nobody/avatar")
    add("unfurl, nothing to unfurl", "/unfurl_link", urlencode({"url": "http://127.0.0.1:1/"}))
    add("cable without an upgrade", "/cable")
    add("routing 404", "/nope")
    add("record 404", "/rooms/1/messages/999/edit")
    add("unknown format 406", "/account/users")
    add("asset", re.search(rb'href="(/assets/[^"]+\.css)"', room)[1].decode())
    body, content_type = multipart([("message[client_message_id]", "etag-image"), ("message[attachment]", ("wide.png", "image/png", png(2400, 1000)))])
    add("post an image", "/rooms/1/messages", body, content_type, headers=TURBO)
    _, _, room = app.request("/rooms/1")
    blob = re.search(rb'href="(/rails/active_storage/blobs/redirect/[^"]+)"', room)[1].decode().replace("&amp;", "&")
    _, fields = add("blob redirect", blob)
    add("blob on disk", re.sub(r"^https?://[^/]+", "", fields["location"]))
    add("blob proxy", blob.replace("/blobs/redirect/", "/blobs/proxy/"))
    thumb = re.search(rb'class="message__attachment" loading="lazy" src="([^"]+)"', room)[1].decode().replace("&amp;", "&")
    _, fields = add("variant redirect", thumb)
    add("variant on disk", re.sub(r"^https?://[^/]+", "", fields["location"]))
    add("session delete", "/session", urlencode({"_method": "delete"}))
    add("sign-in page", "/session/new")
    add("sign-in refused", "/session", urlencode({"email_address": "ada@example.test", "password": "wrong"}))
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--reference", default="once-campfire-verification:reference-90b3300")
    args = parser.parse_args()
    secret = secrets.token_hex(64)
    results = {}
    with tempfile.TemporaryDirectory(prefix="campfire-compare-etag-") as directory:
        for label, image in (("rails", args.reference), ("goose", args.image)):
            app = App(image, secret, Path(directory) / label)
            try:
                results[label] = scenario(app)
            finally:
                app.close()
    failures, same_bodies = 0, []
    for (name, rails, rails_etag, rails_digest), (_, goose, goose_etag, goose_digest) in zip(results["rails"], results["goose"]):
        # Rack::ETag's own digest (not a controller's validator) of the same non-empty body.
        digested = rails_etag == f'W/"{rails_digest[:32]}"' and rails_digest != hashlib.sha256(b"").hexdigest()
        if digested and rails_digest == goose_digest and rails["status"] == goose["status"] == 200:
            same_bodies.append(name)
            rails, goose = dict(rails, etag=rails_etag), dict(goose, etag=goose_etag)
        if rails == goose:
            print(f"PASS: {name}: {rails['status']} {rails['etag'] or ''} {rails['cache-control'] or ''}")
            continue
        failures += 1
        print(f"FAIL: {name}")
        for key in sorted(set(rails) | set(goose)):
            if rails.get(key) != goose.get(key):
                print(f"  {key}\n    rails: {rails.get(key)}\n    goose: {goose.get(key)}")
    print(f"Byte-identical bodies, ETags compared by value: {', '.join(same_bodies)}")
    print(f"{len(results['rails']) - failures} of {len(results['rails'])} match")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
