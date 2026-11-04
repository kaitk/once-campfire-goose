#!/usr/bin/env python3
"""Differential upload checks against the Rails reference image: the same uploads, with the same
secret, to Rails and to this server, compared by their turbo streams, Active Storage rows and
variant sizes, and a video's markup, analysis, preview image and poster. Needs Docker and the
reference image (once-campfire-verification's bin/seed builds it):

    python3 compare_uploads.py once-campfire-goose:app [--reference once-campfire-verification:reference-a05ee90]
"""
import argparse
import html
import http.client
import itertools
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
import uuid

from compare_rendering import CanonicalHTML
from test_uploads import TURNED_JPEG, avi, dimensions, jpeg, multipart, png, png_header, wav

ENV = {"RAILS_ENV": "production", "DISABLE_SSL": "true", "SKIP_TELEMETRY": "true", "APP_VERSION": "parity", "GIT_REVISION": "parity",
       "WEB_CONCURRENCY": "1", "RAILS_MAX_THREADS": "5", "JOB_CONCURRENCY": "1", "RAILS_LOG_LEVEL": "warn"}

VIDEO_MARKUP = re.compile(r'<div class="max-inline-size[^"]*"(?: style="[^"]*")?><video [^>]*></video></div>')


class App:
    def __init__(self, image, secret, work):
        self.image, self.work = image, work
        self.name = "campfire-uploads-" + uuid.uuid4().hex[:10]
        for folder in ("db", "files", "logs"):
            (work / folder).mkdir(parents=True); os.chmod(work / folder, 0o777)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0)); self.port = probe.getsockname()[1]
        env = work / "env"
        env.write_text("".join(f"{k}={v}\n" for k, v in dict(ENV, SECRET_KEY_BASE=secret, HTTP_PORT="3000", TARGET_PORT="3001").items()))
        command = ["docker", "run", "-d", "--name", self.name, "-p", f"127.0.0.1:{self.port}:3000", "--env-file", str(env)]
        for folder in ("db", "files", "logs"): command += ["-v", f"{work / folder}:/rails/storage/{folder}"]
        subprocess.run(command + [image], check=True, stdout=subprocess.DEVNULL)
        self.cookies = {}
        for _ in range(600):
            try:
                if self.request("/up")[0] == 200: break
            except (OSError, http.client.HTTPException): pass
            time.sleep(.1)
        else: raise RuntimeError(f"{image} did not start")

    def request(self, path, data=None, kind="application/x-www-form-urlencoded", method=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        fields = {"Sec-Fetch-Site": "same-origin", "Host": f"127.0.0.1:{self.port}"}
        if self.cookies: fields["Cookie"] = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
        if data is not None:
            fields["Content-Type"] = kind
        fields.update(headers or {})
        connection.request(method or ("GET" if data is None else "POST"), path, data, fields)
        response = connection.getresponse()
        for cookie in response.msg.get_all("Set-Cookie") or []:
            name, _, value = cookie.split(";", 1)[0].partition("=")
            self.cookies[name] = value
        result = response.status, {k.lower(): v for k, v in response.getheaders()}, response.read()
        connection.close()
        return result

    def follow(self, location):
        path = re.sub(r"^https?://[^/]+", "", location)
        return self.request(path)

    def sql(self, query, *args):
        with sqlite3.connect(self.work / "db/production.sqlite3", timeout=10) as db:
            return db.execute(query, args).fetchall()

    def close(self):
        subprocess.run(["docker", "rm", "-f", self.name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def normalize(text):
    text = re.sub(r'((?:data-message-timestamp|data-message-updated-at|data-sort-value)="-?)\d+', r"\1TIME", text)
    text = re.sub(r'(datetime=")[^"]+', r"\1TIME", text)
    text = re.sub(r">\d{1,2}:\d{2}[ap]m<", ">TIME<", text)
    text = re.sub(r"/avatar\?v=\d+", "/avatar?v=VERSION", text)
    # The copy-link button's absolute URL names this run's port.
    text = re.sub(r'(data-copy-to-clipboard-content-value="https?://)127\.0\.0\.1:\d+', r"\1SERVER", text)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--reference", default="once-campfire-verification:reference-a05ee90")
    args = parser.parse_args()
    secret = secrets.token_hex(64)
    wide, avatar, logo = png(2400, 1000), png(1000, 800), png(900, 600, 200)
    # A 64x48 MJPEG AVI whose 4:3 sample aspect ratio makes it 16:9, its frames encoded by the image's own ffmpeg.
    encoder = ("docker", "run", "--rm", "-i", "--entrypoint", "ffmpeg", args.image)
    clip = avi(64, 48, [jpeg(64, 48, 40 * i, aspect=(4, 3), ffmpeg=encoder) for i in range(5)])
    uploads = [("wide image.png", "image/png", wide), ("photo.JPG", "image/jpeg", TURNED_JPEG), ("notes.txt", "text/plain", b"plain notes\n"),
               ("tone.wav", "audio/x-wav", wav()), ("clip.avi", "video/x-msvideo", clip),
               # Past THUMBNAIL_MAX_PIXELS (its header alone), and an image libvips can't decode: posted without a thumbnail.
               ("huge.png", "image/png", png_header(20000, 20000)), ("corrupt.png", "image/png", png_header(40, 30))]
    results = {}
    with tempfile.TemporaryDirectory(prefix="campfire-compare-uploads-") as directory:
        for label, image in (("rails", args.reference), ("goose", args.image)):
            app = App(image, secret, Path(directory) / label)
            try:
                app.request("/first_run")
                status, headers, _ = app.request("/first_run", "user%5Bname%5D=Ada+Admin&user%5Bemail_address%5D=ada%40example.test&user%5Bpassword%5D=admin+password+123")
                assert status in (302, 303), (label, status)
                room = app.sql("SELECT id FROM rooms ORDER BY id LIMIT 1")[0][0]
                streams, variants = [], []
                for index, (filename, kind, data) in enumerate(uploads):
                    body, content_type = multipart([("message[client_message_id]", f"compare-{index}"), ("message[attachment]", (filename, kind, data))])
                    status, _, page = app.request(f"/rooms/{room}/messages", body, content_type, headers={"Accept": "text/vnd.turbo-stream.html, text/html"})
                    assert status == 200, (label, filename, status, page[:300])
                    page = page.decode()
                    streams.append(normalize(page))
                    thumb = re.search(r'class="message__attachment" loading="lazy" src="([^"]+)"', page)
                    if thumb:
                        status, headers, _ = app.request(thumb[1].replace("&amp;", "&"))
                        assert status == 302, (label, status)
                        status, headers, variant = app.follow(headers["location"])
                        variants.append((headers["content-type"], dimensions(variant)))
                    poster = re.search(r'<video [^>]*poster="([^"]+)"', page)
                    if poster:
                        status, headers, _ = app.request(html.unescape(poster[1]))
                        assert status == 302, (label, status)
                        status, headers, frame = app.follow(headers["location"])
                        variants.append((headers["content-type"], dimensions(frame)))
                videos = VIDEO_MARKUP.findall(app.request(f"/rooms/{room}")[2].decode())
                # A video ffmpeg can't preview: the message is created and answered 200 all the same, with no poster.
                body, content_type = multipart([("message[client_message_id]", "compare-broken"),
                                                ("message[attachment]", ("broken.mp4", "video/mp4", b"\x00\x00\x00\x18ftypmp42" + bytes(range(256)) * 8))])
                broken, _, page = app.request(f"/rooms/{room}/messages", body, content_type, headers={"Accept": "text/vnd.turbo-stream.html, text/html"})
                if broken == 200: streams.append(normalize(page.decode()))
                body, content_type = multipart([("_method", "patch"), ("user[avatar]", ("me.png", "image/png", avatar))])
                assert app.request("/users/me/profile", body, content_type)[0] in (302, 303)
                profile = app.request("/users/me/profile")[2].decode()
                avatar_url = re.search(r'src="(/users/[^"]+/avatar)', profile)[1]
                status, headers, image_bytes = app.request(avatar_url)
                variants.append((headers["content-type"], dimensions(image_bytes)))
                body, content_type = multipart([("_method", "patch"), ("account[logo]", ("logo.png", "image/png", logo))])
                assert app.request("/account", body, content_type)[0] in (302, 303)
                for size in ("", "?size=small"):
                    status, headers, image_bytes = app.request("/account/logo" + size)
                    variants.append((headers["content-type"], dimensions(image_bytes)))
                time.sleep(3)  # Rails' AnalyzeJob for the avatar and the logo
                # The database is read once the container has stopped: a bind mount shares no WAL index with it.
                subprocess.run(["docker", "stop", "-t", "20", app.name], stdout=subprocess.DEVNULL)
                blobs = app.sql("SELECT id,filename,content_type,metadata,service_name,byte_size,checksum FROM active_storage_blobs ORDER BY id")
                attachments = app.sql("SELECT name,record_type,record_id,blob_id FROM active_storage_attachments ORDER BY id")
                records = app.sql("SELECT blob_id,variation_digest FROM active_storage_variant_records ORDER BY id")
                search = app.sql("SELECT rowid,body FROM message_search_index ORDER BY rowid")
                results[label] = {"streams": streams, "variants": variants, "blobs": blobs, "attachments": attachments, "records": records, "search": search,
                                  "videos": videos, "broken": broken}
            finally:
                logs = subprocess.run(["docker", "logs", app.name], capture_output=True, text=True)
                (Path(directory) / f"{label}.log").write_text(logs.stdout + logs.stderr)
                app.close()
        rails, goose = results["rails"], results["goose"]
        failures = 0
        # The last stream is the broken video's, when it was answered 200; one side lacking it is a difference.
        for index, (a, b) in enumerate(itertools.zip_longest(rails["streams"], goose["streams"], fillvalue="")):
            # As compare_rendering.py compares pages: layout whitespace and attribute order don't count.
            x, y = CanonicalHTML(a, "http://unused.invalid").events, CanonicalHTML(b, "http://unused.invalid").events
            if x == y: print(f"PASS: upload {index} turbo stream matches Rails ({len(x)} HTML events; byte-identical: {a == b})")
            else:
                at = next(i for i, (p, q) in enumerate(zip(x + [None], y + [None])) if p != q)
                failures += 1; print(f"FAIL: upload {index} turbo stream differs at event {at}\n  rails: {x[at:at + 3]}\n  goose: {y[at:at + 3]}")
        for key in ("variants", "records", "search", "attachments", "videos", "broken"):
            if rails[key] == goose[key]: print(f"PASS: {key} match: {rails[key]}")
            else: failures += 1; print(f"FAIL: {key}\n  rails: {rails[key]}\n  goose: {goose[key]}")
        # Blob rows: the same files give the same rows; a variant's bytes depend on libvips' build.
        if [r[1:5] for r in rails["blobs"]] == [r[1:5] for r in goose["blobs"]]: print("PASS: blob rows (filename, content type, metadata, service) match")
        else:
            failures += 1
            for a, b in zip(rails["blobs"], goose["blobs"]):
                print(("  " if a[1:5] == b[1:5] else "! ") + f"rails {a[:5]}\n    goose {b[:5]}")
        assert failures == 0, f"{failures} differences"


if __name__ == "__main__":
    main()
