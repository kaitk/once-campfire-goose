#!/usr/bin/env python3
"""Built-in HTTPS, as Thruster gives the Rails image: TLS_DOMAIN's certificates from an ACME CA
through TLS-ALPN-01, h2 and HTTP/1.1 by ALPN, the HTTP port's redirect, HSTS and secure cookies,
renewal without a restart, and Thruster's certificate cache, against a CA faked here (no network:
the suite runs in `docker build`). compare_ui_tls.sh runs the same against Pebble."""

import base64
import hashlib
import hmac
import http.client
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlencode

DOMAIN = "chat.test"
EAB_KID = "kid-1"
EAB_KEY = base64.urlsafe_b64encode(bytes(range(32))).rstrip(b"=").decode()
ACME_IDENTIFIER = bytes.fromhex("06082b0601050507011f")  # the OID 1.3.6.1.5.5.7.1.31, acmeIdentifier


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def openssl(*args, data=None):
    return subprocess.run(["openssl", *args], input=data, capture_output=True, check=True).stdout


class FakeCA:
    """An ACME CA (RFC 8555) as goose-acme's flow uses one: it checks EAB and validates
    TLS-ALPN-01 (RFC 8737) by connecting to the server, but not JWS signatures. Its certificates
    last 90 days, or, while `short` is set, 30 seconds from 10 seconds ago."""

    def __init__(self, work, https_port):
        self.work, self.https_port, self.short = work, https_port, False
        self.nonce, self.orders, self.authz, self.issued, self.validations = 0, {}, {}, [], []
        self.thumbprint, self.lock = None, threading.Lock()
        work.mkdir()
        (work / "newcerts").mkdir()
        (work / "index.txt").write_text("")
        (work / "serial").write_text("1000\n")
        openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(work / "ca.key"))
        openssl("req", "-x509", "-new", "-key", str(work / "ca.key"), "-subj", "/CN=Test ACME CA", "-days", "3650",
                "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                "-out", str(work / "ca.pem"))
        openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(work / "dir.key"))
        csr = openssl("req", "-new", "-key", str(work / "dir.key"), "-subj", "/CN=127.0.0.1")
        (work / "ca.cnf").write_text(f"""[ca]
default_ca = test
[test]
dir = {work}
database = {work}/index.txt
new_certs_dir = {work}/newcerts
serial = {work}/serial
certificate = {work}/ca.pem
private_key = {work}/ca.key
default_md = sha256
policy = anything
copy_extensions = copy
unique_subject = no
[anything]
commonName = optional
[directory]
subjectAltName = IP:127.0.0.1
""")
        (work / "dir.csr").write_bytes(csr)
        openssl("ca", "-batch", "-config", str(work / "ca.cnf"), "-extensions", "directory", "-days", "30", "-notext",
                "-in", str(work / "dir.csr"), "-out", str(work / "dir.pem"))
        self.port = free_port()
        self.url = f"https://127.0.0.1:{self.port}"
        ca = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def log_message(self, *args): pass
            def do_GET(self): ca.answer(self)
            def do_HEAD(self): ca.answer(self)
            def do_POST(self): ca.answer(self)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(work / "dir.pem", work / "dir.key")
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def reply(self, handler, status, body=b"", kind="application/json", location=None):
        with self.lock:
            self.nonce += 1
            nonce = f"n{self.nonce}"
        handler.send_response(status)
        handler.send_header("Replay-Nonce", nonce)
        if location: handler.send_header("Location", location)
        handler.send_header("Content-Type", kind)
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        if handler.command != "HEAD": handler.wfile.write(body)

    def problem(self, handler, status, kind, detail):
        self.reply(handler, status, json.dumps({"type": f"urn:ietf:params:acme:error:{kind}", "detail": detail}).encode(),
                   "application/problem+json")

    def answer(self, handler):
        path = handler.path
        if handler.command == "GET" and path == "/dir":
            return self.reply(handler, 200, json.dumps({"newNonce": f"{self.url}/nonce", "newAccount": f"{self.url}/account",
                                                        "newOrder": f"{self.url}/order"}).encode())
        if handler.command == "HEAD" and path == "/nonce":
            return self.reply(handler, 200)
        body = json.loads(handler.rfile.read(int(handler.headers["Content-Length"])))
        header = json.loads(unb64(body["protected"]))
        payload = json.loads(unb64(body["payload"])) if body["payload"] else None
        if path == "/account":
            jwk = header["jwk"]
            binding = payload.get("externalAccountBinding")
            if not binding: return self.problem(handler, 400, "externalAccountRequired", "no binding")
            bound = json.loads(unb64(binding["protected"]))
            mac = hmac.new(unb64(EAB_KEY), f"{binding['protected']}.{binding['payload']}".encode(), hashlib.sha256).digest()
            if bound != {"alg": "HS256", "kid": EAB_KID, "url": f"{self.url}/account"} or json.loads(unb64(binding["payload"])) != jwk \
                    or unb64(binding["signature"]) != mac:
                return self.problem(handler, 400, "unauthorized", "a bad binding")
            canonical = json.dumps({k: jwk[k] for k in ("crv", "kty", "x", "y")}, separators=(",", ":"), sort_keys=True)
            self.thumbprint = b64(hashlib.sha256(canonical.encode()).digest())
            return self.reply(handler, 201, b'{"status":"valid"}', location=f"{self.url}/acct/1")
        if path == "/order":
            names = [i["value"] for i in payload["identifiers"]]
            order = str(len(self.orders) + 1)
            self.orders[order] = {"names": names, "cert": None}
            for name in names: self.authz[name] = {"status": "pending", "token": secrets.token_urlsafe(16)}
            return self.reply(handler, 201, self.order_body(order), location=f"{self.url}/orders/{order}")
        if path.startswith("/authz/"):
            name = path[7:]
            a = self.authz[name]
            return self.reply(handler, 200, json.dumps({"identifier": {"type": "dns", "value": name}, "status": a["status"],
                "challenges": [{"type": "tls-alpn-01", "url": f"{self.url}/chal/{name}", "token": a["token"], "status": a["status"]}]}).encode())
        if path.startswith("/chal/"):
            name = path[6:]
            threading.Thread(target=self.validate, args=(name,), daemon=True).start()
            return self.reply(handler, 200, b'{"type":"tls-alpn-01","status":"processing"}')
        if path.startswith("/orders/"):
            return self.reply(handler, 200, self.order_body(path[8:]))
        if path.startswith("/finalize/"):
            order = path[10:]
            csr = openssl("req", "-inform", "DER", data=unb64(payload["csr"]))
            (self.work / "leaf.csr").write_bytes(csr)
            now = time.time()
            start, end = (now - 10, now + 20) if self.short else (now - 60, now + 90 * 86400)
            stamp = lambda t: time.strftime("%Y%m%d%H%M%SZ", time.gmtime(t))
            openssl("ca", "-batch", "-config", str(self.work / "ca.cnf"), "-notext", "-startdate", stamp(start),
                    "-enddate", stamp(end), "-in", str(self.work / "leaf.csr"), "-out", str(self.work / "leaf.pem"))
            self.orders[order]["cert"] = (self.work / "leaf.pem").read_bytes() + (self.work / "ca.pem").read_bytes()
            self.issued.append(self.orders[order]["cert"])
            return self.reply(handler, 200, self.order_body(order))
        if path.startswith("/cert/"):
            return self.reply(handler, 200, self.orders[path[6:]]["cert"], "application/pem-certificate-chain")
        return self.problem(handler, 404, "malformed", path)

    def order_body(self, order):
        o = self.orders[order]
        valid = all(self.authz[n]["status"] == "valid" for n in o["names"])
        status = "valid" if o["cert"] else "ready" if valid else "pending"
        body = {"status": status, "authorizations": [f"{self.url}/authz/{n}" for n in o["names"]], "finalize": f"{self.url}/finalize/{order}"}
        if o["cert"]: body["certificate"] = f"{self.url}/cert/{order}"
        return json.dumps(body).encode()

    def validate(self, name):
        """TLS-ALPN-01: the server's certificate for name over acme-tls/1 must carry the key
        authorization's digest in a critical acmeIdentifier extension."""
        a = self.authz[name]
        digest = hashlib.sha256(f"{a['token']}.{self.thumbprint}".encode()).digest()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname, context.verify_mode = False, ssl.CERT_NONE
        context.set_alpn_protocols(["acme-tls/1"])
        try:
            with socket.create_connection(("127.0.0.1", self.https_port), timeout=10) as raw, \
                    context.wrap_socket(raw, server_hostname=name) as tls:
                der, alpn = tls.getpeercert(binary_form=True), tls.selected_alpn_protocol()
            ok = alpn == "acme-tls/1" and ACME_IDENTIFIER in der and bytes([0x04, 0x20]) + digest in der
        except OSError:
            ok = False
        self.validations.append((name, ok))
        a["status"] = "valid" if ok else "invalid"


