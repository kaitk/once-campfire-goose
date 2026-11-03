#!/usr/bin/env python3
"""Smoke-test the actual production image with fresh, disposable Linux storage."""
import argparse
import hashlib
import http.client
import json
import os
import re
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
    env.write_text(f"SECRET_KEY_BASE={secrets.token_hex(64)}\nHTTP_PORT={port}\nDISABLE_SSL=true\n")
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
        assert status==302
        cookie=headers["Set-Cookie"].split(";",1)[0]
        room_path="/"+headers["Location"].split("//",1)[-1].split("/",1)[1] if "//" in headers["Location"] else headers["Location"]
        status,_,body=request("/rooms/1",cookie=cookie)
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
        # libvips loads and makes variants with the image's own libraries: a PNG thumbnail and a WebP avatar.
        def post_file(path,field,filename,data,extra=(),kind="image/png"):
            boundary="----image"+secrets.token_hex(8)
            body=b"".join(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode() for k,v in extra)
            body+=f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"; filename=\"{filename}\"\r\nContent-Type: {kind}\r\n\r\n".encode()+data+f"\r\n--{boundary}--\r\n".encode()
            client=http.client.HTTPConnection("127.0.0.1",port,timeout=30)
            client.request("POST",path,body,{"Content-Type":f"multipart/form-data; boundary={boundary}","Sec-Fetch-Site":"same-origin","Cookie":cookie})
            response=client.getresponse();result=response.status,dict(response.getheaders()),response.read();client.close();return result
        def local(location):return location.split(f"127.0.0.1:{port}",1)[-1]
        icon=logo.read_bytes()
        status,_,body=post_file(f"{room_path}/messages","message[attachment]","icon.png",icon,[("message[client_message_id]","image-test")])
        assert status==200 and b"message__attachment" in body,(status,body[:300])
        thumb=re.search(rb'class="message__attachment" loading="lazy" src="([^"]+)"',body)[1].decode().replace("&amp;","&")
        status,headers,_=request(thumb,cookie=cookie)
        assert status==302,status
        status,headers,variant=request(local(headers["Location"]))
        assert status==200 and headers["Content-Type"]=="image/png" and variant.startswith(b"\x89PNG"),(status,headers)
        status,_,_=post_file("/users/me/profile","user[avatar]","me.png",icon,[("_method","patch")])
        assert status in (302,303),status
        avatar=re.search(rb'src="(/users/[^"]+/avatar)"',request("/users/me/profile",cookie=cookie)[2])[1].decode()
        status,headers,image=request(avatar,cookie=cookie)
        assert status==200 and headers["Content-Type"]=="image/webp" and image[8:12]==b"WEBP",(status,headers)
        print("PASS: an attachment's PNG thumbnail and an avatar's WebP variant are made by the image's libvips")
        # ffprobe and ffmpeg run in the image as its user: a 16:9 MJPEG AVI (frames from the image's own
        # ffmpeg) is analyzed before its post is answered, and its poster drawn and made a WebP.
        from test_uploads import avi,jpeg
        encoder=("docker","run","--rm","-i","--entrypoint","ffmpeg",args.image)
        clip=avi(64,48,[jpeg(64,48,40*i,aspect=(4,3),ffmpeg=encoder) for i in range(3)])
        status,_,body=post_file(f"{room_path}/messages","message[attachment]","clip.avi",clip,[("message[client_message_id]","video-test")],"video/x-msvideo")
        assert status==200 and b'style="width: 32.0px; aspect-ratio: 1.7777777777777777;"><video ' in body,(status,body[:300])
        poster=re.search(rb'<video [^>]*poster="([^"]+)"',body)[1].decode().replace("&amp;","&")
        status,headers,_=request(poster,cookie=cookie)
        assert status==302,status
        status,headers,image=request(local(headers["Location"]))
        assert status==200 and headers["Content-Type"]=="image/webp" and image[8:12]==b"WEBP",(status,headers)
        logs=subprocess.run(["docker","logs",name],capture_output=True,text=True)
        assert "Video previews: on\n" in logs.stdout+logs.stderr
        print("PASS: a video is analyzed by the image's ffprobe, and its poster drawn by its ffmpeg")
    except BaseException:
        subprocess.run(["docker","logs",name],check=False)
        raise
    finally:
        subprocess.run(["docker","rm","-f",name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False)
        # The image's user owns what it wrote; on Linux the runner can't delete that until the image opens it up.
        subprocess.run(["docker","run","--rm","-v",f"{work}:/w","--entrypoint","find",args.image,"/w/db","/w/files","/w/logs",
            "-mindepth","1","-user","1000","-exec","chmod","a+rwX","{}","+"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False)
