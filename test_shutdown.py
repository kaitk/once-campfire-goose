#!/usr/bin/env python3
"""Graceful shutdown: on SIGTERM or SIGINT the listener closes, cable connections get Action Cable's
server_restart, requests in flight finish, and the jobs queued (webhooks, Web Push, a room's
deletion) and those they queue run until CAMPFIRE_SHUTDOWN_GRACE_MS; then the process exits 0.
Work left at the deadline is lost and counted in the log, and a second signal exits at once."""
import base64
from datetime import datetime, timezone
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlencode

from test_push import PushService, b64url, certificates, keypair
from test_webhooks import WebSocket, mention, sgid


class Receiver(http.server.ThreadingHTTPServer):
    """A bot's webhook endpoint that answers /sleep/<ms> after that long."""
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Hook)
        self.arrived = []
        self.answered = []
        self.changed = threading.Condition()

    def wait(self, count, timeout=15):
        with self.changed:
            assert self.changed.wait_for(lambda: len(self.arrived) >= count, timeout), f"{len(self.arrived)} webhooks, not {count}"


class Hook(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        with self.server.changed:
            self.server.arrived.append(time.monotonic())
            self.server.changed.notify_all()
        time.sleep(int(self.path.rsplit("/", 1)[1]) / 1000)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "4")
            self.end_headers()
            self.wfile.write(b"Pong")
            with self.server.changed:
                self.server.answered.append(time.monotonic())
        except OSError:
            pass

    def log_message(self, *args):
        pass


class SlowPush(http.server.BaseHTTPRequestHandler):
    """A push service that answers each notification after 300 ms."""
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        time.sleep(0.3)
        with self.server.changed:
            self.server.received.append({"path": self.path, "at": time.monotonic()})
            self.server.changed.notify_all()
        self.send_response(201)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")


class Server:
    def __init__(self, executable, work, receiver, **settings):
        self.work = work
        self.database = work / "production.sqlite3"
        with socket.socket() as available:
            available.bind(("127.0.0.1", 0))
            self.port = available.getsockname()[1]
        self.secret = os.urandom(32).hex()
        delay = settings.pop("HOOK_MS", "1000")
        environment = dict(os.environ, DATABASE_PATH=str(self.database), HTTP_PORT=str(self.port),
                           SECRET_KEY_BASE=self.secret, STORAGE_PATH=str(work / "files"), **settings)
        self.log_path = work / "server.log"
        self.log = self.log_path.open("w+")
        self.process = subprocess.Popen([executable], env=environment, stdout=self.log, stderr=self.log)
        for _ in range(200):
            try:
                if self.request("/up")[0] == 200:
                    break
            except OSError:
                time.sleep(.05)
        status, headers, _ = self.request("/first_run", {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test",
                                                         "user[password]": "test password"})
        assert status == 302, status
        self.cookie = headers["set-cookie"].split(";", 1)[0]
        hooks = f"http://127.0.0.1:{receiver.server_address[1]}"
        assert self.request("/account/bots", {"user[name]": "Echo bot", "user[webhook_url]": f"{hooks}/sleep/{delay}"}, self.cookie)[0] == 302
        self.bot = self.sql("SELECT id FROM users WHERE name='Echo bot' AND role=2")[0][0]

    def request(self, path, fields=None, cookie=""):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        conn.request("GET" if fields is None else "POST", path, None if fields is None else urlencode(fields),
                     {"Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded"})
        response = conn.getresponse()
        result = response.status, {k.lower(): v for k, v in response.getheaders()}, response.read().decode()
        conn.close()
        return result

    def sql(self, query, *args):
        with sqlite3.connect(self.database) as db:
            return db.execute(query, args).fetchall()

    def mention_bot(self, count):
        for i in range(count):
            body = f"<p>Hi {mention(sgid(self.secret, self.bot))} number {i}</p>"
            started = time.monotonic()
            status, _, _ = self.request("/rooms/1/messages", {"message[body]": body, "message[client_message_id]": f"hi-{i}"}, self.cookie)
            assert status == 200 and time.monotonic() - started < 1.5, status

    def text(self):
        self.log.flush()
        return self.log_path.read_text()

    def wait(self, timeout):
        try:
            return self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise AssertionError(f"still running {timeout} s after the signal")

    def report(self):
        """The process's state, and its log's end, for a failure."""
        status = self.process.poll()
        state = ("still running" if status is None else
                 f"exited by signal {signal.Signals(-status).name}" if status < 0 else f"exited with status {status}")
        return f"server {state}; its log ends:\n{self.text()[-4000:]}"

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        self.log.close()


