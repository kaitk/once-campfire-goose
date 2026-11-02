#!/usr/bin/env python3
"""Web Push: who a message notifies, the encrypted payload and VAPID token a push service receives,
expired-subscription cleanup, the private-address guard and test notifications.

The push service is a TLS receiver on a Unix socket, trusted through SSL_CERT_FILE. The server
reaches it through two TEST ONLY settings: CAMPFIRE_PUSH_TEST_RESOLVE answers the push hosts'
lookups (the guard still judges the answers) and CAMPFIRE_PUSH_TEST_CONNECT sends the admitted
connection to the socket; TLS still checks the endpoint's host. RFC 8291 decryption and ES256
verification are done here in plain Python, independently of the server's OpenSSL."""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import socket
import socketserver
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlencode

# --- P-256 (SEC 2), for ECDH and ES256 verification -------------------------------------------

P = 2**256 - 2**224 + 2**192 + 2**96 - 1
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
G = (0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
     0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)


def on_curve(point):
    x, y = point
    return (y * y - (x * x * x - 3 * x + B)) % P == 0


def add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    (x1, y1), (x2, y2) = p1, p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        slope = (3 * x1 * x1 - 3) * pow(2 * y1, -1, P) % P
    else:
        slope = (y2 - y1) * pow(x2 - x1, -1, P) % P
    x3 = (slope * slope - x1 - x2) % P
    return x3, (slope * (x1 - x3) - y1) % P


def multiply(k, point):
    result = None
    while k:
        if k & 1:
            result = add(result, point)
        point = add(point, point)
        k >>= 1
    return result


def encode_point(point):
    return b"\x04" + point[0].to_bytes(32, "big") + point[1].to_bytes(32, "big")


def decode_point(data):
    assert len(data) == 65 and data[0] == 4, data
    point = int.from_bytes(data[1:33], "big"), int.from_bytes(data[33:], "big")
    assert on_curve(point)
    return point


def keypair():
    private = secrets.randbelow(N - 1) + 1
    return private, encode_point(multiply(private, G))


def es256_valid(public, message, signature):
    r, s = int.from_bytes(signature[:32], "big"), int.from_bytes(signature[32:], "big")
    if not (0 < r < N and 0 < s < N):
        return False
    w = pow(s, -1, N)
    h = int.from_bytes(hashlib.sha256(message).digest(), "big")
    point = add(multiply(h * w % N, G), multiply(r * w % N, decode_point(public)))
    return point is not None and point[0] % N == r


# --- AES-128 (FIPS 197) and GCM (SP 800-38D), for aes128gcm -------------------------------------

