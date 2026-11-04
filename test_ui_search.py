#!/usr/bin/env python3
"""Search, permalinks, room navigation and message paging, as in Rails: SearchesController (recording,
sanitizing, recent searches), WelcomeController and TrackedRoomVisit, RoomsController#index and #show
with /rooms/:id/@:message_id, the flash set_room leaves, MessagesController#index's paging, 204 and
validators, and MessagesController#create's room_not_found."""
import gzip
import http.client
import os
from pathlib import Path
import re
import secrets
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlencode


binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="campfire-search-") as directory:
    work = Path(directory)
    database = work / "production.sqlite3"
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = dict(os.environ, DATABASE_PATH=str(database), SECRET_KEY_BASE=secrets.token_hex(64), HTTP_PORT=str(port))
    base = f"http://127.0.0.1:{port}"
    with (work / "server.log").open("w+") as log:
        server = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)

        def request(path, data=None, cookie="", method=None, headers=None):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
            fields = {"Host": f"127.0.0.1:{port}", "Accept-Encoding": "gzip"}
            if cookie:
                fields["Cookie"] = cookie
            if data is not None:
                fields.update({"Content-Type": "application/x-www-form-urlencoded", "Sec-Fetch-Site": "same-origin"})
                data = urlencode(data, doseq=True)
            fields.update(headers or {})
            conn.request(method or ("GET" if data is None else "POST"), path, data, fields)
            response = conn.getresponse()
            body = response.read()
            if response.getheader("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            headers = {k.lower(): v for k, v in response.getheaders()}
            headers["set-cookies"] = response.msg.get_all("Set-Cookie") or []
            conn.close()
            return response.status, headers, body.decode()

        def query(sql, *args):
            with sqlite3.connect(database, timeout=10) as db:
                return db.execute(sql, args).fetchall()

        def execute(sql, *args):
            with sqlite3.connect(database, timeout=10) as db:
                db.execute(sql, args)

        def ids(body):
            return [int(i) for i in re.findall(r'data-message-id="(\d+)"', body)]

        def cookie_named(headers, name):
            return next((c for c in headers["set-cookies"] if c.startswith(name + "=")), None)

        try:
            for _ in range(200):
                if server.poll() is not None:
                    raise AssertionError("server exited")
                try:
                    if request("/up")[0] == 200:
                        break
                except ConnectionRefusedError:
                    time.sleep(.05)
            else:
                raise AssertionError("server did not start")
            status, headers, _ = request("/first_run", {"user[name]": "Ada Admin", "user[email_address]": "ada@example.test", "user[password]": "admin password"})
            assert status == 302
            admin = headers["set-cookie"].split(";", 1)[0]
            code = query("SELECT join_code FROM accounts")[0][0]
            status, headers, _ = request(f"/join/{code}", {"user[name]": "Bob Member", "user[email_address]": "bob@example.test", "user[password]": "member password"})
            assert status == 302
            member = headers["set-cookie"].split(";", 1)[0]
            admin_id, member_id = (query("SELECT id FROM users WHERE email_address=?", email)[0][0] for email in ("ada@example.test", "bob@example.test"))
            texts = ["hello-world one", "hello world two", "café crème", "under_score three"] + [f"filler {n:03}" for n in range(96)]
            for n, text in enumerate(texts):
                status, _, _ = request("/rooms/1/messages", {"message[body]": text, "message[client_message_id]": f"search-{n}"}, admin)
                assert status == 200, status
            messages = [row[0] for row in query("SELECT id FROM messages WHERE room_id=1 ORDER BY created_at,id")]
            assert len(messages) == 100

            # TrackedRoomVisit: the root goes to the last room visited while the user is in it, else the earliest.
            execute("INSERT INTO rooms(id,name,type,creator_id,created_at,updated_at) VALUES (2,'Second','Rooms::Closed',?, '2030-01-01 00:00:00','2030-01-01 00:00:00')", admin_id)
            execute("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES (2,?,'mentions','2030-01-01','2030-01-01')", admin_id)
            status, headers, _ = request("/", cookie=admin)
            assert status == 302 and headers["location"] == f"{base}/rooms/1", (status, headers)
            status, headers, body = request("/rooms/2", cookie=admin)
            last_room = cookie_named(headers, "last_room")
            assert status == 200 and last_room.startswith("last_room=2; path=/; expires=") and last_room.endswith("; samesite=lax"), headers
            assert re.search(r"expires=\w{3}, \d\d \w{3} \d{4} \d\d:\d\d:\d\d GMT", last_room)
            assert request("/", cookie=f"{admin}; last_room=2")[1]["location"] == f"{base}/rooms/2"
            assert request("/", cookie=f"{admin}; last_room=2abc")[1]["location"] == f"{base}/rooms/2"
            assert request("/", cookie=f"{member}; last_room=2")[1]["location"] == f"{base}/rooms/1"
            # A cached room page still sets the cookie.
            again = request("/rooms/2", cookie=admin)[1]
            assert cookie_named(again, "last_room").startswith("last_room=2;")
            # rooms#index: the user's last room by id.
            status, headers, _ = request("/rooms", cookie=admin)
            assert status == 302 and headers["location"] == f"{base}/rooms/2"
            assert request("/rooms", cookie=member)[1]["location"] == f"{base}/rooms/1"
            print("PASS: the root and rooms#index redirect as TrackedRoomVisit and Rails' rooms.last do; room pages set last_room")

            # set_room: a room the user isn't in goes back to the root with an alert the next page shows once.
            status, headers, _ = request("/rooms/2", cookie=member)
            flash = cookie_named(headers, "_campfire_session")
            assert status == 302 and headers["location"] == f"{base}/" and flash and cookie_named(headers, "last_room") is None, headers
            flash = flash.split(";", 1)[0]
            status, headers, _ = request("/", cookie=f"{member}; {flash}")
            assert status == 302 and cookie_named(headers, "_campfire_session") is None
            status, headers, body = request("/rooms/1", cookie=f"{member}; {flash}")
            assert status == 200 and "Room not found or inaccessible" in body and "--flash-background: var(--color-negative)" in body
            assert cookie_named(headers, "_campfire_session").startswith("_campfire_session=;")
            assert "Room not found or inaccessible" not in request("/rooms/1", cookie=member)[2]
            assert "Room not found or inaccessible" not in request("/rooms/1", cookie=f"{member}; _campfire_session=forged--00")[2]
            assert request("/rooms/abc", cookie=member)[0] == 302
            print("PASS: set_room redirects to the root with Rails' alert, kept until a page in the layout shows it")

            # Permalinks: the pages around the message, or the last page when it isn't one of the room's.
            target = messages[50]
            status, headers, body = request(f"/rooms/1/@{target}", cookie=member)
            assert status == 200 and ids(body) == messages[10:91], ids(body)
            assert cookie_named(headers, "last_room").startswith("last_room=1;")
            assert ids(request("/rooms/1/@abc", cookie=member)[2]) == messages[60:]
            assert ids(request(f"/rooms/1/@{target}xyz", cookie=member)[2]) == messages[10:91]
            assert request(f"/rooms/2/@{target}", cookie=admin)[0] == 200 and ids(request(f"/rooms/2/@{target}", cookie=admin)[2]) == []
            assert request(f"/rooms/2/@{target}", cookie=member)[0] == 302
            assert f'href="/rooms/1/@{target}"' in body
            print("PASS: /rooms/:id/@:message_id shows the pages around the message")

            # Paging: before, after, 204 at either end, 404 for a message not in the room.
            status, headers, body = request(f"/rooms/1/messages?before={messages[50]}", cookie=member)
            assert status == 200 and ids(body) == messages[10:50] and headers["content-type"] == "text/html; charset=utf-8"
            assert not body.lstrip().startswith("<!DOCTYPE")
            status, headers, body = request(f"/rooms/1/messages?after={messages[50]}", cookie=member)
            assert status == 200 and ids(body) == messages[51:91], ids(body)
            etag = headers["etag"]
            assert etag.startswith('W/"') and "last-modified" not in headers and headers["cache-control"] == "max-age=0, private, must-revalidate"
            assert ids(request(f"/rooms/1/messages?after={messages[50]}&before={messages[20]}", cookie=member)[2]) == messages[:20]
            assert ids(request("/rooms/1/messages?before=", cookie=member)[2]) == messages[60:]
            for path in (f"?after={messages[-1]}", f"?before={messages[0]}"):
                status, _, body = request(f"/rooms/1/messages{path}", cookie=member)
                assert status == 204 and body == "", (path, status)
            assert request("/rooms/1/messages?before=999999", cookie=member)[0] == 404
            assert request("/rooms/1/messages?after=abc", cookie=member)[0] == 404
            assert request("/rooms/2/messages", cookie=member)[0] == 404
            # fresh_when etag: the body's digest answers 304 while it holds; without a Last-Modified an
            # If-Modified-Since never holds, but Rack::ConditionalGet still honours a matching If-None-Match.
            path = f"/rooms/1/messages?after={messages[50]}"
            status, headers, body = request(path, cookie=member, headers={"If-None-Match": etag})
            assert status == 304 and body == "" and headers["etag"] == etag and "last-modified" not in headers
            assert request(path, cookie=member, headers={"If-Modified-Since": "Wed, 01 Jan 2031 00:00:00 GMT"})[0] == 200
            assert request(path, cookie=member, headers={"If-None-Match": 'W/"other"', "If-Modified-Since": "Wed, 01 Jan 2031 00:00:00 GMT"})[0] == 200
            assert request(path, cookie=member, headers={"If-None-Match": etag, "If-Modified-Since": "Mon, 01 Jan 2001 00:00:00 GMT"})[0] == 304
            cached = request(path, cookie=member)[1]
            assert cached["etag"] == etag and "last-modified" not in cached
            assert request(path, cookie=member, headers={"Accept": "application/json"})[0] == 406
            print("PASS: message paging before and after a message, 204 at either end, 404s, and fresh_when's ETag and 304, without Last-Modified")

            # Searching: the box posts, which records the sanitized query and redirects to it.
            status, headers, body = request("/searches", cookie=member)
            assert status == 200 and "searches__query" not in body and 'name="q"' in body and 'value=' not in body.split('name="q"')[0][-400:]
            assert 'href="/rooms/1"' in body
            status, headers, _ = request("/searches", {"q": "hello-world"}, member)
            assert status == 302 and headers["location"] == f"{base}/searches?q=hello+world", headers
            assert query("SELECT query FROM searches WHERE user_id=?", member_id) == [("hello world",)]
            status, _, body = request("/searches?q=hello-world", cookie=member)
            assert status == 200 and sorted(ids(body)) == messages[:2], ids(body)
            assert "“hello world”" in body and 'value="hello-world"' in body
            assert ids(request("/searches?q=caf%C3%A9", cookie=member)[2]) == [messages[2]]
            assert ids(request("/searches?q=under_score", cookie=member)[2]) == [messages[3]]
            assert ids(request("/searches?q=filler", cookie=member)[2]) == messages[4:]
            # Rails #304's last_page_of_matches: by the index's rowid (the id), not created_at.
            (stamp,), = query("SELECT created_at FROM messages WHERE id=?", messages[-1])
            execute("UPDATE messages SET created_at='2001-01-01 00:00:00.000000' WHERE id=?", messages[-1])
            assert ids(request("/searches?q=filler&order=rowid", cookie=member)[2]) == messages[4:]
            execute("UPDATE messages SET created_at=? WHERE id=?", stamp, messages[-1])
            # A blank query searches nothing and shows no query, but keeps the field's value.
            status, _, body = request("/searches?q=+-+", cookie=member)
            assert status == 200 and ids(body) == [] and "searches__query" not in body and 'value=" - "' in body
            assert request("/searches?q=AND", cookie=member)[0] == 500
            assert request("/searches", {"q": "AND"}, member)[0] == 500
            assert request("/searches", {"x": "1"}, member)[0] == 500
            assert request("/searches", {"q": "x"}, member, headers={"Sec-Fetch-Site": "cross-site"})[0] == 422
            # Recording touches an existing search and keeps the ten latest.
            for word in ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "hello world"]:
                assert request("/searches", {"q": word}, member)[0] == 302
            recent = [row[0] for row in query("SELECT query FROM searches WHERE user_id=? ORDER BY updated_at DESC", member_id)]
            assert recent == ["hello world", "j", "i", "h", "g", "f", "e", "d", "c", "b"], recent
            assert request("/searches", {"q": ""}, member)[1]["location"] == f"{base}/searches?q="
            assert query("SELECT count(*) FROM searches WHERE user_id=? AND query=''", member_id) == [(1,)]
            body = request("/searches", cookie=member)[2]
            assert body.count('href="/searches?q=hello+world"') == 2 and "Clear recent searches" in body
            assert request("/searches?q=hello", cookie=member, headers={"Accept": "application/json"})[0] == 406
            status, _, body = request("/searches?q=hello", cookie=member, headers={"Turbo-Frame": "results"})
            assert status == 200 and body.startswith("<html>") and 'id="search-results"' in body and "<nav" not in body
            print("PASS: searches record the sanitized query, keep ten, redirect to it, and show its results, as Rails does")

            # A deleted room: posting renders room_not_found; with no rooms left, the welcome page.
            status, headers, _ = request("/rooms/1", {"_method": "delete"}, admin)
            assert status == 302
            status, headers, body = request("/rooms/1/messages", {"message[body]": "late", "message[client_message_id]": "late-1"}, member,
                                            headers={"Accept": "text/vnd.turbo-stream.html, text/html"})
            assert status == 200 and headers["content-type"] == "text/html; charset=utf-8", (status, headers)
            assert "This room was deleted." in body and body.startswith("<!DOCTYPE html>") and 'id="composer-frame"' in body
            status, _, body = request("/", cookie=member)
            assert status == 200 and "<title>No rooms yet</title>" in body and 'class="sidebar' in body and "Bob Member" in body
            assert request("/rooms", cookie=member)[0] == 500
            assert request("/searches", cookie=member)[0] == 500
            print("PASS: posting to a deleted room renders room_not_found; the root shows the welcome page without rooms")
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