class Campfire:
    def __init__(self, binary, work, cache, ca, extra=None):
        self.work, self.http_port, self.https_port = work, free_port(), ca.https_port if ca else free_port()
        env = dict(os.environ, DATABASE_PATH=str(work / "production.sqlite3"), STORAGE_PATH=str(work / "storage"),
                   SECRET_KEY_BASE=secrets.token_hex(64), HTTP_PORT=str(self.http_port), HTTPS_PORT=str(self.https_port),
                   TLS_DOMAIN=DOMAIN, THRUSTER_STORAGE_PATH=str(cache), EAB_KID=EAB_KID, EAB_HMAC_KEY=EAB_KEY,
                   ACME_DIRECTORY=f"{ca.url if ca else 'https://127.0.0.1:9'}/dir", SSL_CERT_FILE=str(ca.work / "ca.pem") if ca else "/dev/null")
        env.pop("DISABLE_SSL", None)
        env.update(extra or {})
        (work / "storage").mkdir(parents=True, exist_ok=True)
        self.log = (work / "server.log").open("a+")
        self.process = subprocess.Popen([str(binary)], env=env, stdout=self.log, stderr=self.log, cwd=Path(__file__).resolve().parent)
        for _ in range(400):
            if self.process.poll() is not None:
                self.dump_log(); raise AssertionError("server exited")
            try:
                with socket.create_connection(("127.0.0.1", self.http_port), timeout=1): break
            except OSError: time.sleep(.05)
        else: raise AssertionError("server did not start")

    def close(self):
        self.process.terminate()
        try: self.process.wait(timeout=5)
        except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()

    def dump_log(self):
        self.log.seek(0); print(self.log.read(), file=sys.stderr)


