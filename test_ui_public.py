#!/usr/bin/env python3
"""What Rails answers above and beside its controllers: ShowExceptions' and PublicExceptions' pages
(public/<status>.html, or an empty page, in charset=UTF-8; the { status:, error: } hash for JSON,
XML and YAML; an empty body for a HEAD; no Rack::ETag fields, default headers or version headers),
ActionDispatch::Static's public/ files and assets (Rack::Files' Last-Modified, If-Modified-Since,
byte ranges, production.rb's Cache-Control), controllers' `head`s, the avatar and logo
controllers (ActionController::Live: no default headers, expires_in's Cache-Control, a weak ETag,
send_file's disposition, users/avatars/show.svg.erb), and Active Storage's proxies (streamed, with
http_cache_forever's validators, Range, 304)."""
import gzip
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from urllib.parse import urlencode

binary = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parent
DEFAULTS = ("x-frame-options", "x-xss-protection", "x-content-type-options", "x-permitted-cross-domain-policies", "referrer-policy")
TURBO = {"Accept": "text/vnd.turbo-stream.html, text/html"}
COLORS = "#AF2E1B #CC6324 #3B4B59 #BFA07A #ED8008 #ED3F1C #BF1B1B #736B1E #D07B53 #736356 #AD1D1D #BF7C2A #C09C6F #698F9C #7C956B #5D618F #3B3633 #67695E".split()
# users/avatars/show.svg.erb, at the Rails reference's revision.
AVATAR = """<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
  viewBox="0 0 512 512" class="avatar" aria-hidden="true">
  <defs>
    <clipPath id="porthole">
      <circle cx="50%" cy="50%" r="50%" />
    </clipPath>
  </defs>

  <g>
    <rect width="100%" height="100%" rx="50" fill="{color}" />

    <text x="50%" y="50%" fill="#FFFFFF"
      text-anchor="middle" dy="0.35em"
      {length}
      font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif"
      font-size="230"
      font-weight="800"
      letter-spacing="-5">
      {initials}
    </text>
  </g>
</svg>
"""


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


def weak(key):
    return f'W/"{hashlib.sha256(key.encode()).hexdigest()[:32]}"'


