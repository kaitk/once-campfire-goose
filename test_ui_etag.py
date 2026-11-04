#!/usr/bin/env python3
"""What Rails' middleware stack puts on responses: Rack::ETag's weak ETag (the first 32 hex digits of
the body's SHA-256, taken before compression) and Cache-Control (max-age=0, private, must-revalidate
with it, no-cache for a controller's other responses, nothing on exception pages and assets),
Rack::ConditionalGet's 304 (If-None-Match equal to the ETag as a whole, If-Modified-Since against a
Last-Modified), Rack::Head (the GET's fields, Content-Length 0, no body), config.action_dispatch's
default headers on controllers' responses (not on ActionController::Live's), and no Server field.
Run once with the page cache and once without: a cached page's ETag is the uncached page's."""
import gzip
import hashlib
import http.client
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

binary = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parent
DEFAULTS = {"x-frame-options": "SAMEORIGIN", "x-content-type-options": "nosniff",
            "x-permitted-cross-domain-policies": "none", "referrer-policy": "strict-origin-when-cross-origin"}
PRIVATE = "max-age=0, private, must-revalidate"
TURBO = {"Accept": "text/vnd.turbo-stream.html, text/html"}


def png(width, height):
    rows = b"".join(b"\x00" + bytes([(x * 7) % 256 for x in range(width)]) * 3 for _ in range(height))
    chunk = lambda kind, data: struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


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


def rack_etag(body):
    return f'W/"{hashlib.sha256(body).hexdigest()[:32]}"'


