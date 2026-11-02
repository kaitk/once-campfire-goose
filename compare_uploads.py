#!/usr/bin/env python3
"""Differential upload checks against the Rails reference image: the same uploads, with the same
secret, to Rails and to this server, compared by their turbo streams, Active Storage rows and
variant sizes. Needs Docker and the reference image (once-campfire-verification's bin/seed builds it):

    python3 compare_uploads.py once-campfire-goose:app [--reference once-campfire-verification:reference-90b3300]
"""
import argparse
import http.client
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

from test_uploads import TURNED_JPEG, dimensions, multipart, png

ENV = {"RAILS_ENV": "production", "DISABLE_SSL": "true", "SKIP_TELEMETRY": "true", "APP_VERSION": "parity", "GIT_REVISION": "parity",
       "WEB_CONCURRENCY": "1", "RAILS_MAX_THREADS": "5", "JOB_CONCURRENCY": "1", "RAILS_LOG_LEVEL": "warn"}


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
        self.cookies, self.csrf = {}, ""
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
            # Rails' forgery protection, from the last page's csrf-token; this server ignores it.
            if self.csrf: fields["X-CSRF-Token"] = self.csrf
        fields.update(headers or {})
        connection.request(method or ("GET" if data is None else "POST"), path, data, fields)
        response = connection.getresponse()
        for cookie in response.msg.get_all("Set-Cookie") or []:
            name, _, value = cookie.split(";", 1)[0].partition("=")
            self.cookies[name] = value
        result = response.status, {k.lower(): v for k, v in response.getheaders()}, response.read()
        token = re.search(rb'<meta name="csrf-token" content="([^"]*)"', result[2])
        if token: self.csrf = token[1].decode()
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
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--reference", default="once-campfire-verification:reference-90b3300")
    args = parser.parse_args()
    secret = secrets.token_hex(64)
    wide, avatar, logo = png(2400, 1000), png(1000, 800), png(900, 600, 200)
    uploads = [("wide image.png", "image/png", wide), ("photo.JPG", "image/jpeg", TURNED_JPEG), ("notes.txt", "text/plain", b"plain notes\n")]
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
                results[label] = {"streams": streams, "variants": variants, "blobs": blobs, "attachments": attachments, "records": records, "search": search}
            finally:
                logs = subprocess.run(["docker", "logs", app.name], capture_output=True, text=True)
                (Path(directory) / f"{label}.log").write_text(logs.stdout + logs.stderr)
                app.close()
        rails, goose = results["rails"], results["goose"]
        failures = 0
        for index, (a, b) in enumerate(zip(rails["streams"], goose["streams"])):
            if a == b: print(f"PASS: upload {index} turbo stream matches Rails byte for byte")
            else:
                at = next(i for i, (x, y) in enumerate(zip(a + "\0", b + "\0")) if x != y)
                failures += 1; print(f"FAIL: upload {index} turbo stream differs at {at}\n  rails: ...{a[max(at - 300, 0):at + 300]}\n  goose: ...{b[max(at - 300, 0):at + 300]}")
        for key in ("variants", "records", "search", "attachments"):
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