def main():
    # Rails' public/ files, as views/public.json records them.
    record = json.loads((root / "views/public.json").read_text())
    for name, digest in record["files_sha256"].items():
        assert hashlib.sha256((root / "public" / name).read_bytes()).hexdigest() == digest, name
    assert sorted(p.name for p in (root / "public").iterdir()) == sorted(record["files_sha256"])
    page = {status: (root / f"public/{status}.html").read_bytes() for status in (404, 422, 500)}
    robots = (root / "public/robots.txt").read_bytes()
    print("PASS: public/ holds Rails' files, as views/public.json records them")

    with tempfile.TemporaryDirectory(prefix="campfire-public-") as directory:
        work = Path(directory)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0)); port = probe.getsockname()[1]
        env = dict(os.environ, DATABASE_PATH=str(work / "production.sqlite3"), STORAGE_PATH=str(work / "files"), SECRET_KEY_BASE=secrets.token_hex(64),
                   HTTP_PORT=str(port), APP_VERSION="public", GIT_REVISION="public")
        with (work / "server.log").open("w+") as log:
            server = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log, cwd=root)

            def request(path, data=None, cookie="", method=None, headers=None, kind="application/x-www-form-urlencoded"):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
                fields = {"Host": f"127.0.0.1:{port}"}
                if cookie: fields["Cookie"] = cookie
                if data is not None:
                    fields.update({"Content-Type": kind, "Sec-Fetch-Site": "same-origin"})
                    if isinstance(data, dict): data = urlencode(data)
                fields.update(headers or {})
                conn.request(method or ("GET" if data is None else "POST"), path, data, fields)
                response = conn.getresponse()
                raw = response.read()
                fields = {k.lower(): v for k, v in response.getheaders()}
                body = gzip.decompress(raw) if fields.get("content-encoding") == "gzip" else raw
                conn.close()
                return response.status, fields, body

            def exception(status, fields, body, expected, kind="text/html; charset=UTF-8"):
                assert fields.get("content-type") == kind and body == expected, (status, fields, body[:200])
                assert not {"cache-control", "etag", "x-version", "x-rev"} & set(fields) and not set(DEFAULTS) & set(fields), fields

            try:
                for _ in range(200):
                    if server.poll() is not None: raise AssertionError("server exited")
                    try:
                        if request("/up")[0] == 200: break
                    except ConnectionRefusedError: time.sleep(.05)
                else: raise AssertionError("server did not start")
                status, headers, _ = request("/first_run", {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test", "user[password]": "admin password"})
                assert status == 302, status
                admin = headers["set-cookie"].split(";", 1)[0]
                status, headers, stream = request("/rooms/1/messages", {"message[body]": "public", "message[client_message_id]": "public-1"}, admin, headers=TURBO)
                assert status == 200, status
                message = re.search(rb'data-message-id="(\d+)"', stream)[1].decode()

                # PublicExceptions: the page, or the hash in the request's format.
                for path in ("/nope", "/assets/nope-0123abcd.css", "/rooms/1/messages/999999/edit"):
                    status, headers, body = request(path, cookie=admin)
                    assert status == 404, (path, status)
                    exception(status, headers, body, page[404])
                status, headers, body = request("/nope", cookie=admin, headers={"Accept-Encoding": "gzip"})
                assert status == 404 and headers["content-encoding"] == "gzip" and body == page[404]
                status, headers, body = request("/nope.json", cookie=admin)
                exception(status, headers, body, b'{"status":404,"error":"Not Found"}', "application/json; charset=UTF-8")
                status, headers, body = request("/nope", cookie=admin, headers={"Accept": "application/xml"})
                exception(status, headers, body, b'<?xml version="1.0" encoding="UTF-8"?>\n<hash>\n  <status type="integer">404</status>\n  <error>Not Found</error>\n</hash>\n',
                          "application/xml; charset=UTF-8")
                status, headers, body = request("/nope", cookie=admin, headers={"Accept": "application/json;q=0.5, application/x-yaml"})
                exception(status, headers, body, b"---\n:status: 404\n:error: Not Found\n", "application/x-yaml; charset=UTF-8")
                # A browser's Accept, listing */* among others, is ignored: the path's extension decides.
                status, headers, body = request("/nope.json", cookie=admin, headers={"Accept": "text/html,application/xhtml+xml,*/*;q=0.8"})
                exception(status, headers, body, b'{"status":404,"error":"Not Found"}', "application/json; charset=UTF-8")
                status, headers, body = request("/nope", cookie=admin, method="HEAD")
                exception(status, headers, body, b"")
                assert headers["content-length"] == "0"
                status, headers, body = request("/nope", cookie=admin, method="HEAD", headers={"Accept": "*/*"})
                exception(status, headers, body, b"", "*/*; charset=UTF-8")
                status, headers, body = request("/up", "", admin)
                assert status == 404 and body == page[404], status
                status, headers, body = request("/searches", {"q": "x"}, admin, headers={"Sec-Fetch-Site": "cross-site"})
                assert status == 422
                exception(status, headers, body, page[422])
                status, headers, body = request("/searches", {"q": "x"}, admin, headers={"Sec-Fetch-Site": "cross-site", "Accept": "application/json"})
                exception(status, headers, body, b'{"status":422,"error":"Unprocessable Content"}', "application/json; charset=UTF-8")
                status, headers, body = request("/rooms/1/settings", cookie=admin)
                assert status == 500
                exception(status, headers, body, page[500])
                status, headers, body = request("/rooms/1/involvement?involvement=bogus", {"_method": "put"}, admin)
                assert status == 500
                exception(status, headers, body, page[500])
                # No 406.html or 400.html: ShowExceptions' empty page.
                status, headers, body = request("/account/users", cookie=admin)
                assert status == 406
                exception(status, headers, body, b"")
                status, headers, body = request(f"/rooms/1/messages/{message}", {"_method": "patch"}, admin)
                assert status == 400
                exception(status, headers, body, b"")
                print("PASS: exception pages in the request's format: public/<status>.html, the hash in JSON, XML or YAML, a HEAD's empty body; no Rack fields or version headers")

                # ActionDispatch::Static.
                status, headers, body = request("/robots.txt")
                assert status == 200 and body == robots and headers["content-type"] == "text/plain", headers
                assert headers["cache-control"] == "public, max-age=2592000" and headers["last-modified"] and "etag" not in headers, headers
                assert not set(DEFAULTS) & set(headers) and "x-version" not in headers and "set-cookie" not in headers, headers
                modified = headers["last-modified"]
                status, headers, body = request("/robots.txt", method="HEAD")
                assert status == 200 and body == b"" and headers["content-length"] == str(len(robots)), headers
                status, headers, body = request("/robots.txt", headers={"If-Modified-Since": modified})
                assert status == 304 and body == b"" and "cache-control" not in headers and "content-type" not in headers, headers
                assert request("/robots.txt", headers={"If-Modified-Since": "Mon, 01 Jan 2001 00:00:00 GMT"})[0] == 200
                status, headers, body = request("/robots.txt", headers={"Range": "bytes=0-9"})
                assert status == 206 and body == robots[:10] and headers["content-range"] == f"bytes 0-9/{len(robots)}", headers
                status, headers, body = request("/robots.txt", headers={"Range": "bytes=-5"})
                assert status == 206 and body == robots[-5:]
                status, headers, body = request("/robots.txt", headers={"Range": "bytes=0-1,4-6"})
                assert status == 206 and headers["content-type"] == "text/plain", headers
                assert body == (f"\r\n--AaB03x\r\ncontent-type: text/plain\r\ncontent-range: bytes 0-1/{len(robots)}\r\n\r\n").encode() + robots[:2] + \
                    (f"\r\n--AaB03x\r\ncontent-type: text/plain\r\ncontent-range: bytes 4-6/{len(robots)}\r\n\r\n").encode() + robots[4:7] + b"\r\n--AaB03x--\r\n", body
                status, headers, body = request("/robots.txt", headers={"Range": "bytes=500-"})
                assert status == 416 and body == b"Byte range unsatisfiable\n" and headers["x-cascade"] == "pass" and headers["content-range"] == f"bytes */{len(robots)}"
                assert request("/robots.txt", headers={"Range": "bytes=9-1"})[0] == 200
                for path in ("/robots.txt/", "/%72obots.txt", "//robots.txt", "/x/../robots.txt"):
                    assert request(path)[2] == robots, path
                for path, status_page in (("/404.html", 404), ("/404", 404), ("/500", 500), ("/422.html", 422)):
                    status, headers, body = request(path)
                    assert status == 200 and body == page[status_page] and headers["content-type"] == "text/html" and headers["cache-control"].startswith("public"), (path, headers)
                status, headers, body = request("/404.html", headers={"Accept-Encoding": "gzip"})
                assert headers.get("content-encoding") == "gzip" and body == page[404]
                _, _, room = request("/rooms/1", cookie=admin)
                asset = re.search(rb'href="(/assets/[^"]+\.css)"', room)[1].decode()
                status, headers, css = request(asset)
                assert status == 200 and headers["content-type"] == "text/css" and "x-version" not in headers
                assert request(asset, headers={"If-Modified-Since": headers["last-modified"]})[0] == 304
                assert request(asset, headers={"Range": "bytes=0-3"})[2] == css[:4]
                print("PASS: public/ and asset files as ActionDispatch::Static serves them: types, Cache-Control, Last-Modified, If-Modified-Since, byte ranges, .html")

                # Users::AvatarsController and Accounts::LogosController (ActionController::Live).
                avatar = re.search(rb'src="(/users/[^"/]+/avatar\?v=\d+)"', room)[1].decode()
                status, headers, body = request(avatar, cookie=admin)
                expected = AVATAR.format(color=COLORS[zlib.crc32(b"1") % 18], length="", initials="AA").encode()
                assert status == 200 and body == expected, body
                assert headers["content-type"] == "image/svg+xml; charset=utf-8" and headers["cache-control"] == "max-age=1800, public, stale-while-revalidate=604800", headers
                assert re.fullmatch(r'W/"[0-9a-f]{32}"', headers["etag"]) and not set(DEFAULTS) & set(headers) and "content-length" not in headers, headers
                etag = headers["etag"]
                for tags in (etag, f'"x", {etag}', "*"):
                    status, headers, body = request(avatar, cookie=admin, headers={"If-None-Match": tags})
                    assert status == 304 and body == b"" and headers["etag"] == etag, (tags, status)
                # EtagWithTemplateDigest: the template is found for */*, not for html.
                assert request(avatar, cookie=admin, headers={"Accept": "*/*"})[1]["etag"] != etag
                assert request(avatar, cookie=admin, headers={"Accept": "image/avif,image/webp,*/*;q=0.8"})[1]["etag"] == etag
                status, headers, body = request("/users/nobody/avatar", cookie=admin)
                assert status == 404 and body == b"" and headers["content-type"] == "text/html" and headers["cache-control"] == "no-cache", headers
                assert not set(DEFAULTS) & set(headers), headers
                assert request("/users/nobody/avatar", cookie=admin, headers={"Accept": "application/json"})[1]["content-type"] == "application/json"
                status, headers, logo = request("/account/logo")
                assert status == 200 and logo.startswith(b"\x89PNG") and headers["cache-control"] == "max-age=300, public, stale-while-revalidate=604800", headers
                assert headers["content-disposition"] == "inline; filename=\"app-icon.png\"; filename*=UTF-8''app-icon.png" and headers["content-transfer-encoding"] == "binary"
                assert re.fullmatch(r'W/"[0-9a-f]{32}"', headers["etag"]) and not set(DEFAULTS) & set(headers), headers
                status, headers, _ = request("/account/logo", headers={"If-None-Match": headers["etag"]})
                assert status == 304 and headers["content-disposition"].startswith("inline")
                status, headers, body = request("/account/logo", method="HEAD")
                assert status == 200 and body == b"" and headers["content-length"] == "0", headers
                request("/account/bots", {"user[name]": "Deploy Bot"}, admin)
                bots = request("/account/bots", cookie=admin)[2]
                bot = re.search(rb"/account/bots/(\d+)/edit", bots)[1].decode()
                # The bots' routes default to JSON: a message not found is its hash; set_room's head is empty.
                key = re.search(rb"/rooms/\d+/(\d+-[A-Za-z0-9]+)/messages", bots)[1].decode()
                status, headers, body = request(f"/rooms/1/{key}/messages/999999", "x", method="PUT", headers={"Content-Type": "text/plain"})
                exception(status, headers, body, b'{"status":404,"error":"Not Found"}', "application/json; charset=UTF-8")
                status, headers, body = request(f"/rooms/999/{key}/messages", "x", headers={"Content-Type": "text/plain"})
                assert status == 404 and body == b"" and headers["content-type"] == "text/html" and headers["cache-control"] == "no-cache", headers
                bot_avatar = re.search(rb'src="(/users/[^"/]+/avatar\?v=\d+)"', request(f"/users/{bot}", cookie=admin)[2])[1].decode()
                status, headers, body = request(bot_avatar, cookie=admin)
                assert status == 200 and body.startswith(b'<svg enable-background="new 0 0 18 18"') and headers["content-type"] == "image/svg+xml", headers
                assert headers["content-disposition"] == "inline; filename=\"default-bot-avatar.svg\"; filename*=UTF-8''default-bot-avatar.svg"
                print("PASS: avatars and the logo: the initials template, the bot's file, weak ETags and 304s, expires_in's Cache-Control, send_file's fields, no default headers, a bad token's head")

                # Active Storage's proxies.
                image = png(64, 16)
                upload, kind = multipart([("message[client_message_id]", "public-image"), ("message[attachment]", ("photo one.png", "image/png", image))])
                assert request("/rooms/1/messages", upload, admin, headers=TURBO, kind=kind)[0] == 200
                _, _, room = request("/rooms/1", cookie=admin)
                blob = re.search(rb'href="(/rails/active_storage/blobs/redirect/[^"]+)"', room)[1].decode().replace("&amp;", "&")
                proxy = blob.replace("/blobs/redirect/", "/blobs/proxy/")
                status, headers, body = request(proxy)
                assert status == 200 and body == image and headers["etag"] == weak(proxy) and headers["last-modified"] == "Sat, 01 Jan 2011 00:00:00 GMT", headers
                assert headers["cache-control"] == "max-age=3155695200, public, immutable" and headers["accept-ranges"] == "bytes" and "content-length" not in headers
                assert headers["content-type"] == "image/png" and headers["content-disposition"].endswith("filename*=UTF-8''photo%20one.png") and not set(DEFAULTS) & set(headers)
                status, headers, body = request(proxy, headers={"If-None-Match": weak(proxy)})
                assert status == 304 and headers["etag"] == weak(proxy) and body == b""
                assert request(proxy, headers={"If-Modified-Since": "Wed, 01 Jan 2031 00:00:00 GMT"})[0] == 304
                assert request(proxy, headers={"If-Modified-Since": "Wed, 01 Jan 2003 00:00:00 GMT"})[0] == 200
                status, headers, body = request(proxy, method="HEAD")
                assert status == 200 and body == b"" and headers["content-length"] == "0"
                status, headers, body = request(proxy, headers={"Range": "bytes=2-5"})
                assert status == 206 and body == image[2:6] and headers["content-range"] == f"bytes 2-5/{len(image)}" and headers["cache-control"] == "no-cache", headers
                assert headers["content-transfer-encoding"] == "binary" and "etag" not in headers
                status, headers, body = request(proxy, headers={"Range": "bytes=0-1,4-5"})
                boundary = re.fullmatch(r"multipart/byteranges; boundary=([0-9a-f]{32})", headers["content-type"])[1]
                assert status == 206 and body == (f"\r\n--{boundary}\r\nContent-Type: image/png\r\nContent-Range: bytes 0-1/{len(image)}\r\n\r\n").encode() + image[:2] + \
                    (f"\r\n--{boundary}\r\nContent-Type: image/png\r\nContent-Range: bytes 4-5/{len(image)}\r\n\r\n").encode() + image[4:6] + f"\r\n--{boundary}--\r\n".encode()
                for bad in ("bytes=999999-", "items=0-1"):
                    status, headers, body = request(proxy, headers={"Range": bad})
                    assert status == 416 and body == b"" and headers["cache-control"] == "no-cache", (bad, headers)
                status, headers, body = request("/rails/active_storage/blobs/proxy/nope/photo.png")
                assert status == 404 and body == b"" and headers["content-type"] == "text/html", headers
                thumb = re.search(rb'class="message__attachment" loading="lazy" src="([^"]+)"', room)[1].decode().replace("&amp;", "&")
                representation = thumb.replace("/representations/redirect/", "/representations/proxy/")
                status, headers, body = request(representation)
                assert status == 200 and body.startswith(b"\x89PNG") and headers["etag"] == weak(representation) and headers["content-type"] == "image/png", headers
                assert request(representation, headers={"If-None-Match": weak(representation)})[0] == 304
                print("PASS: Active Storage's proxies stream blobs and representations with http_cache_forever's validators, 304s and byte ranges")
            finally:
                server.terminate()
                try: server.wait(timeout=5)
                except subprocess.TimeoutExpired: server.kill(); server.wait()
                log.seek(0)
                output = log.read()
                if "panic" in output.lower(): print(output); raise AssertionError("server errors")


main()
