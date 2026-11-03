#!/usr/bin/env python3
"""Differential checks of search, room navigation, permalinks and message paging against the Rails
reference image: the same requests, with the same secret, to Rails and to this server, compared by
status, redirect, the last_room cookie, the flash, validators and the pages as parsed HTML
(compare_rendering.py's CanonicalHTML), then by the searches each recorded. Needs Docker and the
reference image:

    python3 compare_ui_search.py once-campfire-goose:search-app [--reference once-campfire-verification:reference-90b3300]

Not compared: the bodies of error responses (Rails' static public/4xx/5xx pages), the session cookie
Rails rewrites on every response, the CSRF meta tags and form tokens, Rack::ETag's ETag on every Rails page, a nil
VAPID key's empty content attribute, and JavaScript asset digests (layout-wide differences outside this
area).
"""
import argparse
import http.client
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
from urllib.parse import urlencode

from compare_rendering import CanonicalHTML
from compare_uploads import App, normalize


class Client(App):
    def request(self, path, data=None, kind="application/x-www-form-urlencoded", method=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        fields = {"Sec-Fetch-Site": "same-origin", "Host": f"127.0.0.1:{self.port}"}
        if self.cookies: fields["Cookie"] = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
        if data is not None:
            fields["Content-Type"] = kind
            if self.csrf: fields["X-CSRF-Token"] = self.csrf
        fields.update(headers or {})
        connection.request(method or ("GET" if data is None else "POST"), path, data, fields)
        response = connection.getresponse()
        self.set_cookies = response.msg.get_all("Set-Cookie") or []
        for cookie in self.set_cookies:
            name, _, value = cookie.split(";", 1)[0].partition("=")
            self.cookies[name] = value
        result = response.status, {k.lower(): v for k, v in response.getheaders()}, response.read()
        token = re.search(rb'<meta name="csrf-token" content="([^"]*)"', result[2])
        if token: self.csrf = token[1].decode()
        connection.close()
        return result


def page(body, base):
    text = normalize(body.decode())
    text = re.sub(r"/account/logo\?v=\d+", "/account/logo?v=VERSION", text)
    text = re.sub(r'data-refresh-room-loaded-at-value="\d+"', 'data-refresh-room-loaded-at-value="TIME"', text)
    # The vendored JavaScript is the Rust reference's revision: four modules' digests differ from the Rails image's.
    text = re.sub(r"-[0-9a-f]{8}\.js", "-DIGEST.js", text)
    text = re.sub(r'<meta name="csrf-(?:param|token)" content="[^"]*" />', "", text)
    events = CanonicalHTML(text, base).events
    # Forms' CSRF tokens, as the meta tags.
    events = [e for e in events if not (e[0] == "start" and e[1] == "input" and ("name", "authenticity_token") in e[2])]
    # Layout-wide, outside this area: Rails leaves out a nil VAPID key's content attribute.
    vapid = ("start", "meta", [("content", ""), ("name", "vapid-public-key")])
    return [("start", "meta", [("name", "vapid-public-key")]) if event == vapid else event for event in events]


def observe(app, label, path, data=None, method=None, headers=None, body=True):
    status, fields, content = app.request(path, None if data is None else urlencode(data), method=method, headers=headers)
    cookies = {}
    for cookie in app.set_cookies:
        name = cookie.split("=", 1)[0]
        if name == "last_room":
            cookies[name] = re.sub(r"expires=[^;]+", "expires=DATE", cookie)
    seen = {"status": status, "location": re.sub(r"^https?://[^/]+", "", fields.get("location", "")), "cookies": cookies,
            "flash": "Room not found or inaccessible" in content.decode(errors="replace")}
    if status in (200, 304):
        seen["content-type"] = fields.get("content-type")
        # Rack::ETag gives every Rails page an ETag; only MessagesController#index's fresh_when is this area's.
        if path.startswith("/rooms/1/messages") and data is None:
            seen["validators"] = sorted(k for k in ("etag", "last-modified", "cache-control") if k in fields)
    if status == 200 and body:
        seen["page"] = page(content, f"http://127.0.0.1:{app.port}")
    return label, seen


def scenario(app, room_alert):
    out = []
    add = lambda *args, **kw: out.append(observe(app, *args, **kw))
    app.request("/first_run")
    status, _, _ = app.request("/first_run", urlencode({"user[name]": "Ada Admin", "user[email_address]": "ada@example.test", "user[password]": "admin password 123"}))
    assert status in (302, 303), status
    texts = ["hello-world one", "hello world two", "café crème", "under_score three"] + [f"filler {n:02}" for n in range(46)]
    app.request("/rooms/1")
    for n, text in enumerate(texts):
        status, _, _ = app.request("/rooms/1/messages", urlencode({"message[body]": text, "message[client_message_id]": f"compare-{n}"}),
                                   headers={"Accept": "text/vnd.turbo-stream.html, text/html"})
        assert status == 200, (n, status)
    add("root", "/")
    add("rooms#index", "/rooms")
    add("room", "/rooms/1")
    add("room HEAD", "/rooms/1", method="HEAD", body=False)
    add("permalink", "/rooms/1/@10")
    add("permalink not a message", "/rooms/1/@abc")
    add("page before", "/rooms/1/messages?before=45")
    add("page after", "/rooms/1/messages?after=3")
    add("page after empty param", "/rooms/1/messages?after=")
    add("page after the last", "/rooms/1/messages?after=50")
    add("page before the first", "/rooms/1/messages?before=1")
    add("page before a missing message", "/rooms/1/messages?before=999")
    add("page of a room not joined", "/rooms/999/messages")
    add("page as JSON", "/rooms/1/messages", headers={"Accept": "application/json"})
    add("search without q", "/searches")
    add("search posted", "/searches", {"q": "hello-world"})
    add("search page", "/searches?q=hello+world")
    add("search hyphenated", "/searches?q=hello-world")
    add("search accented", "/searches?" + urlencode({"q": "café"}))
    add("search underscore", "/searches?q=under_score")
    add("search blank", "/searches?q=+-+")
    add("search FTS operator", "/searches?q=AND")
    add("search posted FTS operator", "/searches", {"q": "AND"})
    add("search posted empty", "/searches", {"q": ""})
    add("search posted without q", "/searches", {"x": "1"})
    for word in "abcdefghij":
        app.request("/searches", urlencode({"q": word}))
    add("search posted again", "/searches", {"q": "hello world"})
    add("search with recents", "/searches?q=filler")
    add("search as JSON", "/searches?q=hello", headers={"Accept": "application/json"})
    add("search in a frame", "/searches?q=hello", headers={"Turbo-Frame": "search"})
    add("room as JSON", "/rooms/1", headers={"Accept": "application/json"})
    for accept in ("*/*", "image/png", "text/*", "application/xhtml+xml", "text/vnd.turbo-stream.html", "text/html;q=0.9, application/json"):
        add(f"room with Accept {accept}", "/rooms/1", headers={"Accept": accept})
    add("room in a frame", "/rooms/1", headers={"Turbo-Frame": "room"})
    add("permalink in a frame", "/rooms/1/@20", headers={"Turbo-Frame": "room"})
    _, fields, _ = app.request("/rooms/1/messages?before=30")
    add("page revalidated by ETag", "/rooms/1/messages?before=30", headers={"If-None-Match": fields["etag"]})
    add("page revalidated by date", "/rooms/1/messages?before=30", headers={"If-Modified-Since": fields["last-modified"]})
    add("page revalidated by both, one stale", "/rooms/1/messages?before=30", headers={"If-Modified-Since": fields["last-modified"], "If-None-Match": 'W/"stale"'})
    add("room not joined", f"/rooms/{room_alert}")
    add("root keeps the flash", "/")
    add("room shows the flash", "/rooms/1")
    add("room after the flash", "/rooms/1")
    app.request("/rooms/1")
    add("delete room", "/rooms/1", {"_method": "delete"})
    add("post to the deleted room", "/rooms/1/messages", {"message[body]": "late", "message[client_message_id]": "late"},
        headers={"Accept": "text/vnd.turbo-stream.html, text/html"})
    add("welcome", "/")
    add("rooms#index without rooms", "/rooms")
    add("search without rooms", "/searches")
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--reference", default="once-campfire-verification:reference-90b3300")
    args = parser.parse_args()
    secret = secrets.token_hex(64)
    results, searches = {}, {}
    with tempfile.TemporaryDirectory(prefix="campfire-compare-search-") as directory:
        for label, image in (("rails", args.reference), ("goose", args.image)):
            app = Client(image, secret, Path(directory) / label)
            try:
                results[label] = scenario(app, 999)
                # The database is read once the container has stopped: a bind mount shares no WAL index with it.
                subprocess.run(["docker", "stop", "-t", "20", app.name], stdout=subprocess.DEVNULL)
                searches[label] = app.sql("SELECT user_id,query FROM searches ORDER BY updated_at DESC")
            finally:
                logs = subprocess.run(["docker", "logs", app.name], capture_output=True, text=True)
                (Path(directory) / f"{label}.log").write_text(logs.stdout + logs.stderr)
                app.close()
    failures = 0
    for (name, rails), (_, goose) in zip(results["rails"], results["goose"]):
        if rails == goose:
            print(f"PASS: {name}: {rails['status']}" + (f" ({len(rails['page'])} HTML events)" if "page" in rails else ""))
            continue
        failures += 1
        print(f"FAIL: {name}")
        for key in sorted(set(rails) | set(goose)):
            a, b = rails.get(key), goose.get(key)
            if a == b: continue
            if key == "page" and a and b:
                at = next(i for i, (p, q) in enumerate(zip(a + [None], b + [None])) if p != q)
                print(f"  page differs at event {at} of {len(a)}/{len(b)}\n    rails: {a[at:at + 3]}\n    goose: {b[at:at + 3]}")
            else:
                print(f"  {key}\n    rails: {str(a)[:300]}\n    goose: {str(b)[:300]}")
    if searches["rails"] == searches["goose"]: print(f"PASS: recorded searches match: {searches['rails']}")
    else: failures += 1; print(f"FAIL: recorded searches\n  rails: {searches['rails']}\n  goose: {searches['goose']}")
    print(f"{len(results['rails']) + 1 - failures} of {len(results['rails']) + 1} match")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