def handshake(port, name, protocols, ca_file=None):
    """The certificate (DER) and protocol the server answers name with, or None when refused."""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    if ca_file: context.load_verify_locations(ca_file)
    else: context.check_hostname, context.verify_mode = False, ssl.CERT_NONE
    context.set_alpn_protocols(protocols)
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=10) as raw, context.wrap_socket(raw, server_hostname=name) as tls:
            return tls.getpeercert(binary_form=True), tls.selected_alpn_protocol()
    except (ssl.SSLError, OSError):
        return None


def wait_for(predicate, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value: return value
        time.sleep(.2)
    raise AssertionError("timed out")


def https(port, path, ca_file, data=None, headers=None, host=None):
    """An HTTP/1.1 request over TLS to DOMAIN: status, headers (lowercased name to values), body."""
    context = ssl.create_default_context(cafile=ca_file)
    context.set_alpn_protocols(["http/1.1"])
    fields = {"Host": host or f"{DOMAIN}:{port}", "Connection": "close", "Sec-Fetch-Site": "same-origin",
              "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"}
    body = b""
    if data is not None:
        body = urlencode(data).encode()
        fields.update({"Content-Type": "application/x-www-form-urlencoded", "Content-Length": str(len(body)), "Origin": f"https://{DOMAIN}:{port}"})
    fields.update(headers or {})
    head = f"{'POST' if data is not None else 'GET'} {path} HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in fields.items()) + "\r\n"
    with socket.create_connection(("127.0.0.1", port), timeout=10) as raw, context.wrap_socket(raw, server_hostname=DOMAIN) as tls:
        tls.sendall(head.encode() + body)
        return parse(read_all(tls))


def plain(port, method, path, host):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.putrequest(method, path, skip_host=True)
    connection.putheader("Host", host)
    connection.putheader("Content-Length", "0")
    connection.endheaders()
    response = connection.getresponse()
    headers = {}
    for name, value in response.getheaders(): headers.setdefault(name.lower(), []).append(value)
    result = response.status, headers, response.read().decode()
    connection.close()
    return result


def read_all(s):
    data = b""
    while True:
        try: chunk = s.recv(65536)
        except (ssl.SSLError, ConnectionResetError): break
        if not chunk: break
        data += chunk
    return data


def parse(raw):
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers.setdefault(name.strip().lower(), []).append(value.strip())
    if "chunked" in headers.get("transfer-encoding", [""])[0]:
        out = b""
        while body:
            size, _, rest = body.partition(b"\r\n")
            n = int(size, 16)
            if n == 0: break
            out, body = out + rest[:n], rest[n + 2:]
        body = out
    return int(lines[0].split()[1]), headers, body.decode("utf-8", "replace")


def leaf_of(chain):
    return ssl.PEM_cert_to_DER_cert(chain.decode().split("-----END CERTIFICATE-----")[0] + "-----END CERTIFICATE-----\n")


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        https_port = free_port()
        ca = FakeCA(work / "ca", https_port)
        ca_file = str(work / "ca" / "ca.pem")
        cache = work / "thruster"
        ca.short = True
        server = Campfire(binary, work / "app", cache, ca)
        try:
            # The certificate: ordered from ACME_DIRECTORY with EAB, its TLS-ALPN-01 challenge
            # answered on the HTTPS port itself, then served for DOMAIN with h2 or HTTP/1.1.
            first = wait_for(lambda: (handshake(https_port, DOMAIN, ["h2", "http/1.1"], ca_file) or (None,))[0], 30)
            assert first == leaf_of(ca.issued[0]) and ca.validations[0] == (DOMAIN, True), ca.validations
            assert handshake(https_port, DOMAIN, ["h2", "http/1.1"], ca_file)[1] == "h2"
            assert handshake(https_port, DOMAIN, ["http/1.1"], ca_file)[1] == "http/1.1"
            assert handshake(https_port, "other.test", ["h2", "http/1.1"]) is None
            assert handshake(https_port, DOMAIN, ["acme-tls/1"], ca_file) is None
            print("PASS: TLS_DOMAIN's certificate from ACME_DIRECTORY, with EAB and TLS-ALPN-01 on HTTPS_PORT; h2 and HTTP/1.1 by ALPN; other names refused")

            # The HTTP port: Thruster's redirect, autocert's challenge paths, other hosts misdirected.
            status, headers, body = plain(server.http_port, "GET", "/rooms/1?a=1&b=%3C", f"Chat.Test:{server.http_port}")
            assert status == 301 and headers["location"] == ["https://chat.test/rooms/1?a=1&b=%3C"] and headers["connection"] == ["close"]
            assert headers["content-type"] == ["text/html; charset=utf-8"] and body == '<a href="https://chat.test/rooms/1?a=1&amp;b=%3C">Moved Permanently</a>.\n\n'
            status, headers, body = plain(server.http_port, "POST", "/session", DOMAIN)
            assert status == 301 and headers["location"] == ["https://chat.test/session"] and "content-type" not in headers and body == ""
            status, headers, body = plain(server.http_port, "GET", "/", "evil.test")
            assert status == 421 and body == "Misdirected Request\n" and headers["x-content-type-options"] == ["nosniff"]
            status, headers, body = plain(server.http_port, "GET", "/.well-known/acme-challenge/x", DOMAIN)
            assert (status, body) == (404, "acme/autocert: certificate cache miss\n") and "connection" not in headers, headers
            assert plain(server.http_port, "GET", "/.well-known/acme-challenge/x", f"{DOMAIN}:80")[0] == 403
            print("PASS: HTTP_PORT redirects TLS_DOMAIN to HTTPS permanently, answers ACME's HTTP-01 paths as autocert, misdirects other hosts")

            # The app over HTTPS: HSTS, secure cookies, https:// URLs, and the client's
            # X-Forwarded-* ignored, as Thruster replaces them without FORWARD_HEADERS.
            status, headers, body = https(https_port, "/session/new", ca_file)
            assert status == 302 and headers.get("strict-transport-security") == ["max-age=63072000; includeSubDomains"], (status, headers)
            status, headers, _ = https(https_port, "/", ca_file, headers={"X-Forwarded-Proto": "http", "X-Forwarded-Host": "evil.test"})
            assert status == 302 and headers["location"] == [f"https://{DOMAIN}:{https_port}/session/new"], headers
            status, headers, _ = https(https_port, "/first_run", ca_file, {"user[name]": "Ada", "user[email_address]": "ada@example.test", "user[password]": "secret password"})
            assert status == 302 and headers["location"] == [f"https://{DOMAIN}:{https_port}/"], (status, headers)
            cookies = headers["set-cookie"]
            assert cookies and all("; secure" in c for c in cookies), cookies
            print("PASS: over HTTPS, HSTS and secure cookies, https:// URLs and redirects, and the client's X-Forwarded-Proto and -Host ignored")

            # Action Cable over wss://, as a browser opens it on an HTTP/1.1 connection of its own.
            session = next(c.split(";")[0] for c in cookies if c.startswith("session_token="))
            context = ssl.create_default_context(cafile=ca_file)
            context.set_alpn_protocols(["http/1.1"])
            with socket.create_connection(("127.0.0.1", https_port), timeout=10) as raw, context.wrap_socket(raw, server_hostname=DOMAIN) as tls:
                tls.sendall((f"GET /cable HTTP/1.1\r\nHost: {DOMAIN}:{https_port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                             f"Sec-WebSocket-Key: {base64.b64encode(secrets.token_bytes(16)).decode()}\r\nSec-WebSocket-Version: 13\r\n"
                             f"Sec-WebSocket-Protocol: actioncable-v1-json\r\nOrigin: https://{DOMAIN}:{https_port}\r\nCookie: {session}\r\n\r\n").encode())
                got = b""
                while b"welcome" not in got:
                    chunk = tls.recv(4096)
                    if not chunk: break
                    got += chunk
            assert got.startswith(b"HTTP/1.1 101") and b'{"type":"welcome"}' in got, got[:300]
            assert b"strict-transport-security" not in got.split(b"\r\n\r\n")[0].lower(), got[:300]
            print("PASS: Action Cable over wss://, its Origin https://, its 101 without HSTS as Action Cable writes it")

            # ActionDispatch::SSL's HSTS on every response the app writes, not only controllers'.
            hsts = ["max-age=63072000; includeSubDomains"]
            for path in ("/rails/active_storage/disk/x/y", "/no/such/page", "/up"):
                status, headers, _ = https(https_port, path, ca_file)
                assert headers.get("strict-transport-security") == hsts, (path, status, headers)
            status, headers, _ = https(https_port, "/cable", ca_file, headers={"Origin": "https://evil.test"})
            assert status == 404 and headers.get("strict-transport-security") == hsts, (status, headers)
            assert "strict-transport-security" not in plain(server.http_port, "GET", "/", DOMAIN)[1]
            print("PASS: HSTS on Active Storage's files, errors, the health check and the cable's refusal; not on the HTTP port's redirect, as Thruster's")

            # The first certificate lasts 30 seconds: renewed two thirds in, without a restart.
            ca.short = False
            renewed = wait_for(lambda: (lambda r: r and r[0] != first and r[0])(handshake(https_port, DOMAIN, ["http/1.1"], ca_file)), 40)
            assert renewed == leaf_of(ca.issued[1]) and len(ca.issued) == 2
            print("PASS: the certificate renewed while serving, new connections getting the new one")

            # Kept as Thruster keeps it (autocert's DirCache), private.
            names = sorted(p.name for p in cache.iterdir())
            assert names == ["acme_account+key", DOMAIN], names
            assert cache.stat().st_mode & 0o777 == 0o700 and all((cache / n).stat().st_mode & 0o777 == 0o600 for n in names)
            stored = (cache / DOMAIN).read_text()
            assert stored.startswith("-----BEGIN PRIVATE KEY-----") and stored.endswith("-----END CERTIFICATE-----\n")
            assert leaf_of(stored.split("-----END PRIVATE KEY-----\n")[1].encode()) == renewed
            print("PASS: the account key and the certificate in THRUSTER_STORAGE_PATH, in autocert's layout, 0700 and 0600")
        except BaseException:
            server.dump_log(); raise
        finally:
            server.close()

        # A restart with the CA gone: the cached certificate serves at once.
        ca.close()
        server = Campfire(binary, work / "app", cache, None, {"HTTPS_PORT": str(https_port)})
        server.https_port = https_port
        try:
            assert wait_for(lambda: (handshake(https_port, DOMAIN, ["h2"], ca_file) or (None,))[0], 10) == renewed
            print("PASS: after a restart, the cached certificate, with no request to the CA")
        except BaseException:
            server.dump_log(); raise
        finally:
            server.close()

        # An install that ran Thruster: its cache, as autocert wrote it (SEC 1 keys), serves as is;
        # THRUSTER_ names take precedence; DISABLE_SSL keeps HTTPS but drops HSTS and secure cookies.
        thruster = work / "thruster-old"
        thruster.mkdir(mode=0o700)
        key = openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout")
        account = openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout")
        (thruster / "key.pem").write_bytes(key)
        cert = openssl("req", "-x509", "-new", "-key", str(thruster / "key.pem"), "-subj", f"/CN={DOMAIN}", "-days", "60",
                       "-addext", f"subjectAltName=DNS:{DOMAIN}")
        (thruster / "key.pem").unlink()
        assert key.startswith(b"-----BEGIN EC PRIVATE KEY-----")
        (thruster / DOMAIN).write_bytes(key + cert)
        (thruster / "acme_account+key").write_bytes(account)
        server = Campfire(binary, work / "thruster-app", thruster, None,
                          {"HTTPS_PORT": str(https_port), "TLS_DOMAIN": "other.test", "THRUSTER_TLS_DOMAIN": f" {DOMAIN.upper()} , ", "DISABLE_SSL": "true"})
        try:
            got = wait_for(lambda: (handshake(https_port, DOMAIN, ["h2", "http/1.1"]) or (None,))[0], 10)
            assert got == ssl.PEM_cert_to_DER_cert(cert.decode())
            context_file = work / "thruster-cert.pem"
            context_file.write_bytes(cert)
            status, headers, _ = https(https_port, "/session/new", str(context_file))
            assert status == 302 and "strict-transport-security" not in headers, headers
            assert headers["location"] == [f"https://{DOMAIN}:{https_port}/first_run"] and "secure" not in str(headers.get("set-cookie")), headers
            status, headers, _ = https(https_port, "/", str(context_file))
            assert status == 302 and headers["location"] == [f"https://{DOMAIN}:{https_port}/session/new"]
            print("PASS: a cache Thruster wrote serves as is; THRUSTER_TLS_DOMAIN wins; with DISABLE_SSL, HTTPS URLs without HSTS")
        except BaseException:
            server.dump_log(); raise
        finally:
            server.close()


if __name__ == "__main__":
    main()
