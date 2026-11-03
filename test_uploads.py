#!/usr/bin/env python3
"""Uploads through Active Storage: message attachments, their thumbnails, avatars, the logo's
variants, the blob and disk routes, authorization and the upload body limit."""
import base64
import hashlib
import hmac
import html
import http.client
import json
import math
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
from urllib.parse import quote, urlencode, urlsplit
import zlib

binary = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parent
UPLOAD_LIMIT = 2 << 20

# A 40x20 JPEG whose EXIF orientation (6, Right-top) turns it a quarter: Rails analyzes it as 20x40.
TURNED_JPEG = base64.b64decode(
    "/9j/4QC8RXhpZgAASUkqAAgAAAAGABIBAwABAAAABgAAABoBBQABAAAAVgAAABsBBQABAAAAXgAAACgBAwABAAAAAgAAABMCAwABAAAAAQAAAGmHBAABAAAAZgAAAAAAAABIAAAAAQAAAEgAAAABAAAABgAAkAcABAAAADAyMTABkQcABAAAAAECAwAAoAcABAAAADAxMDABoAMAAQAAAP//AAACoAQAAQAAACgAAAADoAQAAQAAABQAAAAAAAAA/9sAQwAGBAUGBQQGBgUGBwcGCAoQCgoJCQoUDg8MEBcUGBgXFBYWGh0lHxobIxwWFiAsICMmJykqKRkfLTAtKDAlKCko/9sAQwEHBwcKCAoTCgoTKBoWGigoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgo/8AAEQgAFAAoAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/aAAwDAQACEQMRAD8A8QttC6fLWrbaF0+Wu/ttC6fLWrbaF0+T9K6K2b+Z4WXZ7tqcBbaF0+WtW20Lp8td/baF0+WtW20Lp8n6V5VbN/M+8y7PdtTgLbQuny0V6pbaF0+T9KK86eb67n2eHz33NylbWcPHy1q21nDx8tFFedWk+5/JeXSempq29nDx8tattZw8fLRRXl1pPufeZdJ6amrbWcPHy0UUV5s5O+59nh5Pk3P/2Q==")


def png(width, height, blue=96):
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows += bytes((x * 255 // max(width - 1, 1), y * 255 // max(height - 1, 1), blue))
    def chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))


def jpeg(width, height, blue=96, aspect=None, ffmpeg=("ffmpeg",)):
    """A JPEG of png(width, height, blue), encoded by ffmpeg, with a JFIF density of aspect (x, y),
    which ffprobe reads as the sample aspect ratio."""
    frame = subprocess.run([*ffmpeg, "-v", "error", "-i", "pipe:0", "-frames:v", "1", "-f", "image2", "-"],
                           input=png(width, height, blue), check=True, capture_output=True).stdout
    if aspect:
        frame = frame[:2] + b"\xff\xe0" + struct.pack(">H5sBBBHHBB", 16, b"JFIF", 1, 1, 0, *aspect, 0, 0) + frame[2:]
    return frame


def avi(width, height, frames, fps=10):
    """An MJPEG AVI of JPEG frames: the image's ffmpeg encodes JPEGs only, so the container is
    written here."""
    def chunk(kind, data):
        return kind + struct.pack("<I", len(data)) + data + (b"\0" if len(data) % 2 else b"")
    largest = max(map(len, frames))
    avih = struct.pack("<IIIIIIIIII16x", 1000000 // fps, 0, 0, 0x10, len(frames), 0, 1, largest, width, height)
    strh = struct.pack("<4s4sIHHIIIIIIIIhhhh", b"vids", b"MJPG", 0, 0, 0, 0, 1, fps, 0, len(frames), largest, 0xffffffff, 0, 0, 0, width, height)
    strf = struct.pack("<IiiHH4sIiiII", 40, width, height, 1, 24, b"MJPG", width * height * 3, 0, 0, 0, 0)
    header = chunk(b"LIST", b"hdrl" + chunk(b"avih", avih) + chunk(b"LIST", b"strl" + chunk(b"strh", strh) + chunk(b"strf", strf)))
    movie, index = b"", b""
    for frame in frames:
        index += struct.pack("<4sIII", b"00dc", 0x10, 4 + len(movie), len(frame))
        movie += chunk(b"00dc", frame)
    body = b"AVI " + header + chunk(b"LIST", b"movi" + movie) + chunk(b"idx1", index)
    return b"RIFF" + struct.pack("<I", len(body)) + body


def wav(seconds=0.25, rate=8000):
    """A mono 16-bit PCM WAV of a 440 Hz tone."""
    samples = b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(int(seconds * rate)))
    def chunk(kind, data):
        return kind + struct.pack("<I", len(data)) + data
    body = b"WAVE" + chunk(b"fmt ", struct.pack("<HHIIHH", 1, 1, rate, rate * 2, 2, 16)) + chunk(b"data", samples)
    return b"RIFF" + struct.pack("<I", len(body)) + body


