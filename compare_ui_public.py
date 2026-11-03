#!/usr/bin/env python3
"""Differential checks of what Rails answers above and beside its controllers, against the Rails
reference image: ShowExceptions' and PublicExceptions' error pages (by status, type, body and
format: html, JSON, XML, YAML, HEAD), ActionDispatch::Static's public/ files and assets (types,
Cache-Control, Last-Modified, If-Modified-Since, byte ranges), the avatar and logo controllers'
headers and bodies (ActionController::Live: no default headers, their Cache-Control, a weak ETag,
send_file's disposition), and Active Storage's proxy routes (streamed blobs and representations with
http_cache_forever's validators, ranges, 304s). The same requests, with the same secret, go to Rails
(behind Thruster) and to this server. Needs Docker and the reference image:

    python3 compare_ui_public.py once-campfire-goose:public-app [--reference once-campfire-verification:reference-90b3300]

Thruster's response cache answers a warm URL itself (x-cache: hit): a Range or If-Modified-Since
gets the whole stored response, and an If-None-Match a 304 with the stored 200's fields. This
server answers as the application does, but for those 304s, which carry the 200's fields as a hit
does; so the Range and If-Modified-Since requests here go to cold URLs (a query no route reads).

Bodies are compared by their SHA-256, but for what can't be the same: a multipart range's random
boundary (its length is compared), and an ETag that digests a record's timestamps (its form is).
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
FIELDS = ("content-type", "cache-control", "content-disposition", "content-transfer-encoding", "accept-ranges", "content-range", "x-cascade", "x-version")
TURBO = {"Accept": "text/vnd.turbo-stream.html, text/html"}


def observe(app, path, data=None, kind="application/x-www-form-urlencoded", method=None, headers=None, body="sha", etag="form", mask=None):
    status, fields, raw = app.request(path, data, kind, method=method, headers=headers)
    plain = gzip.decompress(raw) if fields.get("content-encoding") == "gzip" and raw else raw
    seen = {"status": status}
    for name in FIELDS:
        value = fields.get(name)
        if value is not None and mask: value = mask(value)
        seen[name] = value
    tag = fields.get("etag")
    seen["etag"] = tag if etag == "value" or tag is None else ("W/<32 hex>" if re.fullmatch(r'W/"[0-9a-f]{32}"', tag) else tag)
    seen["last-modified"] = "last-modified" in fields
    seen["default headers"] = {k: fields[k] for k in DEFAULT_HEADERS if k in fields}
    if "content-encoding" not in fields: seen["content-length"] = fields.get("content-length")
    seen["body"] = hashlib.sha256(plain).hexdigest()[:16] if body == "sha" else len(plain)
    return seen, fields, plain


def scenario(app, secret):
    out = []

    def add(label, path, data=None, **options):
        seen, fields, plain = observe(app, path, data, **options)
        out.append((label, seen))
        return fields, plain

    app.request("/first_run")
    status, _, _ = app.request("/first_run", urlencode({"user[name]": "Ada Admin", "user[email_address]": "ada@example.test",
                                                        "user[password]": "admin password 123"}))
    assert status == 302, status
    room = re.search(r"/rooms/(\d+)", app.request("/")[1]["location"])[1]
    status, _, stream = app.request(f"/rooms/{room}/messages", urlencode({"message[body]": "public", "message[client_message_id]": "public-1"}), headers=TURBO)
    assert status == 200, status
    message = re.search(rb'data-message-id="(\d+)"', stream)[1].decode()

    # ShowExceptions and PublicExceptions.
    add("routing 404", "/nope")
    add("routing 404 .json", "/nope.json")
    add("routing 404, Accept JSON", "/nope", headers={"Accept": "application/json"})
    add("routing 404, Accept XML", "/nope", headers={"Accept": "application/xml"})
    add("routing 404, Accept YAML", "/nope", headers={"Accept": "application/x-yaml"})
    add("routing 404, Accept text/plain", "/nope", headers={"Accept": "text/plain"})
    add("routing 404, a browser's Accept", "/nope.json", headers={"Accept": "text/html,application/xhtml+xml,*/*;q=0.8"})
    add("routing 404, Accept json;q=0.5, xml", "/nope", headers={"Accept": "application/json;q=0.5, application/xml"})
    add("routing 404 HEAD", "/nope", method="HEAD")
    add("routing 404 HEAD, Accept */*", "/nope", method="HEAD", headers={"Accept": "*/*"})
    add("routing 404 HEAD, Accept JSON", "/nope", method="HEAD", headers={"Accept": "application/json"})
    add("routing 404, gzip", "/nope", headers={"Accept-Encoding": "gzip"})
    add("an unknown asset", "/assets/nope-0123abcd.css")
    add("favicon", "/favicon.ico")
    add("POST to no route", "/up", "")
    add("record 404", f"/rooms/{room}/messages/999999/edit")
    add("record 404 .json", f"/rooms/{room}/messages/999999.json")
    add("forged request 422", "/searches", urlencode({"q": "x"}), headers={"Sec-Fetch-Site": "cross-site", "X-CSRF-Token": "forged"})
    add("forged request 422, Accept JSON", "/searches", urlencode({"q": "x"}),
        headers={"Sec-Fetch-Site": "cross-site", "X-CSRF-Token": "forged", "Accept": "application/json"})
    add("500", f"/rooms/{room}/settings")
    add("500, Accept XML", f"/rooms/{room}/settings", headers={"Accept": "application/xml"})
    add("406", "/account/users")
    add("406 webmanifest", "/webmanifest")
    add("400 ParameterMissing", f"/rooms/{room}/messages/{message}", urlencode({"_method": "patch"}))
    add("involvement ArgumentError 500", f"/rooms/{room}/involvement?involvement=bogus", urlencode({"_method": "put"}))

    # ActionDispatch::Static.
    _, _ = add("robots.txt", "/robots.txt")
    fields, _ = add("robots.txt HEAD", "/robots.txt", method="HEAD")
    add("robots.txt If-Modified-Since", "/robots.txt?cold=1", headers={"If-Modified-Since": fields["last-modified"]})
    add("robots.txt stale If-Modified-Since", "/robots.txt?cold=2", headers={"If-Modified-Since": "Mon, 01 Jan 2001 00:00:00 GMT"})
    add("robots.txt Range", "/robots.txt?cold=3", headers={"Range": "bytes=0-9"})
    add("robots.txt suffix Range", "/robots.txt?cold=4", headers={"Range": "bytes=-5"})
    add("robots.txt Ranges", "/robots.txt?cold=5", headers={"Range": "bytes=0-1,4-6"})
    add("robots.txt unsatisfiable Range", "/robots.txt?cold=6", headers={"Range": "bytes=500-"})
    add("robots.txt bad Range", "/robots.txt?cold=7", headers={"Range": "bytes=9-1"})
    add("robots.txt/", "/robots.txt/")
    add("escaped robots.txt", "/%72obots.txt")
    add("dotted robots.txt", "/assets/../robots.txt")
    for page in ("404.html", "422.html", "500.html", "502.html", "404", "500"):
        add(f"/{page}", f"/{page}")
    add("404.html gzip", "/404.html", headers={"Accept-Encoding": "gzip"})
    _, page = app.request(f"/rooms/{room}")[1:]
    asset = re.search(rb'href="(/assets/[^"]+\.css)"', page)[1].decode()
    fields, _ = add("asset", asset)
    add("asset If-Modified-Since", asset + "?cold=1", headers={"If-Modified-Since": fields["last-modified"]})
    add("asset Range", asset + "?cold=2", headers={"Range": "bytes=10-19"})
    add("asset HEAD", asset, method="HEAD")

    # The avatar and logo controllers.
    fields, _ = add("logo", "/account/logo")
    add("logo If-None-Match", "/account/logo", headers={"If-None-Match": fields["etag"]})
    add("logo HEAD", "/account/logo", method="HEAD")
    add("small logo", "/account/logo?size=small")
    avatar = re.search(rb'src="(/users/[^"/]+/avatar\?v=\d+)"', page)[1].decode()
    fields, _ = add("initials avatar", avatar)
    add("initials avatar If-None-Match", avatar, headers={"If-None-Match": fields["etag"]})
    add("initials avatar If-None-Match and If-Modified-Since", avatar,
        headers={"If-None-Match": f'"x", {fields["etag"]}', "If-Modified-Since": "Wed, 01 Jan 2031 00:00:00 GMT"})
    add("initials avatar, Accept */*", avatar + "&cold=2", headers={"Accept": "*/*"})
    add("initials avatar, a browser's image Accept", avatar + "&cold=3", headers={"Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"})
    add("avatar of a bad token", "/users/nobody/avatar")
    add("avatar of a bad token, Accept JSON", "/users/nobody/avatar", headers={"Accept": "application/json"})
    app.request("/account/bots/new")
    status, fields, _ = app.request("/account/bots", urlencode({"user[name]": "Deploy Bot"}))
    assert status == 302 and fields["location"].endswith("/account/bots"), (app.image, status, fields)
    # Not app.sql: across Docker Desktop's file sharing, SQLite's WAL index can be stale here.
    bot = re.search(rb'/account/bots/(\d+)/edit', app.request("/account/bots")[2])[1].decode()
    _, _, user_page = app.request(f"/users/{bot}")
    bot_avatar = re.search(rb'src="(/users/[^"/]+/avatar\?v=\d+)"', user_page)[1].decode()
    add("bot avatar", bot_avatar)
    app.request("/users/me/profile")
    upload, kind = multipart([("_method", "patch"), ("user[avatar]", ("face.png", "image/png", png(600, 400)))])
    status, _, _ = app.request("/users/me/profile", upload, kind)
    assert status == 302, status
    _, _, page = app.request(f"/rooms/{room}")
    avatar = re.search(rb'src="(/users/[^"/]+/avatar\?v=\d+)"', page)[1].decode()
    keys = lambda value: re.sub(r"[a-z0-9]{28}", "KEY", value)
    add("uploaded avatar", avatar, body="length", mask=keys)

    # Active Storage's proxies.
    app.request(f"/rooms/{room}")
    image = png(300, 200)
    upload, kind = multipart([("message[client_message_id]", "public-image"), ("message[attachment]", ("photo one.png", "image/png", image))])
    status, _, _ = app.request(f"/rooms/{room}/messages", upload, kind, headers=TURBO)
    assert status == 200, status
    _, _, page = app.request(f"/rooms/{room}")
    blob = re.search(rb'href="(/rails/active_storage/blobs/redirect/[^"]+)"', page)[1].decode().replace("&amp;", "&")
    proxy = blob.replace("/blobs/redirect/", "/blobs/proxy/")
    cold = lambda n: f"{proxy}{'&' if '?' in proxy else '?'}cold={n}"
    # The same secret signs the same blob id alike, so the paths, and the ETags of them, are the same.
    fields, plain = add("blob proxy", proxy, etag="value")
    assert plain == image
    add("blob proxy If-None-Match", proxy, headers={"If-None-Match": fields["etag"]}, etag="value")
    add("blob proxy If-Modified-Since", cold(1), headers={"If-Modified-Since": "Wed, 01 Jan 2031 00:00:00 GMT"}, etag="value")
    add("blob proxy old If-Modified-Since", cold(2), headers={"If-Modified-Since": "Wed, 01 Jan 2003 00:00:00 GMT"}, etag="value")
    add("blob proxy HEAD", proxy, method="HEAD", etag="value")
    add("blob proxy attachment", proxy + "?disposition=attachment", etag="value")
    add("blob proxy Range", cold(3), headers={"Range": "bytes=0-99"})
    add("blob proxy suffix Range", cold(4), headers={"Range": "bytes=-10"})
    add("blob proxy Ranges", cold(5), headers={"Range": "bytes=0-9,20-29"}, body="length",
        mask=lambda value: re.sub(r"boundary=[0-9a-f]{32}", "boundary=HEX", value))
    add("blob proxy unsatisfiable Range", cold(6), headers={"Range": "bytes=999999-"})
    add("blob proxy bad Range", cold(7), headers={"Range": "items=0-1"})
    add("blob proxy of a bad signed id", "/rails/active_storage/blobs/proxy/nope/photo.png")
    thumb = re.search(rb'class="message__attachment" loading="lazy" src="([^"]+)"', page)[1].decode().replace("&amp;", "&")
    representation = thumb.replace("/representations/redirect/", "/representations/proxy/")
    fields, _ = add("representation proxy", representation, etag="value", body="length")
    add("representation proxy If-None-Match", representation, headers={"If-None-Match": fields["etag"]}, etag="value")
    add("representation proxy of a bad variation", re.sub(r"(/representations/proxy/[^/]+/)[^/]+", r"\1nope", representation))
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--reference", default="once-campfire-verification:reference-90b3300")
    args = parser.parse_args()
    secret = secrets.token_hex(64)
    results = {}
    with tempfile.TemporaryDirectory(prefix="campfire-compare-public-") as directory:
        for label, image in (("rails", args.reference), ("goose", args.image)):
            app = App(image, secret, Path(directory) / label)
            try:
                results[label] = scenario(app, secret)
            finally:
                app.close()
    failures = 0
    for (name, rails), (_, goose) in zip(results["rails"], results["goose"]):
        if rails == goose:
            print(f"PASS: {name}: {rails['status']} {rails['content-type'] or ''}")
            continue
        failures += 1
        print(f"FAIL: {name}")
        for key in sorted(set(rails) | set(goose)):
            if rails.get(key) != goose.get(key):
                print(f"  {key}\n    rails: {rails.get(key)}\n    goose: {goose.get(key)}")
    print(f"{len(results['rails']) - failures} of {len(results['rails'])} match")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