def _xtime(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _gmul(a, b):
    result = 0
    while b:
        if b & 1:
            result ^= a
        a, b = _xtime(a), b >> 1
    return result


SBOX = []
for _x in range(256):
    _inverse = 0 if _x == 0 else next(y for y in range(1, 256) if _gmul(_x, y) == 1)
    _s = _inverse
    for _i in range(1, 5):
        _s ^= ((_inverse << _i) | (_inverse >> (8 - _i))) & 0xFF
    SBOX.append(_s ^ 0x63)


def aes_encrypt_block(key, block):
    words = [list(key[i:i + 4]) for i in range(0, 16, 4)]
    rcon = 1
    for i in range(4, 44):
        word = list(words[i - 1])
        if i % 4 == 0:
            word = [SBOX[b] for b in word[1:] + word[:1]]
            word[0] ^= rcon
            rcon = _xtime(rcon)
        words.append([a ^ b for a, b in zip(words[i - 4], word)])
    round_keys = [sum(words[r * 4:r * 4 + 4], []) for r in range(11)]
    state = [a ^ b for a, b in zip(block, round_keys[0])]
    for round_number in range(1, 11):
        state = [SBOX[b] for b in state]
        state = [state[r + 4 * ((c + r) % 4)] for c in range(4) for r in range(4)]
        if round_number != 10:
            mixed = []
            for c in range(4):
                a = state[4 * c:4 * c + 4]
                mixed += [_gmul(a[0], 2) ^ _gmul(a[1], 3) ^ a[2] ^ a[3], a[0] ^ _gmul(a[1], 2) ^ _gmul(a[2], 3) ^ a[3],
                          a[0] ^ a[1] ^ _gmul(a[2], 2) ^ _gmul(a[3], 3), _gmul(a[0], 3) ^ a[1] ^ a[2] ^ _gmul(a[3], 2)]
            state = mixed
        state = [a ^ b for a, b in zip(state, round_keys[round_number])]
    return bytes(state)


def _ghash_multiply(x, y):
    z, v = 0, y
    for i in range(127, -1, -1):
        if (x >> i) & 1:
            z ^= v
        v = (v >> 1) ^ (0xE1 << 120) if v & 1 else v >> 1
    return z


def gcm_decrypt(key, nonce, sealed):
    ciphertext, tag = sealed[:-16], sealed[-16:]
    h = int.from_bytes(aes_encrypt_block(key, bytes(16)), "big")
    counter0 = nonce + b"\x00\x00\x00\x01"
    plaintext = bytearray()
    for i in range(0, len(ciphertext), 16):
        stream = aes_encrypt_block(key, nonce + (2 + i // 16).to_bytes(4, "big"))
        plaintext += bytes(a ^ b for a, b in zip(ciphertext[i:i + 16], stream))
    y = 0
    padded = ciphertext + bytes(-len(ciphertext) % 16)
    for i in range(0, len(padded), 16):
        y = _ghash_multiply(y ^ int.from_bytes(padded[i:i + 16], "big"), h)
    y = _ghash_multiply(y ^ (len(ciphertext) * 8), h)
    expected = (y ^ int.from_bytes(aes_encrypt_block(key, counter0), "big")).to_bytes(16, "big")
    assert hmac.compare_digest(expected, tag), "aes128gcm tag mismatch"
    return bytes(plaintext)


# --- RFC 8291 -----------------------------------------------------------------------------------

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64url(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def hkdf(salt, ikm, info, length):
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()[:length]


def push_decrypt(body, private, public, auth):
    salt, rs, idlen = body[:16], int.from_bytes(body[16:20], "big"), body[20]
    assert idlen == 65
    sender = body[21:21 + idlen]
    record = body[21 + idlen:]
    assert 18 <= len(record) <= rs, (len(record), rs)
    secret = multiply(private, decode_point(sender))[0].to_bytes(32, "big")
    ikm = hkdf(auth, secret, b"WebPush: info\x00" + public + sender, 32)
    key = hkdf(salt, ikm, b"Content-Encoding: aes128gcm\x00", 16)
    nonce = hkdf(salt, ikm, b"Content-Encoding: nonce\x00", 12)
    padded = gcm_decrypt(key, nonce, record).rstrip(b"\x00")
    assert padded.endswith(b"\x02"), "the only record must end with the last-record delimiter"
    return padded[:-1], rs, len(record)


def self_check():
    assert aes_encrypt_block(bytes(range(16)), bytes.fromhex("00112233445566778899aabbccddeeff")).hex() == "69c4e0d86a7b0430d8cdb78070b4c55a"
    body = unb64url("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_"
                    "yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN")
    private = int.from_bytes(unb64url("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"), "big")
    public = unb64url("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
    assert encode_point(multiply(private, G)) == public
    plaintext, rs, _ = push_decrypt(body, private, public, unb64url("BTBZMqHH6r4Tts7J_aSIgg"))
    assert plaintext == b"When I grow up, I want to be a watermelon" and rs == 4096


def sgid(secret, user):
    key = hashlib.pbkdf2_hmac("sha256", secret.encode(), b"signed_global_ids", 1000, 64)
    envelope = json.dumps({"_rails": {"data": f"gid://campfire/User/{user}?expires_in", "pur": "attachable"}}, separators=(",", ":"))
    data = base64.urlsafe_b64encode(envelope.encode()).decode()
    return data + "--" + hmac.new(key, data.encode(), hashlib.sha1).hexdigest()


def mention(token):
    return (f'<action-text-attachment sgid="{token}" content-type="application/vnd.campfire.mention" '
            'content="&lt;span class=&quot;mention&quot;&gt;x&lt;/span&gt;"></action-text-attachment>')


# --- The push service ---------------------------------------------------------------------------

HOSTS = ["fcm.googleapis.com", "updates.push.services.mozilla.com", "web.push.apple.com", "wns2-par02p.notify.windows.com"]


def certificates(work):
    def openssl(*args):
        subprocess.run(["openssl", *args], cwd=work, check=True, capture_output=True)
    openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "ca.key",
            "-out", "ca.pem", "-days", "1", "-subj", "/CN=Push test CA", "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign")
    openssl("req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "leaf.key",
            "-out", "leaf.csr", "-subj", "/CN=fcm.googleapis.com")
    (work / "leaf.cnf").write_text("subjectAltName=" + ",".join(f"DNS:{host}" for host in HOSTS) +
                                   "\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n")
    openssl("x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "2", "-days", "1",
            "-out", "leaf.pem", "-extfile", "leaf.cnf")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(work / "leaf.pem", work / "leaf.key")
    return context


class PushService(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def __init__(self, path, context):
        self.context = context
        self.received = []
        self.changed = threading.Condition()
        super().__init__(str(path), PushHandler)

    def finish_request(self, request, client_address):
        try:
            tls = self.context.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError):
            return
        try:
            self.RequestHandlerClass(tls, ("push", 0), self)
        finally:
            tls.close()

    def wait(self, count, timeout=15):
        with self.changed:
            assert self.changed.wait_for(lambda: len(self.received) >= count, timeout), \
                f"{len(self.received)} pushes arrived, not {count}"
            return list(self.received)

    def take(self, count, settle=0.5):
        got = self.wait(count)
        time.sleep(settle)
        with self.changed:
            assert len(self.received) == count, [r["path"] for r in self.received]
            self.received.clear()
        return got


class PushHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        with self.server.changed:
            self.server.received.append({"path": self.path, "headers": self.headers, "body": body, "at": time.monotonic()})
            self.server.changed.notify_all()
        if self.path.endswith("/slow"):
            time.sleep(3)
        status = 410 if self.path.endswith("/gone") else 404 if self.path.endswith("/missing") else \
            500 if self.path.endswith("/broken") else 201
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


def main():
    executable = Path(sys.argv[1]).resolve()
    self_check()
    print("PASS: the test's RFC 8291 decryption opens RFC 8291's example")
    with tempfile.TemporaryDirectory(prefix="campfire-push-") as temporary:
        work = Path(temporary)
        context = certificates(work)
        service = PushService(work / "push.sock", context)
        threading.Thread(target=service.serve_forever, daemon=True).start()
        database = work / "production.sqlite3"
        with socket.socket() as available:
            available.bind(("127.0.0.1", 0))
            port = available.getsockname()[1]
        vapid_private, vapid_public = keypair()
        secret = secrets.token_hex(64)
        # As WebPush.generate_key's keys are written: URL-safe Base64 with padding.
        environment = dict(os.environ, DATABASE_PATH=str(database), HTTP_PORT=str(port), SECRET_KEY_BASE=secret,
                           VAPID_PUBLIC_KEY=base64.urlsafe_b64encode(vapid_public).decode(),
                           VAPID_PRIVATE_KEY=base64.urlsafe_b64encode(vapid_private.to_bytes(32, "big")).decode(),
                           SSL_CERT_FILE=str(work / "ca.pem"),
                           CAMPFIRE_PUSH_TEST_RESOLVE="fcm.googleapis.com=142.250.74.10,updates.push.services.mozilla.com=2a00:1450:4001::1,"
                                                      "web.push.apple.com=10.9.9.9,wns2-par02p.notify.windows.com=93.184.216.34",
                           CAMPFIRE_PUSH_TEST_CONNECT=f"unix:{work / 'push.sock'}")
        log_path = work / "server.log"
        with log_path.open("w+") as log:
            server = subprocess.Popen([str(executable)], env=environment, stdout=log, stderr=log)

            def request(path, fields=None, cookie="", raw=None, kind="application/x-www-form-urlencoded"):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
                body = raw if raw is not None else (None if fields is None else urlencode(fields))
                conn.request("GET" if body is None else "POST", path, body, {"Cookie": cookie, "Content-Type": kind})
                response = conn.getresponse()
                result = response.status, {k.lower(): v for k, v in response.getheaders()}, response.read().decode()
                conn.close()
                return result

            def sql(query, *args):
                with sqlite3.connect(database) as db:
                    return db.execute(query, args).fetchall()

            def now(offset=0):
                return (datetime.now(timezone.utc) + timedelta(seconds=offset)).strftime("%Y-%m-%d %H:%M:%S.%f")

            keys = {}

            def subscribe(user, label, host="fcm.googleapis.com", p256dh=None):
                private, public = keypair()
                auth = secrets.token_bytes(16)
                endpoint = f"https://{host}/fcm/send/{label}"
                with sqlite3.connect(database) as db:
                    id = db.execute("INSERT INTO push_subscriptions(user_id,endpoint,p256dh_key,auth_key,user_agent,created_at,updated_at) "
                                    "VALUES(?,?,?,?,'test',?,?)", (user, endpoint, p256dh or b64url(public), b64url(auth), now(), now())).lastrowid
                keys[f"/fcm/send/{label}"] = (private, public, auth, id)
                return id

            def opened(push):
                private, public, auth, _ = keys[push["path"]]
                assert push["headers"]["Content-Encoding"] == "aes128gcm"
                assert push["headers"]["Content-Type"] == "application/octet-stream"
                assert push["headers"]["Ttl"] == "2419200" and push["headers"]["Urgency"] == "high"
                assert int(push["headers"]["Content-Length"]) == len(push["body"])
                plaintext, rs, record = push_decrypt(push["body"], private, public, auth)
                assert rs == record, (rs, record)  # the gem's record size: the record's own length
                # The VAPID token: ES256 over the endpoint's origin, twelve hours, Rails' subject.
                scheme, _, credentials = push["headers"]["Authorization"].partition(" ")
                token, key = dict(part.split("=", 1) for part in credentials.split(","))["t"], credentials.split(",k=")[1]
                assert scheme == "vapid" and credentials == f"t={token},k={key}" and key == b64url(vapid_public)
                head, claims, signature = token.split(".")
                assert json.loads(unb64url(head)) == {"typ": "JWT", "alg": "ES256"}
                claims = json.loads(unb64url(claims))
                assert list(claims) == ["aud", "exp", "sub"] and claims["sub"] == "mailto:support@37signals.com"
                assert claims["aud"] == f"https://{push['headers']['Host']}" and abs(claims["exp"] - time.time() - 43200) < 120
                assert es256_valid(vapid_public, token.rsplit(".", 1)[0].encode(), unb64url(signature))
                return plaintext

            def expected(title, body, path, user):
                badge = sql("SELECT count(*) FROM memberships WHERE user_id=? AND unread_at IS NOT NULL", user)[0][0]
                return json.dumps({"title": title, "options": {"body": body, "icon": "/account/logo", "data": {"path": path, "badge": badge}}},
                                  separators=(",", ":"), ensure_ascii=False).encode()

            def post(room, text, cookie, client_id):
                started = time.monotonic()
                status, _, _ = request(f"/rooms/{room}/messages", {"message[body]": text, "message[client_message_id]": client_id}, cookie)
                assert status == 200, status
                assert time.monotonic() - started < 1.5
                return sql("SELECT id FROM messages WHERE client_message_id=?", client_id)[0][0]

            try:
                for _ in range(100):
                    try:
                        if request("/up")[0] == 200:
                            break
                    except OSError:
                        time.sleep(.05)
                status, headers, _ = request("/first_run", {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test",
                                                            "user[password]": "test password"})
                assert status == 303
                cookie = headers["set-cookie"].split(";", 1)[0]
                log.flush()
                assert "Web Push: on\n" in log_path.read_text()

                # The subscription form stores the browser's subscription; an endpoint must be a push service.
                own_private, own_public = keypair()
                own_auth = secrets.token_bytes(16)
                own_endpoint = "https://fcm.googleapis.com/fcm/send/own"
                subscription = json.dumps({"push_subscription": {"endpoint": own_endpoint, "p256dh_key": b64url(own_public), "auth_key": b64url(own_auth)}})
                assert request("/users/me/push_subscriptions", raw=subscription, cookie=cookie, kind="application/json")[0] == 200
                own = sql("SELECT id FROM push_subscriptions WHERE endpoint=?", own_endpoint)[0][0]
                keys["/fcm/send/own"] = (own_private, own_public, own_auth, own)

                # Members of All Talk (room 1) by involvement and presence; Ada posts.
                people = {}
                with sqlite3.connect(database) as db:
                    for label, involvement, connected in [("everything", "everything", None), ("present", "everything", now()),
                                                          ("stale", "everything", now(-120)), ("mentioned", "mentions", None),
                                                          ("unmentioned", "mentions", None), ("quiet", "nothing", None),
                                                          ("invisible", "invisible", None), ("nobody", "everything", None),
                                                          ("mozilla", "everything", None)]:
                        user = db.execute("INSERT INTO users(name,email_address,role,status,created_at,updated_at) VALUES(?,?,0,0,?,?)",
                                          (f"{label.title()} Person", f"{label}@example.test", now(), now())).lastrowid
                        db.execute("INSERT INTO memberships(room_id,user_id,involvement,connected_at,created_at,updated_at) VALUES(1,?,?,?,?,?)",
                                   (user, involvement, connected, now(), now()))
                        people[label] = user
                    db.execute("UPDATE memberships SET involvement='everything' WHERE user_id=1")
                for label in ("everything", "present", "stale", "mentioned", "unmentioned", "quiet", "invisible"):
                    subscribe(people[label], label)
                subscribe(people["everything"], "everything-second")
                subscribe(people["mozilla"], "mozilla", host="updates.push.services.mozilla.com")
                # Refused: a stored endpoint that isn't a push service, and a push host resolving to a private address.
                with sqlite3.connect(database) as db:
                    loopback = db.execute("INSERT INTO push_subscriptions(user_id,endpoint,p256dh_key,auth_key,created_at,updated_at) "
                                          "VALUES(?,'https://127.0.0.1:9/push/1','x','y',?,?)", (people["nobody"], now(), now())).lastrowid
                private = subscribe(people["nobody"], "private", host="web.push.apple.com")

                text = 'Hi "there" & <b>you</b> / héllo ☃'
                message = post(1, f"<p>{text}</p>", cookie, "plain-1")
                plain = sql("SELECT body FROM message_search_index WHERE rowid=?", message)[0][0]
                assert plain == 'Hi "there" & you / héllo ☃', plain
                arrived = {p["path"]: p for p in service.take(4)}
                assert sorted(arrived) == ["/fcm/send/everything", "/fcm/send/everything-second", "/fcm/send/mozilla", "/fcm/send/stale"], sorted(arrived)
                for path, push in arrived.items():
                    user = sql("SELECT user_id FROM push_subscriptions WHERE id=?", keys[path][3])[0][0]
                    payload = opened(push)
                    assert payload == expected("All Talk", f"Ada Admin: {plain}", "/rooms/1", user), payload
                assert json.loads(opened(arrived["/fcm/send/stale"]))["options"]["data"]["badge"] == 1
                assert arrived["/fcm/send/mozilla"]["headers"]["Host"] == "updates.push.services.mozilla.com"
                print("PASS: a message notifies members involved in everything who aren't connected, not its author; "
                      "the payload decrypts to Rails' JSON and the VAPID token verifies")

                body = (f"<p>Hey {mention(sgid(secret, people['mentioned']))} {mention(sgid(secret, people['quiet']))} "
                        f"{mention(sgid(secret, people['invisible']))} {mention(sgid(secret, people['present']))}</p>")
                message = post(1, body, cookie, "mention-1")
                plain = sql("SELECT body FROM message_search_index WHERE rowid=?", message)[0][0]
                assert plain == "Hey @Mentioned Person @Quiet Person @Invisible Person @Present Person", plain
                arrived = {p["path"]: p for p in service.take(5)}
                assert sorted(arrived) == ["/fcm/send/everything", "/fcm/send/everything-second", "/fcm/send/mentioned",
                                           "/fcm/send/mozilla", "/fcm/send/stale"], sorted(arrived)
                assert opened(arrived["/fcm/send/mentioned"]) == expected("All Talk", f"Ada Admin: {plain}", "/rooms/1", people["mentioned"])
                print("PASS: members involved in mentions are notified only when mentioned; nothing, invisible and connected members never")

                # A direct room: the creator's name is the title, the body is the text alone.
                with sqlite3.connect(database) as db:
                    direct = db.execute("INSERT INTO rooms(type,creator_id,created_at,updated_at) VALUES('Rooms::Direct',1,?,?)", (now(), now())).lastrowid
                    friend = db.execute("INSERT INTO users(name,email_address,role,status,created_at,updated_at) VALUES('Friend Person','friend@example.test',0,0,?,?)",
                                        (now(), now())).lastrowid
                    for user in (1, friend):
                        db.execute("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,'everything',?,?)", (direct, user, now(), now()))
                subscribe(friend, "friend")
                post(direct, "Just us", cookie, "direct-1")
                push = service.take(1)[0]
                assert push["path"] == "/fcm/send/friend"
                assert opened(push) == expected("Ada Admin", "Just us", f"/rooms/{direct}", friend)
                print("PASS: a direct room's notification is titled with its sender and carries the text alone")

                # Refused before any connection: a stored endpoint that isn't a push service, and a push host
                # whose lookup gives only a private address. Neither is destroyed; each is logged.
                assert sql("SELECT count(*) FROM push_subscriptions WHERE id IN (?,?)", loopback, private)[0][0] == 2
                log.flush()
                text_log = log_path.read_text()
                assert f"Web Push to subscription {loopback} skipped: its endpoint is not a permitted push service" in text_log, text_log
                assert f"Web Push to subscription {private} skipped: web.push.apple.com resolves only to private or reserved addresses" in text_log, text_log

                # The benchmark seed's shape: endpoints at https://127.0.0.1:9 cost one query per message and no connection.
                with sqlite3.connect(database) as db:
                    bench = db.execute("INSERT INTO rooms(type,name,creator_id,created_at,updated_at) VALUES('Rooms::Open','Bench',1,?,?)", (now(), now())).lastrowid
                    db.execute("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,1,'nothing',?,?)", (bench, now(), now()))
                    seeded = []
                    for i in range(3):
                        user = db.execute("INSERT INTO users(name,email_address,role,status,created_at,updated_at) VALUES(?,?,0,0,?,?)",
                                          (f"Bench {i}", f"bench{i}@example.test", now(), now())).lastrowid
                        db.execute("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,'everything',?,?)", (bench, user, now(), now()))
                        seeded.append(db.execute("INSERT INTO push_subscriptions(user_id,endpoint,p256dh_key,auth_key,created_at,updated_at) "
                                                 "VALUES(?,'https://127.0.0.1:9/push/'||?,'x','y',?,?)", (user, i, now(), now())).lastrowid)
                started = time.monotonic()
                for i in range(200):
                    post(bench, f"Bench {i}", cookie, f"bench-{i}")
                elapsed = time.monotonic() - started
                time.sleep(1)
                assert service.received == [], [p["path"] for p in service.received]
                log.flush()
                text_log = log_path.read_text()
                for id in seeded:
                    logged = text_log.count(f"Web Push to subscription {id} skipped")
                    assert 1 <= logged <= 4, logged
                assert "queue is full" not in text_log
                print(f"PASS: refused endpoints (not a push service, or resolving to a private address) are never contacted; "
                      f"200 benchmark-shaped posts took {elapsed:.2f}s")

                # What the push service answers: 410 and 404 destroy the subscription, a 5xx keeps it, and a
                # p256dh key that is no P-256 point destroys it before anything is sent.
                with sqlite3.connect(database) as db:
                    cleanup = db.execute("INSERT INTO rooms(type,name,creator_id,created_at,updated_at) VALUES('Rooms::Open','Cleanup',1,?,?)", (now(), now())).lastrowid
                    db.execute("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,1,'everything',?,?)", (cleanup, now(), now()))
                    members = {}
                    for label in ("gone", "missing", "broken", "badkey"):
                        members[label] = db.execute("INSERT INTO users(name,email_address,role,status,created_at,updated_at) VALUES(?,?,0,0,?,?)",
                                                    (label, f"{label}@example.test", now(), now())).lastrowid
                        db.execute("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,'everything',?,?)",
                                   (cleanup, members[label], now(), now()))
                off_curve = bytearray(keypair()[1])
                off_curve[64] ^= 1
                ids = {label: subscribe(members[label], label) for label in ("gone", "missing", "broken")}
                ids["badkey"] = subscribe(members["badkey"], "badkey", p256dh=b64url(bytes(off_curve)))
                post(cleanup, "Anyone there?", cookie, "cleanup-1")
                assert sorted(p["path"] for p in service.take(3)) == ["/fcm/send/broken", "/fcm/send/gone", "/fcm/send/missing"]

                def remaining():
                    return {row[0] for row in sql("SELECT id FROM push_subscriptions WHERE id IN (?,?,?,?)", *ids.values())}
                deadline = time.monotonic() + 10
                while remaining() != {ids["broken"]} and time.monotonic() < deadline:
                    time.sleep(0.05)
                assert remaining() == {ids["broken"]}, remaining()
                log.flush()
                text_log = log_path.read_text()
                for label in ("gone", "missing", "badkey"):
                    assert f"Destroying push subscription: {ids[label]}" in text_log, label
                assert f"Web Push to subscription {ids['broken']} failed: WebPush::PushServiceError" in text_log
                print("PASS: 410 and 404 answers and invalid keys destroy the subscription; a 500 is logged and kept")

                # Test notifications: delivered off the request, to the user's own subscription only.
                started = time.monotonic()
                status, headers, _ = request(f"/users/me/push_subscriptions/{own}/test_notifications", {}, cookie)
                assert status == 302 and headers["location"].endswith("/users/me/push_subscriptions"), (status, headers)
                assert time.monotonic() - started < 1.5
                push = service.take(1)[0]
                assert push["path"] == "/fcm/send/own"
                payload = json.loads(opened(push))
                assert re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", payload["options"]["body"]), payload
                assert opened(push) == expected("Campfire Test", payload["options"]["body"], f"http://127.0.0.1:{port}/users/me/push_subscriptions", 1)
                foreign = keys["/fcm/send/friend"][3]
                assert request(f"/users/me/push_subscriptions/{foreign}/test_notifications", {}, cookie)[0] == 404
                time.sleep(0.5)
                assert service.received == []
                print("PASS: a test notification is sent off the request path, only for the user's own subscription")

                # A slow push service never holds a POST.
                with sqlite3.connect(database) as db:
                    slow_room = db.execute("INSERT INTO rooms(type,name,creator_id,created_at,updated_at) VALUES('Rooms::Open','Slow',1,?,?)", (now(), now())).lastrowid
                    db.execute("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,1,'nothing',?,?)", (slow_room, now(), now()))
                    sluggish = db.execute("INSERT INTO users(name,email_address,role,status,created_at,updated_at) VALUES('Slow Person','slow@example.test',0,0,?,?)",
                                          (now(), now())).lastrowid
                    db.execute("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,'everything',?,?)", (slow_room, sluggish, now(), now()))
                subscribe(sluggish, "slow")
                for i in range(6):
                    post(slow_room, f"Slow {i}", cookie, f"slow-{i}")
                assert [p["path"] for p in service.take(6)] == ["/fcm/send/slow"] * 6
                assert request("/up")[0] == 200 and server.poll() is None
                print("PASS: a slow push service never delays a POST")
            except BaseException:
                log.flush()
                print(log_path.read_text()[-4000:], file=sys.stderr)
                raise
            finally:
                server.terminate()
                server.wait(timeout=10)
                service.shutdown()


if __name__ == "__main__":
    main()