def dimensions(data):
    """The width and height of a PNG, JPEG or WebP."""
    if data.startswith(b"\x89PNG"):
        return struct.unpack("!II", data[16:24])
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        kind = data[12:16]
        if kind == b"VP8X":
            return 1 + int.from_bytes(data[24:27], "little"), 1 + int.from_bytes(data[27:30], "little")
        if kind == b"VP8 ":
            return struct.unpack("<H", data[26:28])[0] & 0x3fff, struct.unpack("<H", data[28:30])[0] & 0x3fff
        if kind == b"VP8L":
            bits = int.from_bytes(data[21:25], "little")
            return (bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1
    if data.startswith(b"\xff\xd8"):
        at = 2
        while at < len(data):
            marker, size = data[at + 1], struct.unpack("!H", data[at + 2:at + 4])[0]
            if 0xc0 <= marker <= 0xc3:
                height, width = struct.unpack("!HH", data[at + 5:at + 9])
                return width, height
            at += 2 + size
    raise AssertionError(f"unknown image {data[:16]!r}")


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


class Verifier:
    """ActiveStorage.verifier, from the secret the server runs with."""
    def __init__(self, secret):
        self.key = hashlib.pbkdf2_hmac("sha256", secret.encode(), b"ActiveStorage", 1000, 64)

    def generate(self, data, purpose):
        payload = base64.b64encode(f'{{"_rails":{{"data":{data},"pur":"{purpose}"}}}}'.encode())
        return (payload + b"--" + hmac.new(self.key, payload, "sha1").hexdigest().encode()).decode()


def marshal_digest(fmt, symbol, width=None, height=None):
    """Variation#digest: SHA1 of Marshal.dump({format:, resize_to_limit:}), Base64."""
    def long(n):
        if n == 0: return b"\x00"
        if 0 < n < 123: return bytes([n + 5])
        out = []; x = n
        for i in range(1, 9):
            out.append(x & 255); x >>= 8
            if x == 0: return bytes([i]) + bytes(out)
    def sym(name): return b":" + long(len(name)) + name
    value = sym(fmt.encode()) if symbol else b'I"' + long(len(fmt)) + fmt.encode() + long(1) + sym(b"E") + b"T"
    dump = b"\x04\x08{" + long(1 if width is None else 2) + sym(b"format") + value
    if width is not None:
        dump += sym(b"resize_to_limit") + b"[" + long(2) + b"i" + long(width) + b"i" + long(height)
    return base64.b64encode(hashlib.sha1(dump).digest()).decode()


def escape_segment(text):
    return quote(text, safe="-._~!$&'()*+,;=:@")


class WebSocket:
    def __init__(self, port, cookie):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=20)
        self.sock.sendall((f"GET /cable HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\n"
                           f"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nCookie: {cookie}\r\n\r\n").encode())
        head = b""
        while not head.endswith(b"\r\n\r\n"): head += self.take(1)
        assert head.startswith(b"HTTP/1.1 101"), head
        assert self.receive()["type"] == "welcome"

    def take(self, size):
        data = bytearray()
        while len(data) < size:
            part = self.sock.recv(size - len(data)); assert part, "WebSocket EOF"; data.extend(part)
        return bytes(data)

    def receive(self):
        result = bytearray()
        while True:
            op, size = self.take(2)
            if size == 126: size = struct.unpack("!H", self.take(2))[0]
            elif size == 127: size = struct.unpack("!Q", self.take(8))[0]
            result.extend(self.take(size))
            if op & 0x80: return json.loads(result)

    def subscribe(self, identifier):
        data = json.dumps({"command": "subscribe", "identifier": identifier}).encode()
        mask = secrets.token_bytes(4)
        size = bytes([0x80 | len(data)]) if len(data) < 126 else b"\xfe" + struct.pack("!H", len(data))
        self.sock.sendall(b"\x81" + size + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))
        while True:
            message = self.receive()
            if message.get("identifier") == identifier and "type" in message: return message["type"]

    def publication(self, marker):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            message = self.receive()
            if isinstance(message.get("message"), str) and marker in message["message"]: return message["message"]
        raise TimeoutError(f"no publication with {marker!r}")