def run(cache):
    with tempfile.TemporaryDirectory(prefix="campfire-etag-") as directory:
        work = Path(directory)
        database = work / "production.sqlite3"
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0)); port = probe.getsockname()[1]
        env = dict(os.environ, DATABASE_PATH=str(database), STORAGE_PATH=str(work / "files"), SECRET_KEY_BASE=secrets.token_hex(64),
                   HTTP_PORT=str(port), CAMPFIRE_CACHE="1" if cache else "0", CAMPFIRE_CACHE_DIAGNOSTICS="1")
        with (work / "server.log").open("w+") as log:
            server = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log, cwd=root)

            def request(path, data=None, cookie="", method=None, headers=None, kind="application/x-www-form-urlencoded"):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
                fields = {"Host": f"127.0.0.1:{port}"}
                if cookie: fields["Cookie"] = cookie
                if data is not None:
                    fields.update({"Content-Type": kind, "Sec-Fetch-Site": "same-origin"})
                    if isinstance(data, dict): data = urlencode(data)
                fields.update(headers or {})
                conn.request(method or ("GET" if data is None else "POST"), path, data, fields)
                response = conn.getresponse()
                raw = response.read()
                headers = {k.lower(): v for k, v in response.getheaders()}
                body = gzip.decompress(raw) if headers.get("content-encoding") == "gzip" else raw
                conn.close()
                return response.status, headers, body

            def defaults(headers):
                return {k: headers[k] for k in DEFAULTS if k in headers}

            try:
                for _ in range(200):
                    if server.poll() is not None: raise AssertionError("server exited")
                    try:
                        if request("/up")[0] == 200: break
                    except ConnectionRefusedError: time.sleep(.05)
                else: raise AssertionError("server did not start")
                mode = "cached" if cache else "uncached"

                # Rails::HealthController: a controller's page, its ETag the same in every coding.
                status, headers, body = request("/up")
                assert status == 200 and headers["etag"] == rack_etag(body) and headers["cache-control"] == PRIVATE, headers
                assert headers["content-type"] == "text/html; charset=utf-8" and defaults(headers) == DEFAULTS and "server" not in headers, headers
                assert request("/up", headers={"Accept-Encoding": "gzip"})[1]["etag"] == headers["etag"]
                status, not_modified, body = request("/up", headers={"If-None-Match": headers["etag"]})
                assert status == 304 and body == b"" and not_modified["etag"] == headers["etag"] and not_modified["cache-control"] == PRIVATE
                assert "content-type" not in not_modified and "content-length" not in not_modified and defaults(not_modified) == DEFAULTS, not_modified
                assert request("/up", data="", headers={"If-None-Match": headers["etag"]})[0] != 304

                status, headers, _ = request("/first_run", {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test", "user[password]": "admin password"})
                assert status == 302 and headers["cache-control"] == "no-cache" and "etag" not in headers and defaults(headers) == DEFAULTS, headers
                admin = headers["set-cookie"].split(";", 1)[0]
                status, headers, _ = request("/", cookie=admin)
                assert status == 302 and headers["cache-control"] == "no-cache" and "server" not in headers

                # A turbo stream answering a post: its body's ETag, taken before it is compressed.
                for n in range(3):
                    status, headers, body = request("/rooms/1/messages", {"message[body]": f"etag {n}", "message[client_message_id]": f"etag-{n}"}, admin,
                                                    headers=dict(TURBO, **{"Accept-Encoding": "gzip"}))
                    assert status == 200 and headers["etag"] == rack_etag(body) and headers["cache-control"] == PRIVATE, headers
                    assert defaults(headers) == DEFAULTS
                # POST isn't conditional.
                status, headers, _ = request("/rooms/1/messages", {"message[body]": "etag post", "message[client_message_id]": "etag-post"}, admin,
                                             headers=dict(TURBO, **{"If-None-Match": headers["etag"]}))
                assert status == 200
                print(f"PASS ({mode}): /up and posts carry Rack::ETag's ETag and Cache-Control and the default headers; redirects no-cache; no Server")

                # A room page: the same ETag on a miss and a hit, gzip or not, GET or HEAD.
                status, page, body = request("/rooms/1", cookie=admin)
                assert status == 200 and page["etag"] == rack_etag(body) and page["cache-control"] == PRIVATE and defaults(page) == DEFAULTS, page
                etag = page["etag"]
                for _ in range(5):
                    status, headers, again = request("/rooms/1", cookie=admin)
                    assert again == body and headers["etag"] == etag, headers
                    if headers.get("x-campfire-cache") == "hit": break
                assert headers.get("x-campfire-cache") == ("hit" if cache else None), headers
                status, headers, packed = request("/rooms/1", cookie=admin, headers={"Accept-Encoding": "gzip"})
                assert headers["content-encoding"] == "gzip" and packed == body and headers["etag"] == etag
                for _ in range(2):
                    status, headers, empty = request("/rooms/1", cookie=admin, method="HEAD", headers={"Accept-Encoding": "gzip"})
                    assert status == 200 and empty == b"" and headers["etag"] == etag and headers["content-length"] == "0", headers
                    assert "content-encoding" not in headers and headers["content-type"] == "text/html; charset=utf-8" and defaults(headers) == DEFAULTS
                # Rack::ConditionalGet: the whole If-None-Match must be the ETag.
                for _ in range(2):
                    for method in ("GET", "HEAD"):
                        for coding in ("gzip", "identity"):
                            status, headers, empty = request("/rooms/1", cookie=admin, method=method, headers={"If-None-Match": etag, "Accept-Encoding": coding})
                            assert status == 304 and empty == b"" and headers["etag"] == etag and headers["cache-control"] == PRIVATE, (method, headers)
                            assert not {"content-type", "content-length", "content-encoding"} & set(headers) and defaults(headers) == DEFAULTS, headers
                for tags in (f'"other", {etag}', "*", etag[2:], f" {etag}x", 'W/"other"'):
                    status, headers, again = request("/rooms/1", cookie=admin, headers={"If-None-Match": tags})
                    assert status == 200 and again == body and headers["etag"] == etag, (tags, status)
                # Without a Last-Modified, If-Modified-Since never holds; If-None-Match comes first.
                for since in ("Wed, 01 Jan 2031 00:00:00 GMT", "Mon, 01 Jan 2001 00:00:00 GMT"):
                    assert request("/rooms/1", cookie=admin, headers={"If-Modified-Since": since})[0] == 200
                assert request("/rooms/1", cookie=admin, headers={"If-None-Match": etag, "If-Modified-Since": "Mon, 01 Jan 2001 00:00:00 GMT"})[0] == 304
                assert request("/rooms/1", cookie=admin, headers={"If-None-Match": '"stale"', "If-Modified-Since": "Wed, 01 Jan 2031 00:00:00 GMT"})[0] == 200
                # A new message changes the page, and so its ETag.
                request("/rooms/1/messages", {"message[body]": "etag change", "message[client_message_id]": "etag-change"}, admin, headers=TURBO)
                status, headers, changed = request("/rooms/1", cookie=admin, headers={"If-None-Match": etag})
                assert status == 200 and headers["etag"] == rack_etag(changed) != etag
                print(f"PASS ({mode}): a room page's ETag on misses and hits, gzip and HEAD, and Rack::ConditionalGet's 304 for an exact If-None-Match only")

                # A refresh (an empty one too), and fresh_when's paging: Rack's 304 when If-None-Match holds, whatever If-Modified-Since says.
                status, headers, body = request("/rooms/1/refresh?since=1", cookie=admin, headers={"Accept": "text/vnd.turbo-stream.html"})
                assert status == 200 and headers["etag"] == rack_etag(body), headers
                for method in ("GET", "HEAD"):
                    status, _, _ = request("/rooms/1/refresh?since=1", cookie=admin, method=method,
                                           headers={"Accept": "text/vnd.turbo-stream.html", "If-None-Match": rack_etag(body)})
                    assert status == 304, (method, status)
                status, headers, body = request("/rooms/1/refresh?since=99999999999999", cookie=admin, headers={"Accept": "text/vnd.turbo-stream.html"})
                assert status == 200 and body == b"\n" and headers["etag"] == rack_etag(b"\n")
                status, headers, body = request("/rooms/1/messages?before=3", cookie=admin)
                assert status == 200 and headers["last-modified"] and headers["etag"] and headers["cache-control"] == PRIVATE
                status, stale, _ = request("/rooms/1/messages?before=3", cookie=admin, headers={"If-None-Match": headers["etag"], "If-Modified-Since": "Mon, 01 Jan 2001 00:00:00 GMT"})
                assert status == 304 and stale["etag"] == headers["etag"] and "content-type" not in stale, stale
                with sqlite3.connect(database, timeout=10) as db: last = db.execute("SELECT max(id) FROM messages WHERE room_id=1").fetchone()[0]
                status, headers, _ = request(f"/rooms/1/messages?after={last}", cookie=admin)
                assert status == 204 and headers["cache-control"] == "no-cache" and "etag" not in headers and defaults(headers) == DEFAULTS, headers
                print(f"PASS ({mode}): refreshes and message pages: ETags, 304s and 204's no-cache")

                # JSON, a public Cache-Control kept, and the responses Rack::ETag never sees.
                status, headers, body = request("/autocompletable/users.json?query=a", cookie=admin)
                assert status == 200 and headers["etag"] == rack_etag(body) and headers["cache-control"] == PRIVATE
                status, headers, body = request("/qr_code/ZXRhZw", cookie=admin)
                assert status == 200 and headers["etag"] == rack_etag(body) and headers["cache-control"] == "max-age=31556952, public", headers
                assert request("/qr_code/ZXRhZw", cookie=admin, headers={"If-None-Match": headers["etag"]})[0] == 304
                status, headers, _ = request("/rooms/1/messages/999999/edit", cookie=admin)
                assert status == 404 and "cache-control" not in headers and "etag" not in headers and not defaults(headers), headers
                status, headers, _ = request("/cable")
                assert status == 404 and headers["cache-control"] == "no-cache" and not defaults(headers), headers
                status, headers, _ = request("/session", {"email_address": "ada@example.test", "password": "wrong"})
                assert status == 401 and headers["cache-control"] == "no-cache" and "etag" not in headers and defaults(headers) == DEFAULTS, headers
                status, headers, _ = request("/unfurl_link", {"url": "http://127.0.0.1:1/"}, admin)
                assert status == 204 and headers["cache-control"] == "no-cache" and defaults(headers) == DEFAULTS, headers
                status, _, room = request("/rooms/1", cookie=admin)
                asset = re.search(rb'href="(/assets/[^"]+\.css)"', room)[1].decode()
                status, headers, _ = request(asset)
                assert status == 200 and "etag" not in headers and headers["cache-control"].startswith("public") and not defaults(headers), headers
                # ActionController::Live (ActiveStorage::Streaming): an avatar has its own ETag and no default headers.
                avatar = re.search(rb'src="(/users/[^"/]+/avatar\?v=\d+)"', room)[1].decode()
                status, headers, _ = request(avatar, cookie=admin)
                assert status == 200 and headers["etag"] and not defaults(headers).keys() - {"x-content-type-options"}, headers
                print(f"PASS ({mode}): JSON and public responses get ETags; exception pages, assets and Live controllers' responses no default headers; cable's 404 no-cache")

                # Active Storage: a redirect's own Cache-Control; the disk file, as Rack::Files serves it, has Last-Modified and no ETag.
                upload, kind = multipart([("message[client_message_id]", "etag-image"), ("message[attachment]", ("wide.png", "image/png", png(64, 16)))])
                assert request("/rooms/1/messages", upload, admin, headers=TURBO, kind=kind)[0] == 200
                _, _, room = request("/rooms/1", cookie=admin)
                blob = re.search(rb'href="(/rails/active_storage/blobs/redirect/[^"]+)"', room)[1].decode().replace("&amp;", "&")
                status, headers, _ = request(blob, cookie=admin)
                assert status == 302 and headers["cache-control"] == "max-age=300, private" and "etag" not in headers and defaults(headers) == DEFAULTS, headers
                disk = re.sub(r"^https?://[^/]+", "", headers["location"])
                status, headers, body = request(disk)
                assert status == 200 and body.startswith(b"\x89PNG") and "etag" not in headers and headers["last-modified"], headers
                assert headers["cache-control"] == "max-age=3600, public" and defaults(headers) == DEFAULTS, headers
                assert request(disk, headers={"If-Modified-Since": headers["last-modified"]})[0] == 304
                assert request(disk, headers={"If-None-Match": "*"})[0] == 200
                print(f"PASS ({mode}): Active Storage redirects and disk files")
            finally:
                server.terminate()
                try: server.wait(timeout=5)
                except subprocess.TimeoutExpired: server.kill(); server.wait()
                log.seek(0)
                output = log.read()
                if "database error" in output or "panic" in output.lower(): print(output); raise AssertionError("server errors")


run(cache=True)
run(cache=False)
