#!/usr/bin/env python3
"""Fresh installation, concurrent setup, invitations and bcrypt/session persistence, and the schema:
Rails main's on a fresh database, and its migrations and messages_count repair on a 90b3300 one."""
import concurrent.futures
import http.client
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlencode

binary=Path(sys.argv[1]).resolve()
root=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="campfire-setup-") as directory:
    work=Path(directory)
    database=work/"production.sqlite3"
    with socket.socket() as probe:
        probe.bind(("127.0.0.1",0));port=probe.getsockname()[1]
    secret=secrets.token_hex(64)
    env=dict(os.environ,DATABASE_PATH=str(database),SECRET_KEY_BASE=secret,HTTP_PORT=str(port))
    with (work/"server.log").open("w+") as log:
        server=subprocess.Popen([str(binary)],env=env,stdout=log,stderr=log)
        def request(path,fields=None,cookie="",origin=None):
            connection=http.client.HTTPConnection("127.0.0.1",port,timeout=10)
            headers={"Content-Type":"application/x-www-form-urlencoded","Sec-Fetch-Site":"same-origin"}
            if cookie: headers["Cookie"]=cookie
            if origin: headers["Origin"]=origin
            connection.request("GET" if fields is None else "POST",path,None if fields is None else urlencode(fields),headers)
            response=connection.getresponse()
            result=response.status,dict(response.getheaders()),response.read().decode()
            connection.close();return result
        try:
            for _ in range(200):
                if server.poll() is not None: raise AssertionError("server exited during setup")
                try:
                    if request("/up")[0]==200:break
                except ConnectionRefusedError: time.sleep(.05)
            else: raise AssertionError("server did not start")
            base=f"http://127.0.0.1:{port}"
            status,headers,_=request("/")
            assert status==302 and headers["Location"]==base+"/session/new"
            status,headers,_=request("/session/new")
            assert status==302 and headers["Location"]==base+"/first_run"
            assert 'name="user[name]"' in request("/first_run")[2]
            fields={"user[name]":"First Admin","user[email_address]":"admin@example.test","user[password]":"setup password"}
            assert request("/first_run",fields,origin="https://foreign.test")[0]==422
            assert request("/first_run",{"other":"incomplete"})[0]==400
            with sqlite3.connect(database) as db: assert db.execute("SELECT count(*) FROM accounts").fetchone()[0]==0
            def setup(i):
                return i,request("/first_run",dict(fields,**{"user[email_address]":f"admin{i}@example.test"}))
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(setup,range(2)))
            assert sorted(result[0] for _,result in results)==[302,302],[(i,r[0]) for i,r in results]
            assert [result[1]["Location"] for _,result in results]==[base+"/"]*2
            winner,(status,headers,_)=next((i,r) for i,r in results if "Set-Cookie" in r[1])
            cookie=headers["Set-Cookie"].split(";",1)[0]
            status,_,page=request("/rooms/1",cookie=cookie)
            assert status==200 and "Write a message" in page and "All Talk" in page
            with sqlite3.connect(database) as db:
                assert db.execute("SELECT count(*) FROM accounts").fetchone()[0]==1
                assert db.execute("SELECT count(*) FROM users WHERE role=1").fetchone()[0]==1
                assert db.execute("SELECT count(*) FROM memberships").fetchone()[0]==1
                assert db.execute("SELECT password_digest FROM users").fetchone()[0].startswith("$2b$12$")
                invitation=db.execute("SELECT join_code FROM accounts").fetchone()[0]
            assert request("/first_run",fields)[0]==302
            assert request("/join/invalid")[0]==404
            assert request("/join/"+invitation)[0]==200
            member={"user[name]":"Member","user[email_address]":"member@example.test","user[password]":"member password"}
            status,headers,_=request("/join/"+invitation,member)
            assert status==302
            member_cookie=headers["Set-Cookie"].split(";",1)[0]
            assert request("/rooms/1",cookie=member_cookie)[0]==200
            status,headers,_=request("/join/"+invitation,member)
            assert status==302 and headers["Location"]==base+"/session/new?email_address=member%40example.test"
            with sqlite3.connect(database) as db:
                assert db.execute("SELECT count(*) FROM users").fetchone()[0]==2
                assert db.execute("SELECT role FROM users WHERE email_address='member@example.test'").fetchone()[0]==0
                assert db.execute("SELECT count(*) FROM memberships").fetchone()[0]==2
            assert request("/session",{"email_address":f"admin{winner}@example.test","password":"setup password"})[0]==302
            assert request("/session",{"email_address":f"admin{winner}@example.test","password":"wrong"})[0]==401
            print("PASS: fresh schema, atomic concurrent setup, signed sessions, bcrypt login, invitation membership, duplicate rollback and origin checks")
        except BaseException:
            log.seek(0);print(log.read(),file=sys.stderr);raise
        finally:
            server.terminate()
            try:server.wait(timeout=5)
            except subprocess.TimeoutExpired:server.kill();server.wait()

