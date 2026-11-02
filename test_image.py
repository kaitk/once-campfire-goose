#!/usr/bin/env python3
"""Smoke-test the actual production image with fresh, disposable Linux storage."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
from urllib.parse import urlencode
import uuid

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("image",nargs="?",default="once-campfire-goose:app")
args=parser.parse_args()
root=Path(__file__).resolve().parent
name="campfire-image-test-"+uuid.uuid4().hex[:12]
with tempfile.TemporaryDirectory(prefix="campfire-image-") as temporary:
    work=Path(temporary)
    os.chmod(work,0o755)
    for folder in ("db","files","logs"):
        (work/folder).mkdir();os.chmod(work/folder,0o777)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1",0));port=probe.getsockname()[1]
    env=work/"server.env"
    env.write_text(f"SECRET_KEY_BASE={secrets.token_hex(64)}\nHTTP_PORT={port}\n")
    os.chmod(env,0o600)
    command=["docker","run","-d","--name",name,"--network","host","--env-file",str(env)]
    for folder in ("db","files","logs"):command += ["-v",f"{work/folder}:/rails/storage/{folder}"]
    try:
        subprocess.run(command+[args.image],check=True,stdout=subprocess.DEVNULL)
        def request(path,fields=None,cookie=""):
            client=http.client.HTTPConnection("127.0.0.1",port,timeout=10)
            headers={"Content-Type":"application/x-www-form-urlencoded","Sec-Fetch-Site":"same-origin","Cookie":cookie}
            client.request("GET" if fields is None else "POST",path,None if fields is None else urlencode(fields),headers)
            response=client.getresponse();result=response.status,dict(response.getheaders()),response.read();client.close();return result
        for _ in range(200):
            try:
                if request("/up")[0]==200:break
            except (OSError,http.client.HTTPException):pass
            time.sleep(.05)
        else:raise AssertionError("image did not become ready")
        assert request("/first_run")[0]==200
        status,headers,_=request("/first_run",{"user[name]":"Image Test","user[email_address]":"image@example.test","user[password]":"disposable test password"})
        assert status==303
        cookie=headers["Set-Cookie"].split(";",1)[0]
        status,_,body=request(headers["Location"],cookie=cookie)
        assert status==200 and b"Write a message" in body
        manifest=json.loads((root/"views/assets.json").read_text())
        asset=next(iter(manifest.values()))
        status,headers,body=request("/assets/"+asset["path"])
        assert status==200 and hashlib.sha256(body).hexdigest()==asset["sha256"]
        assert headers["Content-Type"]==asset["content_type"]
        assert (work/"db/production.sqlite3").is_file()
        logo=root/"assets/reference"/manifest["logos/app-icon.png"]["path"]
        status,headers,body=request("/account/logo")
        assert status==200 and headers["Content-Type"]=="image/png" and body==logo.read_bytes()
        status,headers,body=request("/webmanifest.json")
        assert status==200 and json.loads(body)["name"]=="Campfire"
        print("PASS: production image, HTTP_PORT, fresh storage, setup/login cookie, room rendering, vendored asset, stock logo and manifest")
    except BaseException:
        subprocess.run(["docker","logs",name],check=False)
        raise
    finally:
        subprocess.run(["docker","rm","-f",name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False)