def main():
    with tempfile.TemporaryDirectory(prefix="campfire-uploads-") as directory:
        work = Path(directory)
        database, storage = work / "production.sqlite3", work / "files"
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0)); port = probe.getsockname()[1]
        secret = secrets.token_hex(64)
        verifier = Verifier(secret)
        env = dict(os.environ, DATABASE_PATH=str(database), STORAGE_PATH=str(storage), SECRET_KEY_BASE=secret, HTTP_PORT=str(port),
                   CAMPFIRE_UPLOAD_MAX_BYTES=str(UPLOAD_LIMIT), CAMPFIRE_MEDIA_THREADS="1")
        with (work / "server.log").open("w+") as log:
            server = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log, cwd=root)

            def request(path, data=None, cookie="", method=None, headers=None, kind="application/x-www-form-urlencoded"):
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
                fields = {"Sec-Fetch-Site": "same-origin", "Host": f"127.0.0.1:{port}"}
                if cookie: fields["Cookie"] = cookie
                body = None
                if data is not None:
                    body = urlencode(data) if isinstance(data, (dict, list)) else data
                    fields["Content-Type"] = kind
                fields.update(headers or {})
                connection.request(method or ("GET" if data is None else "POST"), path, body, fields)
                response = connection.getresponse()
                result = response.status, {k.lower(): v for k, v in response.getheaders()}, response.read()
                connection.close()
                return result

            def follow(location, **options):
                parts = urlsplit(location)
                assert parts.netloc in ("", f"127.0.0.1:{port}"), location
                return request(parts.path + (f"?{parts.query}" if parts.query else ""), **options)

            def upload(room, cookie, filename, kind, data, client=None, field="message[attachment]", headers=None):
                fields = [(field, (filename, kind, data))]
                if client: fields.append(("message[client_message_id]", client))
                body, content_type = multipart(fields)
                return request(f"/rooms/{room}/messages", body, cookie, kind=content_type,
                               headers=dict({"Accept": "text/vnd.turbo-stream.html, text/html"}, **(headers or {})))

            def sql(query, *args):
                with sqlite3.connect(database, timeout=10) as db:
                    return db.execute(query, args).fetchall()

            def files():
                return sorted(path.name for path in storage.rglob("*") if path.is_file()) if storage.exists() else []

            def cookie_of(headers):
                return headers["set-cookie"].split(";", 1)[0]

            def stream(room, cookie):
                page = request(f"/rooms/{room}", cookie=cookie)[2].decode()
                tag = next(tag for tag in re.findall(r"<turbo-cable-stream-source[^>]+>", page) if 'channel="RoomMessagesChannel"' in tag)
                signed = html.unescape(re.search(r'signed-stream-name="([^"]+)"', tag)[1])
                return json.dumps({"channel": "RoomMessagesChannel", "signed_stream_name": signed})

            try:
                for _ in range(200):
                    if server.poll() is not None: raise AssertionError("server exited during startup")
                    try:
                        if request("/up")[0] == 200: break
                    except ConnectionRefusedError: time.sleep(.05)
                else: raise AssertionError("server did not start")

                status, headers, _ = request("/first_run", {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test", "user[password]": "admin password"})
                assert status == 303
                admin = cookie_of(headers)
                room = sql("SELECT id FROM rooms ORDER BY id LIMIT 1")[0][0]
                code = sql("SELECT join_code FROM accounts")[0][0]
                status, headers, _ = request(f"/join/{code}", {"user[name]": "Bob Member", "user[email_address]": "bob@example.test", "user[password]": "member password"})
                assert status == 303
                member = cookie_of(headers)
                member_id = sql("SELECT id FROM users WHERE email_address='bob@example.test'")[0][0]
                status, headers, _ = request("/rooms/opens", {"room[name]": "Admins only"}, admin)
                private = int(headers["location"].rsplit("/", 1)[1])
                assert status in (302, 303)
                with sqlite3.connect(database) as db:
                    db.execute("DELETE FROM memberships WHERE room_id=? AND user_id=?", (private, member_id)); db.commit()

                # A wide PNG, posted as the composer's FileUploader posts it, is broadcast to the room.
                listener = WebSocket(port, admin)
                assert listener.subscribe(stream(room, admin)) == "confirm_subscription"
                wide = png(2400, 1000)
                status, headers, body = upload(room, member, "wide image.png", "image/png", wide, "upload-1")
                page = body.decode()
                assert status == 200 and headers["content-type"].startswith("text/vnd.turbo-stream.html"), (status, page[:300])
                assert page.startswith('<turbo-stream action="append" target="') and 'id="message_upload-1"' in page, page[:300]
                [(message, blob)] = sql("SELECT m.id,a.blob_id FROM messages m JOIN active_storage_attachments a ON a.record_type='Message' AND a.name='attachment' AND a.record_id=m.id WHERE m.client_message_id='upload-1'")
                signed = verifier.generate(str(blob), "blob_id")
                path = f"/rails/active_storage/blobs/redirect/{escape_segment(signed)}/wide%20image.png"
                thumb_key = verifier.generate('{"format":"png","resize_to_limit":[1200,800]}', "variation")
                thumb = f"/rails/active_storage/representations/redirect/{escape_segment(signed)}/{escape_segment(thumb_key)}/wide%20image.png"
                expected = (f'<div class="max-inline-size center flex overflow-clip" style="width: 600.0px; aspect-ratio: 2.4;"><a class="flex" data-lightbox-target="image" '
                            f'data-action="lightbox#open" data-lightbox-url-value="{html.escape(path)}?disposition=attachment" href="{html.escape(path)}">'
                            f'<img width="1200.0" height="500.0" class="message__attachment" loading="lazy" src="{html.escape(thumb)}" /></a></div>')
                assert expected in page, page
                assert listener.publication("message_upload-1") == page
                print("PASS: an image posted as the composer posts it renders Rails' attachment markup, and is broadcast to the room")

                # The rows are Active Storage's: the blob, the attachment, no rich text, the filename indexed.
                [row] = sql("SELECT key,filename,content_type,metadata,service_name,byte_size,checksum FROM active_storage_blobs WHERE id=?", blob)
                key = row[0]
                assert re.fullmatch(r"[0-9a-z]{28}", key), key
                assert row[1:] == ("wide image.png", "image/png", '{"identified":true,"width":2400,"height":1000,"analyzed":true}', "local", len(wide),
                                   base64.b64encode(hashlib.md5(wide).digest()).decode()), row
                assert (storage / key[:2] / key[2:4] / key).read_bytes() == wide
                assert sql("SELECT name,record_type,record_id FROM active_storage_attachments WHERE blob_id=?", blob) == [("attachment", "Message", message)]
                assert sql("SELECT count(*) FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?", message) == [(0,)]
                assert sql("SELECT body FROM message_search_index WHERE rowid=?", message) == [("wide image.png",)]
                assert sql("SELECT creator_id FROM messages WHERE id=?", message) == [(member_id,)]
                print("PASS: blob, attachment, message and search rows match Rails' shape")

                # The thumbnail: a tracked variant, made off the HTTP workers, redirected to the disk service.
                status, headers, _ = request(thumb)
                assert status == 302 and headers["cache-control"] == "max-age=300, private", (status, headers)
                status, headers, variant = follow(headers["location"])
                assert status == 200 and headers["content-type"] == "image/png", (status, headers)
                assert dimensions(variant) == (1200, 500), dimensions(variant)
                assert headers["cache-control"] == "max-age=3600, public"
                assert headers["content-disposition"] == "inline; filename=\"wide image.png\"; filename*=UTF-8''wide%20image.png", headers
                [(record, digest)] = sql("SELECT id,variation_digest FROM active_storage_variant_records WHERE blob_id=?", blob)
                assert digest == marshal_digest("png", False, 1200, 800) == "aFrmZ9PxOH5XKtnRmopvClCmS1g=", digest
                [row] = sql("SELECT b.filename,b.content_type,b.metadata,b.byte_size,b.checksum FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='ActiveStorage::VariantRecord' AND a.name='image' AND a.record_id=?", record)
                assert row == ("wide image.png", "image/png", '{"identified":true,"width":1200,"height":500,"analyzed":true}', len(variant),
                               base64.b64encode(hashlib.md5(variant).digest()).decode()), row
                assert request(thumb)[0] == 302 and len(sql("SELECT id FROM active_storage_variant_records")) == 1
                print("PASS: the thumbnail variant is generated once with libvips, recorded as Rails records it, and served at 1200x500")

                # The blob itself, inline or as a download, with ranges.
                status, headers, _ = request(path)
                assert status == 302 and "/rails/active_storage/disk/" in headers["location"]
                status, headers, body = follow(headers["location"])
                assert status == 200 and body == wide and headers["content-type"] == "image/png" and headers["accept-ranges"] == "bytes"
                status, headers, _ = request(path + "?disposition=attachment")
                status, headers, body = follow(headers["location"], headers={"Range": "bytes=0-9"})
                assert status == 206 and body == wide[:10] and headers["content-range"] == f"bytes 0-9/{len(wide)}", (status, headers)
                assert headers["content-disposition"].startswith("attachment; ")
                assert follow(request(path)[1]["location"], method="HEAD")[0] == 200
                print("PASS: blob redirects to signed disk URLs, which serve inline or attachment dispositions and ranges")

                # A turned JPEG with an uppercase extension: analyzed upright, its thumbnail's format is the extension.
                status, _, body = upload(room, admin, "photo.JPG", "image/jpeg", TURNED_JPEG, "upload-2")
                assert status == 200
                [(jpeg_blob, metadata)] = sql("SELECT b.id,b.metadata FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id JOIN messages m ON m.id=a.record_id WHERE m.client_message_id='upload-2'")
                assert metadata == '{"identified":true,"width":20,"height":40,"analyzed":true}', metadata
                assert 'style="width: 10px; aspect-ratio: 0.5;"' in body.decode() and '<img width="20" height="40"' in body.decode(), body
                variation = verifier.generate('{"format":"JPG","resize_to_limit":[1200,800]}', "variation")
                assert escape_segment(variation) in body.decode()
                status, headers, _ = request(f"/rails/active_storage/representations/redirect/{escape_segment(verifier.generate(str(jpeg_blob), 'blob_id'))}/{escape_segment(variation)}/photo.JPG")
                assert status == 302, status
                status, headers, variant = follow(headers["location"])
                assert status == 200 and headers["content-type"] == "image/jpeg" and dimensions(variant) == (20, 40), (headers, dimensions(variant))
                assert sql("SELECT v.variation_digest,b.filename FROM active_storage_variant_records v JOIN active_storage_attachments a ON a.record_type='ActiveStorage::VariantRecord' AND a.record_id=v.id JOIN active_storage_blobs b ON b.id=a.blob_id WHERE v.blob_id=?", jpeg_blob) == [(marshal_digest("JPG", False, 1200, 800), "photo.jpg")]
                print("PASS: EXIF orientation is analyzed and auto-rotated; the thumbnail keeps the extension's format")

                # A file that isn't an image: a download link, no variants.
                text = b"plain notes\n" * 10
                status, _, body = upload(room, member, "notes.txt", "text/plain", text, "upload-3")
                page = body.decode()
                assert status == 200 and '<span>notes.txt</span>' in page and 'data-web-share-files-value="' in page and "Download notes.txt" in page, page
                [(text_blob, kind, metadata)] = sql("SELECT b.id,b.content_type,b.metadata FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id JOIN messages m ON m.id=a.record_id WHERE m.client_message_id='upload-3'")
                assert (kind, metadata) == ("text/plain", '{"identified":true,"analyzed":true}'), (kind, metadata)
                text_path = f"/rails/active_storage/blobs/redirect/{escape_segment(verifier.generate(str(text_blob), 'blob_id'))}/notes.txt"
                status, headers, body = follow(request(text_path)[1]["location"])
                assert status == 200 and body == text and headers["content-disposition"].startswith("attachment; "), headers
                status, _, body = upload(room, member, "page.html", "text/html", b"<!DOCTYPE html><html><body>x</body></html>", "upload-4")
                [(html_blob,)] = sql("SELECT a.blob_id FROM active_storage_attachments a JOIN messages m ON m.id=a.record_id WHERE m.client_message_id='upload-4'")
                status, headers, _ = follow(request(f"/rails/active_storage/blobs/redirect/{escape_segment(verifier.generate(str(html_blob), 'blob_id'))}/page.html")[1]["location"])
                assert headers["content-type"] == "application/octet-stream" and headers["content-disposition"].startswith("attachment; "), headers
                assert sql("SELECT count(*) FROM active_storage_variant_records WHERE blob_id IN (?,?)", text_blob, html_blob) == [(0,)]
                print("PASS: a non-image is stored as text/plain with a download link; HTML is served as a binary download")

                # A bot's attachment, as accounts/bots/_bot's curl line posts it.
                assert request("/account/bots", {"user[name]": "Uploader", "user[webhook_url]": ""}, admin)[0] in (302, 303)
                [(bot, token)] = sql("SELECT id,bot_token FROM users WHERE role=2 AND name='Uploader'")
                body, kind = multipart([("attachment", ("bot.png", "image/png", png(30, 30)))])
                status, headers, _ = request(f"/rooms/{room}/{bot}-{token}/messages", body, kind=kind, headers={"Sec-Fetch-Site": "none"})
                assert status == 201, status
                assert sql("SELECT b.filename,b.metadata FROM messages m JOIN active_storage_attachments a ON a.record_type='Message' AND a.record_id=m.id JOIN active_storage_blobs b ON b.id=a.blob_id WHERE m.creator_id=?", bot) == [("bot.png", '{"identified":true,"width":30,"height":30,"analyzed":true}')]
                # Its thumbnail is made eagerly, after the post; wait for it so that the counts below hold still.
                for _ in range(200):
                    if sql("SELECT count(*) FROM active_storage_variant_records v JOIN active_storage_attachments a ON a.blob_id=v.blob_id JOIN messages m ON m.id=a.record_id AND a.record_type='Message' WHERE m.creator_id=?", bot)[0][0] == 1: break
                    time.sleep(.05)
                else: raise AssertionError("the bot's thumbnail was not made eagerly")
                print("PASS: a bot posts an attachment with curl -F attachment=@file, and its thumbnail is made after the post")

                # Rendering: the room page and the messages page show the attachments as the broadcast did.
                room_page = request(f"/rooms/{room}", cookie=admin)[2].decode()
                assert expected in room_page and "<span>notes.txt</span>" in room_page
                print("PASS: the room page renders the stored attachments")

                # Authorization: members only, same origin, signed ids.
                before = (sql("SELECT count(*) FROM active_storage_blobs"), files())
                # Rails renders room_not_found for a room the user isn't in.
                status, _, page = upload(private, member, "secret.png", "image/png", png(4, 4), "upload-5")
                assert status == 200 and b"This room was deleted." in page
                assert upload(room, member, "cross.png", "image/png", png(4, 4), "upload-6", headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
                assert upload(room, "", "anon.png", "image/png", png(4, 4), "upload-7")[0] == 302
                assert (sql("SELECT count(*) FROM active_storage_blobs"), files()) == before
                tampered = path.replace("--", "--0", 1)
                forged = thumb_key[:-1] + ("1" if thumb_key[-1] == "0" else "0")
                assert request(tampered)[0] == 404 and request(thumb.replace(escape_segment(thumb_key), escape_segment(forged)))[0] == 404
                assert request("/rails/active_storage/disk/" + escape_segment(verifier.generate('{"key":"x"}', "blob_id")) + "/x.png")[0] == 404
                assert request(f"/rails/active_storage/representations/redirect/{escape_segment(verifier.generate(str(text_blob), 'blob_id'))}/{escape_segment(thumb_key)}/notes.txt")[0] == 500
                print("PASS: uploads need a member of the room on the same origin; blob, representation and disk URLs need valid signatures")

                # The body limit: uploads may be as large as the upload limit, everything else 1 MiB.
                big = os.urandom(UPLOAD_LIMIT - 4096)
                status, _, _ = upload(room, member, "random.bin", "application/octet-stream", big, "upload-8")
                assert status == 200, status
                assert sql("SELECT b.byte_size FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id JOIN messages m ON m.id=a.record_id WHERE m.client_message_id='upload-8'") == [(len(big),)]
                try: status = upload(room, member, "too big.bin", "application/octet-stream", os.urandom(UPLOAD_LIMIT + 1), "upload-9")[0]
                except (ConnectionError, http.client.HTTPException): status = 413
                assert status == 413, status
                try: status = request(f"/rooms/{room}/messages", {"message[body]": "x" * (1 << 20), "message[client_message_id]": "huge"}, member)[0]
                except (ConnectionError, http.client.HTTPException): status = 413
                assert status == 413, status
                assert request("/up")[0] == 200
                print("PASS: an upload up to CAMPFIRE_UPLOAD_MAX_BYTES is accepted, past it 413, and other bodies keep the 1 MiB limit")

                # Deleting the message purges its attachment, variants and files.
                keys = [k for (k,) in sql("SELECT key FROM active_storage_blobs WHERE id=? OR id IN (SELECT a.blob_id FROM active_storage_variant_records v JOIN active_storage_attachments a ON a.record_type='ActiveStorage::VariantRecord' AND a.record_id=v.id WHERE v.blob_id=?)", blob, blob)]
                assert len(keys) == 2
                status, _, _ = request(f"/rooms/{room}/messages/{message}", {"_method": "delete"}, member, headers={"Accept": "text/vnd.turbo-stream.html"})
                assert status == 200, status
                assert sql("SELECT count(*) FROM active_storage_blobs WHERE id=?", blob) == [(0,)] and sql("SELECT count(*) FROM active_storage_variant_records WHERE blob_id=?", blob) == [(0,)]
                assert not any(key in files() for key in keys)
                print("PASS: deleting a message purges its blob, variant records and files")

                def wait_for(condition, what, seconds=20):
                    deadline = time.monotonic() + seconds
                    while not condition():
                        assert time.monotonic() < deadline, what
                        time.sleep(.05)

                def attached(client):
                    return sql("SELECT m.id,a.blob_id FROM messages m JOIN active_storage_attachments a ON a.record_type='Message' AND a.name='attachment' AND a.record_id=m.id WHERE m.client_message_id=?", client)[0]

                def preview_image(blob):
                    return sql("SELECT b.id,b.filename,b.content_type,b.metadata,b.key FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='ActiveStorage::Blob' AND a.name='preview_image' AND a.record_id=?", blob)

                def variant_rows(blob):
                    return sql("SELECT v.variation_digest,b.filename,b.content_type,b.key FROM active_storage_variant_records v JOIN active_storage_attachments a ON a.record_type='ActiveStorage::VariantRecord' AND a.record_id=v.id JOIN active_storage_blobs b ON b.id=a.blob_id WHERE v.blob_id=? ORDER BY v.id", blob)

                def metadata_of(blob):
                    return sql("SELECT metadata FROM active_storage_blobs WHERE id=?", blob)[0][0]

                # A video is analyzed with ffprobe (its frames are 64x48 with a 4:3 sample aspect ratio, so 16:9 on
                # screen) and previewed with ffmpeg, then the preview's {format: :webp} variant is made, before the post
                # is answered and broadcast, as create_with_attachment! runs Message#process_attachment first. Its
                # markup is Rails' sized <video> with the poster preview(format: :webp, resize_to_limit:).
                clip = avi(64, 48, [jpeg(64, 48, 40 * i, aspect=(4, 3)) for i in range(5)])
                status, headers, body = upload(room, member, "clip.avi", "video/x-msvideo", clip, "video-1")
                page = body.decode()
                assert status == 200, (status, page[:300])
                video_message, video_blob = attached("video-1")
                video_signed = escape_segment(verifier.generate(str(video_blob), "blob_id"))
                video_path = f"/rails/active_storage/blobs/redirect/{video_signed}/clip.avi"
                poster_key = verifier.generate('{"format":"webp","resize_to_limit":[1200,800]}', "variation")
                poster = f"/rails/active_storage/representations/redirect/{video_signed}/{escape_segment(poster_key)}/clip.avi"
                video_tag = (f'<video src="{html.escape(video_path)}" poster="{html.escape(poster)}" controls="controls" preload="none" '
                             'width="100%" height="100%" class="message__attachment"></video>')
                sized = f'<div class="max-inline-size center flex overflow-clip" style="width: 32.0px; aspect-ratio: 1.7777777777777777;">{video_tag}</div>'
                assert sized in page, page
                assert listener.publication("message_video-1") == page
                assert metadata_of(video_blob) == '{"identified":true,"width":64.0,"height":36.0,"duration":0.5,"display_aspect_ratio":[16,9],"audio":false,"video":true,"analyzed":true}'
                assert sql("SELECT updated_at > created_at FROM messages WHERE id=?", video_message) == [(1,)]
                [(preview_id, preview_name, preview_type, preview_metadata, preview_key)] = preview_image(video_blob)
                assert (preview_name, preview_type, preview_metadata) == ("clip.jpg", "image/jpeg", '{"identified":true,"width":64,"height":48,"analyzed":true}')
                assert dimensions((storage / preview_key[:2] / preview_key[2:4] / preview_key).read_bytes()) == (64, 48)
                assert [row[:3] for row in variant_rows(preview_id)] == [(marshal_digest("webp", True), "clip.webp", "image/webp")]
                assert sql("SELECT count(*) FROM active_storage_variant_records WHERE blob_id=?", video_blob) == [(0,)]
                room_page = request(f"/rooms/{room}", cookie=admin)[2].decode()
                assert sized in room_page
                print("PASS: a video is analyzed with ffprobe and previewed with ffmpeg before its post is answered and broadcast with Rails' sized <video>")

                # The poster: a variant of the preview image; a bare variation is the preview image itself.
                status, headers, _ = request(poster)
                assert status == 302 and headers["cache-control"] == "max-age=300, private", (status, headers)
                status, headers, image = follow(headers["location"])
                assert status == 200 and headers["content-type"] == "image/webp" and dimensions(image) == (64, 48), (status, headers)
                assert headers["content-disposition"] == "inline; filename=\"clip.webp\"; filename*=UTF-8''clip.webp", headers
                assert [row[:3] for row in variant_rows(preview_id)] == [(marshal_digest("webp", True), "clip.webp", "image/webp"),
                                                                          (marshal_digest("webp", False, 1200, 800), "clip.webp", "image/webp")]
                bare = verifier.generate("{}", "variation")
                status, headers, _ = request(f"/rails/active_storage/representations/redirect/{video_signed}/{escape_segment(bare)}/clip.avi")
                assert status == 302, status
                status, headers, image = follow(headers["location"])
                assert status == 200 and headers["content-type"] == "image/jpeg" and dimensions(image) == (64, 48), (status, headers)
                assert len(variant_rows(preview_id)) == 2 and len(preview_image(video_blob)) == 1
                status, headers, _ = request(video_path)
                status, headers, body = follow(headers["location"])
                assert status == 200 and body == clip and headers["content-type"] == "video/x-msvideo", headers
                print("PASS: the poster is the preview image's WebP variant, made on request; the video itself streams from its blob")

                # A bot's video, through the bot API, is processed before its 201 too.
                body, kind = multipart([("attachment", ("bot clip.avi", "video/x-msvideo", avi(48, 64, [jpeg(48, 64, 200)])))])
                status, headers, _ = request(f"/rooms/{room}/{bot}-{token}/messages", body, kind=kind, headers={"Sec-Fetch-Site": "none"})
                assert status == 201 and re.search(r"/messages/\d+$", headers["location"]), (status, headers)
                bot_clip = sql("SELECT a.blob_id FROM active_storage_attachments a WHERE a.record_type='Message' AND a.name='attachment' AND a.record_id=?",
                               int(headers["location"].rsplit("/", 1)[1]))[0][0]
                assert metadata_of(bot_clip) == '{"identified":true,"width":48.0,"height":64.0,"duration":0.1,"audio":false,"video":true,"analyzed":true}', metadata_of(bot_clip)
                assert len(preview_image(bot_clip)) == 1 and len(variant_rows(preview_image(bot_clip)[0][0])) == 1
                print("PASS: a bot's video is processed before its post is answered 201")

                # A video that isn't a message's (an avatar) has no preview until one is requested, which waits for a
                # media thread to make it; it is analyzed after the upload, as AnalyzeJob does.
                admin_id = sql("SELECT id FROM users WHERE email_address='ada@example.test'")[0][0]
                body, kind = multipart([("_method", "patch"), ("user[avatar]", ("me.avi", "video/x-msvideo", avi(48, 64, [jpeg(48, 64, 120)])))])
                assert request("/users/me/profile", body, admin, kind=kind)[0] in (302, 303)
                [(avatar_video,)] = sql("SELECT blob_id FROM active_storage_attachments WHERE record_type='User' AND name='avatar' AND record_id=?", admin_id)
                status, headers, _ = request(f"/rails/active_storage/representations/redirect/{escape_segment(verifier.generate(str(avatar_video), 'blob_id'))}/{escape_segment(poster_key)}/me.avi")
                assert status == 302, status
                status, headers, image = follow(headers["location"])
                assert status == 200 and headers["content-type"] == "image/webp" and dimensions(image) == (48, 64), (status, headers)
                wait_for(lambda: metadata_of(avatar_video) == '{"identified":true,"width":48.0,"height":64.0,"duration":0.1,"audio":false,"video":true,"analyzed":true}',
                         f"the avatar video was not analyzed: {metadata_of(avatar_video)}")
                assert request(f"/users/{admin_id}/avatar", {"_method": "delete"}, admin)[0] == 302
                assert sql("SELECT count(*) FROM active_storage_blobs WHERE id=?", avatar_video) == [(0,)]
                print("PASS: a poster requested before the preview exists waits for it; an avatar's video is analyzed after its upload")

                # A file ffprobe can't read is analyzed as Rails' analyzer reads ffprobe's empty answer; its preview
                # can't be drawn, so the post answers 500 as Rails' PreviewError does, before any broadcast, and so does
                # its poster. The message stays, as in Rails.
                status, _, body = upload(room, member, "broken.mp4", "video/mp4", b"\x00\x00\x00\x18ftypmp42" + bytes(range(256)) * 8, "video-3")
                assert status == 500, (status, body[:300])
                broken_message, broken_blob = attached("video-3")
                assert sql("SELECT content_type FROM active_storage_blobs WHERE id=?", broken_blob) == [("video/mp4",)]
                assert metadata_of(broken_blob) == '{"identified":true,"audio":false,"video":false,"analyzed":true}', metadata_of(broken_blob)
                assert request(f"/rails/active_storage/representations/redirect/{escape_segment(verifier.generate(str(broken_blob), 'blob_id'))}/{escape_segment(poster_key)}/broken.mp4")[0] == 500
                assert preview_image(broken_blob) == []
                print("PASS: a video ffprobe can't read is analyzed as Rails reads ffprobe's empty output, and its post and poster answer 500")

                # Audio: a download link, analyzed with ffprobe as AudioAnalyzer reads it before the answer, no preview.
                status, _, body = upload(room, member, "tone.wav", "audio/x-wav", wav(), "audio-1")
                page = body.decode()
                assert status == 200 and "<span>tone.wav</span>" in page and "<video" not in page, page
                tone_message, tone_blob = attached("audio-1")
                assert metadata_of(tone_blob) == '{"identified":true,"duration":0.25,"bit_rate":128000,"sample_rate":8000,"analyzed":true}', metadata_of(tone_blob)
                assert preview_image(tone_blob) == [] and variant_rows(tone_blob) == []
                print("PASS: an audio file is a download link, analyzed with ffprobe before its post is answered")

                # Deleting the video's message purges the video, its preview image, the preview's variants and files.
                video_keys = [k for (k,) in sql("SELECT key FROM active_storage_blobs WHERE id IN (?,?)", video_blob, preview_id)] + [row[3] for row in variant_rows(preview_id)]
                assert len(video_keys) == 4 and all(key in files() for key in video_keys)
                status, _, _ = request(f"/rooms/{room}/messages/{video_message}", {"_method": "delete"}, member, headers={"Accept": "text/vnd.turbo-stream.html"})
                assert status == 200, status
                assert sql("SELECT count(*) FROM active_storage_blobs WHERE id IN (?,?)", video_blob, preview_id) == [(0,)]
                assert sql("SELECT count(*) FROM active_storage_attachments WHERE record_type='ActiveStorage::Blob' AND record_id=?", video_blob) == [(0,)]
                assert sql("SELECT count(*) FROM active_storage_variant_records WHERE blob_id=?", preview_id) == [(0,)]
                assert not any(key in files() for key in video_keys)
                print("PASS: deleting a video's message purges its blob, preview image, the preview's variants and their files")

                # Avatars: uploaded with the profile form, their :square WebP variant served, replaced and destroyed.
                avatar_url = re.search(r'src="(/users/[^"]+/avatar)"', request("/users/me/profile", cookie=member)[2].decode())[1]
                status, headers, initials = request(avatar_url, cookie=member)
                assert status == 200 and headers["content-type"] == "image/svg+xml", (avatar_url, status, headers, initials[:200])
                body, kind = multipart([("_method", "patch"), ("user[avatar]", ("me.png", "image/png", png(1000, 800)))])
                status, headers, _ = request("/users/me/profile", body, member, kind=kind)
                assert status in (302, 303) and headers["location"] == "/users/me/profile", (status, headers)
                [(avatar_blob, filename, metadata)] = sql("SELECT b.id,b.filename,b.metadata FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='User' AND a.name='avatar' AND a.record_id=?", member_id)
                assert (filename, metadata) == ("me.png", '{"identified":true,"width":1000,"height":800,"analyzed":true}')
                status, headers, image = request(avatar_url, cookie=member)
                assert status == 200 and headers["content-type"] == "image/webp" and dimensions(image) == (512, 410), (status, headers, dimensions(image) if status == 200 else image)
                assert request(avatar_url, cookie=member, headers={"If-None-Match": headers["etag"]})[0] == 304
                [(digest, variant_name, variant_type)] = sql("SELECT v.variation_digest,b.filename,b.content_type FROM active_storage_variant_records v JOIN active_storage_attachments a ON a.record_type='ActiveStorage::VariantRecord' AND a.record_id=v.id JOIN active_storage_blobs b ON b.id=a.blob_id WHERE v.blob_id=?", avatar_blob)
                assert (digest, variant_name, variant_type) == ("6gwfjNKv9eUy9jNUtEZvQFLU0hQ=", "me.webp", "image/webp")
                first_keys = [k for (k,) in sql("SELECT key FROM active_storage_blobs")]
                body, kind = multipart([("_method", "patch"), ("user[avatar]", ("again.jpg", "image/jpeg", TURNED_JPEG))])
                assert request("/users/me/profile", body, member, kind=kind)[0] in (302, 303)
                assert sql("SELECT count(*) FROM active_storage_blobs WHERE id=?", avatar_blob) == [(0,)]
                status, headers, image = request(avatar_url, cookie=member)
                assert status == 200 and headers["content-type"] == "image/webp" and dimensions(image) == (20, 40), dimensions(image)
                assert "Delete avatar" in request("/users/me/profile", cookie=member)[2].decode()
                assert request(f"/users/{member_id}/avatar", {"_method": "delete"}, member, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
                status, headers, _ = request(f"/users/{member_id}/avatar", {"_method": "delete"}, member)
                assert status == 302 and headers["location"] == "/users/me/profile"
                assert sql("SELECT count(*) FROM active_storage_attachments WHERE record_type='User'") == [(0,)]
                status, headers, body = request(avatar_url, cookie=member)
                assert status == 200 and headers["content-type"] == "image/svg+xml" and body == initials
                assert not set(first_keys) & {name for name in files() if not sql("SELECT 1 FROM active_storage_blobs WHERE key=?", name)}
                assert files() == sorted(k for (k,) in sql("SELECT key FROM active_storage_blobs"))
                print("PASS: avatar upload, its 512px WebP variant, replacement and destroy, with blobs and files purged")

                # The account logo's :large and :small PNG variants.
                body, kind = multipart([("_method", "patch"), ("account[logo]", ("logo.png", "image/png", png(900, 600, 200)))])
                assert request("/account", body, member, kind=kind)[0] == 403
                assert request("/account", body, admin, kind=kind)[0] == 302
                status, headers, large = request("/account/logo")
                assert status == 200 and headers["content-type"] == "image/png" and dimensions(large) == (512, 341), dimensions(large)
                status, headers, small = request("/account/logo?size=small")
                assert status == 200 and dimensions(small) == (192, 128), dimensions(small)
                digests = sorted(d for (d,) in sql("SELECT variation_digest FROM active_storage_variant_records v JOIN active_storage_attachments a ON a.blob_id=v.blob_id WHERE a.record_type='Account'"))
                assert digests == sorted([marshal_digest("png", True, 512, 512), marshal_digest("png", True, 192, 192)]), digests
                print("PASS: the account logo's 512 and 192 PNG variants are generated and recorded")

                # Deleting a room purges its messages' attachments, their variants and files (dependent: :destroy).
                assert upload(private, admin, "doomed.png", "image/png", png(1600, 900), "doomed-1")[0] == 200
                assert upload(private, admin, "doomed.txt", "text/plain", b"gone soon", "doomed-2")[0] == 200
                assert upload(private, admin, "doomed.avi", "video/x-msvideo", avi(32, 32, [jpeg(32, 32)]), "doomed-3")[0] == 200
                blobs = [b for (b,) in sql("SELECT a.blob_id FROM messages m JOIN active_storage_attachments a ON a.record_type='Message' AND a.name='attachment' AND a.record_id=m.id WHERE m.room_id=? ORDER BY m.id", private)]
                assert len(blobs) == 3
                wait_for(lambda: sql("SELECT count(*) FROM active_storage_variant_records WHERE blob_id IN (?,?)", *blobs[:2])[0][0], "no thumbnail", 15)
                wait_for(lambda: preview_image(blobs[2]) and variant_rows(preview_image(blobs[2])[0][0]), "no preview", 15)
                blobs.append(preview_image(blobs[2])[0][0])
                held = ",".join(map(str, blobs))
                keys = [k for (k,) in sql(f"SELECT key FROM active_storage_blobs WHERE id IN ({held}) OR id IN (SELECT a.blob_id FROM active_storage_variant_records v JOIN active_storage_attachments a ON a.record_type='ActiveStorage::VariantRecord' AND a.record_id=v.id WHERE v.blob_id IN ({held}))")]
                assert len(keys) == 6 and all(key in files() for key in keys)
                assert request(f"/rooms/{private}", {"_method": "delete"}, admin)[0] == 302
                assert sql(f"SELECT count(*) FROM active_storage_blobs WHERE id IN ({held})") == [(0,)]
                assert sql(f"SELECT count(*) FROM active_storage_variant_records WHERE blob_id IN ({held})") == [(0,)]
                assert sql("SELECT count(*) FROM active_storage_attachments WHERE record_type='Message' AND record_id NOT IN (SELECT id FROM messages)") == [(0,)]
                assert sql("SELECT count(*) FROM active_storage_attachments WHERE record_type='ActiveStorage::Blob' AND record_id NOT IN (SELECT id FROM active_storage_blobs)") == [(0,)]
                assert not any(key in files() for key in keys)
                print("PASS: deleting a room purges its messages' blobs, variant records, a video's preview image and its variants, and their files")

                assert files() == sorted(k for (k,) in sql("SELECT key FROM active_storage_blobs")), "blob files without rows, or rows without files"
                assert server.poll() is None
            except BaseException:
                log.seek(0); sys.stderr.write(log.read()[-4000:])
                raise
            finally:
                server.terminate()
                try: server.wait(timeout=10)
                except subprocess.TimeoutExpired: server.kill()


if __name__ == "__main__":
    main()