MAIN_VERSIONS=["20261004225000","20261005022000","20261007190000"]
TRIGGERS=["messages_ai_rooms_messages_count","messages_ad_rooms_messages_count","messages_au_rooms_messages_count"]
NOW="2026-03-02 16:00:00"

def master(database):
    """sqlite_master, minus what SQLite derives."""
    with sqlite3.connect(database) as db:
        return [row for row in db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY rowid")
                if row[3] is not None and row[1]!="sqlite_sequence" and not row[1].startswith("message_search_index_")]

def versions(database):
    with sqlite3.connect(database) as db: return [v for v, in db.execute("SELECT version FROM schema_migrations ORDER BY rowid")]

def metadata(database):
    with sqlite3.connect(database) as db: return dict(db.execute("SELECT key,value FROM ar_internal_metadata"))

def counts(database):
    with sqlite3.connect(database) as db:
        return db.execute("SELECT id,messages_count,(SELECT count(*) FROM messages m WHERE m.room_id=rooms.id) FROM rooms ORDER BY id").fetchall()

def boot(database,work,ready=True):
    """Runs the server on database until /up answers, or until it exits, and returns its log."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1",0));port=probe.getsockname()[1]
    env=dict(os.environ,DATABASE_PATH=str(database),SECRET_KEY_BASE=secrets.token_hex(64),HTTP_PORT=str(port))
    with (work/"boot.log").open("w+") as log:
        server=subprocess.Popen([str(binary)],env=env,stdout=log,stderr=log,cwd=root)
        try:
            for _ in range(400):
                if server.poll() is not None: break
                try:
                    connection=http.client.HTTPConnection("127.0.0.1",port,timeout=10);connection.request("GET","/up")
                    if connection.getresponse().status==200: break
                except ConnectionRefusedError: time.sleep(.05)
            else: raise AssertionError("server did not start")
            started=server.poll() is None
        finally:
            server.terminate()
            try:server.wait(timeout=5)
            except subprocess.TimeoutExpired:server.kill();server.wait()
        log.seek(0);text=log.read()
    assert started==ready,text
    return text

def seed_90b3300(database,recorded=True):
    """A database as Rails at 90b3300 leaves it (data/test-schema-90b3300.sql, or without its rows as an
    earlier Goose made it), with rooms of 5, 0 and 12 messages."""
    schema=(root/"data/test-schema-90b3300.sql").read_text()
    if not recorded: schema="\n".join(line for line in schema.splitlines() if not line.startswith("INSERT INTO"))
    with sqlite3.connect(database) as db:
        db.executescript(schema)
        db.execute("INSERT INTO users(name,role,created_at,updated_at) VALUES('Seed',1,?,?)",(NOW,NOW))
        for room,n in ((1,5),(2,0),(3,12)):
            db.execute("INSERT INTO rooms(id,name,type,creator_id,created_at,updated_at) VALUES(?,?,'Rooms::Open',1,?,?)",(room,f"Room {room}",NOW,NOW))
            for i in range(n): db.execute("INSERT INTO messages(room_id,creator_id,client_message_id,created_at,updated_at) VALUES(?,1,?,?,?)",(room,f"seed-{room}-{i}",NOW,NOW))

with tempfile.TemporaryDirectory(prefix="campfire-schema-") as directory:
    work=Path(directory)
    # A fresh database has Rails main's schema, recorded as its db:schema:load records it, with the
    # triggers Room::MessagesCount.ensure! then installs.
    fresh=work/"fresh.sqlite3"
    boot(fresh,work)
    fresh_master=master(fresh)
    by_name={row[1]:row for row in fresh_master}
    assert [row[1] for row in fresh_master if row[0]=="trigger"]==TRIGGERS and fresh_master[-3:]==[by_name[t] for t in TRIGGERS],fresh_master
    assert by_name["rooms"][3].endswith('"updated_at" datetime(6) NOT NULL, "messages_count" integer DEFAULT 0 NOT NULL)'),by_name["rooms"]
    all_versions=sorted(versions(fresh))
    assert len(all_versions)==18 and all_versions[-3:]==MAIN_VERSIONS,all_versions
    assert versions(fresh)==[MAIN_VERSIONS[-1]]+all_versions[:-1],versions(fresh)
    assert metadata(fresh)=={"environment":"production","schema_sha1":"aff2a42b1a9c498adc4eddf775976f2f09ecdedd"},metadata(fresh)
    # The triggers count inserts, deletes and moves.
    with sqlite3.connect(fresh) as db:
        db.execute("INSERT INTO users(name,created_at,updated_at) VALUES('U',?,?)",(NOW,NOW))
        for room in (1,2): db.execute("INSERT INTO rooms(id,type,creator_id,created_at,updated_at) VALUES(?,'Rooms::Open',1,?,?)",(room,NOW,NOW))
        for i in range(3): db.execute("INSERT INTO messages(room_id,creator_id,client_message_id,created_at,updated_at) VALUES(1,1,?,?,?)",(f"m{i}",NOW,NOW))
        db.execute("UPDATE messages SET room_id=2 WHERE id=1")
        db.execute("UPDATE messages SET room_id=2 WHERE id=1")
        db.execute("DELETE FROM messages WHERE id=2")
    assert counts(fresh)==[(1,1,1),(2,1,1)],counts(fresh)
    log=boot(fresh,work)
    assert master(fresh)==fresh_master and "Database:" not in log,log

    # A 90b3300 database runs Rails main's migrations as its db:prepare does: rooms gains the column in
    # place, the indexes and triggers follow every older object, and each room's messages are counted.
    seeded=work/"seeded.sqlite3"
    seed_90b3300(seeded)
    seeded_master,seeded_versions=master(seeded),versions(seeded)
    assert seeded_versions==sorted(seeded_versions,reverse=True)==sorted(all_versions[:15],reverse=True)
    log=boot(seeded,work)
    assert all(f"Database: migrated {v}" in log for v in MAIN_VERSIONS),log
    added=["index_messages_on_room_id_and_created_at","index_messages_on_room_id_and_updated_at",*TRIGGERS]
    assert master(seeded)==[by_name["rooms"] if row[1]=="rooms" else row for row in seeded_master]+[by_name[n] for n in added],master(seeded)
    assert versions(seeded)==seeded_versions+MAIN_VERSIONS,versions(seeded)
    assert metadata(seeded)=={"environment":"production","schema_sha1":"f75da8dad38bfb179ffd757bd7a7c2b3f818bc29"},metadata(seeded)
    assert counts(seeded)==[(1,5,5),(2,0,0),(3,12,12)],counts(seeded)
    migrated_master=master(seeded)
    log=boot(seeded,work)
    assert master(seeded)==migrated_master and "Database:" not in log,log

    # Room::MessagesCount.ensure!: a database that lost a trigger is recounted and gets all three back.
    with sqlite3.connect(seeded) as db:
        db.execute("DROP TRIGGER messages_ad_rooms_messages_count")
        db.execute("DELETE FROM messages WHERE room_id=3 AND id%2=0")
        db.execute("UPDATE rooms SET messages_count=99 WHERE id=1")
    boot(seeded,work)
    assert sorted(master(seeded))==sorted(migrated_master),master(seeded)
    assert counts(seeded)==[(1,5,5),(2,0,0),(3,6,6)],counts(seeded)

    # An earlier Goose loaded 90b3300's schema without recording its migrations.
    legacy=work/"legacy.sqlite3"
    seed_90b3300(legacy,recorded=False)
    log=boot(legacy,work)
    assert "recorded 90b3300's migrations" in log,log
    assert versions(legacy)==seeded_versions+MAIN_VERSIONS,versions(legacy)
    assert metadata(legacy)["schema_sha1"]=="f75da8dad38bfb179ffd757bd7a7c2b3f818bc29"
    assert master(legacy)==migrated_master and counts(legacy)==[(1,5,5),(2,0,0),(3,12,12)]

    # A database from before 90b3300 is left for the Rails image to migrate.
    old=work/"old.sqlite3"
    seed_90b3300(old)
    with sqlite3.connect(old) as db: db.execute("DELETE FROM schema_migrations WHERE version IN ('20251212154340','20251126130131')")
    before=master(old)
    log=boot(old,work,ready=False)
    assert "pending migrations from before 90b3300 (boot the Rails image on this database once): 20251126130131, 20251212154340" in log,log
    assert master(old)==before and len(versions(old))==13
    print("PASS: Rails main's schema on a fresh database, a 90b3300 one migrated with its counts, trigger repair, and earlier databases recorded or refused")