def frames(ws):
    """The cable connection's text messages, then None at its close or EOF."""
    while True:
        try:
            op, size = ws.take(2)
        except AssertionError:
            yield None
            return
        if size == 126:
            size = int.from_bytes(ws.take(2), "big")
        payload = bytes(ws.take(size))
        if op & 0x0F == 8:
            yield None
            return
        if op & 0x0F == 1:
            yield json.loads(payload)


def refused(port):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=2).close()
        return False
    except ConnectionRefusedError:
        return True


def drained(executable, receiver):
    """Queued deliveries and a room's deletion requested in flight finish after SIGTERM."""
    with tempfile.TemporaryDirectory(prefix="campfire-shutdown-") as temporary:
        work = Path(temporary)
        context = certificates(work)
        service = PushService(work / "push.sock", context)
        service.RequestHandlerClass = SlowPush
        threading.Thread(target=service.serve_forever, daemon=True).start()
        vapid_private, vapid_public = keypair()
        server = Server(executable, work, receiver,
                        VAPID_PUBLIC_KEY=base64.urlsafe_b64encode(vapid_public).decode(),
                        VAPID_PRIVATE_KEY=base64.urlsafe_b64encode(vapid_private.to_bytes(32, "big")).decode(),
                        SSL_CERT_FILE=str(work / "ca.pem"), CAMPFIRE_PUSH_TEST_RESOLVE="fcm.googleapis.com=142.250.74.10",
                        CAMPFIRE_PUSH_TEST_CONNECT=f"unix:{work / 'push.sock'}")
        try:
            # Two members of All Talk with a push subscription each, and a room of 10,000 messages to delete.
            with sqlite3.connect(server.database) as db:
                for label in ("first", "second"):
                    user = db.execute("INSERT INTO users(name,email_address,role,status,created_at,updated_at) VALUES(?,?,0,0,?,?)",
                                      (f"{label.title()} Person", f"{label}@example.test", now(), now())).lastrowid
                    db.execute("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(1,?,'everything',?,?)",
                               (user, now(), now()))
                    db.execute("INSERT INTO push_subscriptions(user_id,endpoint,p256dh_key,auth_key,user_agent,created_at,updated_at) "
                               "VALUES(?,?,?,?,'test',?,?)", (user, f"https://fcm.googleapis.com/fcm/send/{label}",
                                                            b64url(keypair()[1]), b64url(os.urandom(16)), now(), now()))
                doomed = db.execute("INSERT INTO rooms(type,name,creator_id,created_at,updated_at) VALUES('Rooms::Open','Doomed',1,?,?)",
                                    (now(), now())).lastrowid
                db.execute("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,1,'everything',?,?)",
                           (doomed, now(), now()))
                db.executemany("INSERT INTO messages(room_id,creator_id,client_message_id,created_at,updated_at) VALUES(?,1,?,?,?)",
                               [(doomed, f"doomed-{i}", now(), now()) for i in range(10000)])
            live = WebSocket(server.port, server.cookie)
            live.sock.settimeout(5)
            # Four mentions, each a webhook answered after a second whose reply is a message, and each of
            # the eight messages two pushes answered after 300 ms: more than the delivery threads finish
            # before the signal.
            server.mention_bot(4)
            # A request in flight: the room's deletion, half sent.
            body = urlencode({"_method": "delete"}).encode()
            pending = socket.create_connection(("127.0.0.1", server.port), timeout=10)
            pending.sendall((f"POST /rooms/{doomed} HTTP/1.1\r\nHost: 127.0.0.1:{server.port}\r\nCookie: {server.cookie}\r\n"
                             f"Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body[:4])
            time.sleep(0.2)
            signalled = time.monotonic()
            server.process.send_signal(signal.SIGTERM)

            messages = frames(live)
            message = next(messages)
            while message is not None and message.get("type") == "ping":
                message = next(messages)
            assert message == {"type": "disconnect", "reason": "server_restart", "reconnect": True}, message
            assert next(messages) is None
            assert time.monotonic() - signalled < 2
            assert server.process.poll() is None, "the drain ended before its work"
            assert refused(server.port)
            print("PASS: at SIGTERM the cable connections get server_restart and close, and new connections are refused")

            pending.sendall(body[4:])
            answer = b""
            while part := pending.recv(4096):
                answer += part
            pending.close()
            assert answer.startswith(b"HTTP/1.1 302 "), answer[:300]
            print("PASS: a request in flight at SIGTERM is answered, and its connection closed")

            assert server.wait(10) == 0
            stopped = time.monotonic() - signalled
            assert stopped < 8 + 1, stopped
            log = server.text()
            assert "Shutting down: requests in flight and " in log and "Shutdown: every job finished\n" in log, log
            assert len(receiver.answered) == 4
            assert [body for (body,) in server.sql("SELECT t.body FROM messages m JOIN action_text_rich_texts t ON t.record_type='Message' "
                                                   "AND t.record_id=m.id WHERE m.creator_id=?", server.bot)] == ["Pong"] * 4
            assert len(service.received) == 16, len(service.received)
            assert max(push["at"] for push in service.received) > signalled + 0.5
            assert server.sql("SELECT count(*) FROM rooms WHERE id=?", doomed) == [(0,)]
            assert server.sql("SELECT count(*) FROM messages WHERE room_id=?", doomed) == [(0,)]
            print(f"PASS: the webhooks, their replies, 16 pushes and a 10,000-message room's deletion finish after SIGTERM, "
                  f"and the process exits 0 ({stopped:.1f} s)")
        except BaseException:
            print(server.report(), file=sys.stderr)
            raise
        finally:
            server.close()
            service.shutdown()


def deadline(executable, receiver):
    """Work that outlasts the grace is lost, counted, and doesn't hold the exit."""
    with tempfile.TemporaryDirectory(prefix="campfire-shutdown-") as temporary:
        server = Server(executable, Path(temporary), receiver, CAMPFIRE_SHUTDOWN_GRACE_MS="1500", HOOK_MS="6000")
        try:
            before = len(receiver.arrived)
            server.mention_bot(6)
            receiver.wait(before + 4)
            signalled = time.monotonic()
            server.process.send_signal(signal.SIGTERM)
            assert server.wait(5) == 0
            stopped = time.monotonic() - signalled
            assert 1.4 < stopped < 1.5 + 1, stopped
            log = server.text()
            assert ("Shutdown: 2 queued and 4 running jobs are lost at the 1500 ms deadline "
                    "(queued+running: deliveries 2+4, cleanups 0+0, media 0+0)\n") in log, log
            assert server.sql("SELECT count(*) FROM messages WHERE creator_id=?", server.bot) == [(0,)]
            print(f"PASS: jobs left at the deadline are lost and counted, and the process exits 0 at once ({stopped:.1f} s)")
        except BaseException:
            print(server.report(), file=sys.stderr)
            raise
        finally:
            server.close()


def second_signal(executable, receiver):
    """A second signal ends the drain at once."""
    with tempfile.TemporaryDirectory(prefix="campfire-shutdown-") as temporary:
        server = Server(executable, Path(temporary), receiver, HOOK_MS="6000")
        try:
            before = len(receiver.arrived)
            server.mention_bot(2)
            receiver.wait(before + 2)
            server.process.send_signal(signal.SIGINT)
            time.sleep(0.5)
            assert server.process.poll() is None and refused(server.port)
            signalled = time.monotonic()
            server.process.send_signal(signal.SIGTERM)
            assert server.wait(2) == 128 + signal.SIGTERM
            assert time.monotonic() - signalled < 1
            assert "A second signal: exiting now\n" in server.text()
            print("PASS: SIGINT starts the shutdown too, and a second signal exits at once")
        except BaseException:
            print(server.report(), file=sys.stderr)
            raise
        finally:
            server.close()


def main():
    executable = str(Path(sys.argv[1]).resolve())
    receiver = Receiver()
    threading.Thread(target=receiver.serve_forever, daemon=True).start()
    drained(executable, receiver)
    deadline(executable, receiver)
    second_signal(executable, receiver)


if __name__ == "__main__":
    main()
