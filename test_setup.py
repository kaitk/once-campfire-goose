#!/usr/bin/env python3
"""Fresh installation, concurrent setup, invitations and bcrypt/session persistence."""
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
