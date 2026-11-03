#!/usr/bin/env python3
"""Run the pinned, unmodified shared Chromium smoke test against the production image."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import uuid

REVISION = "ec02debb3e44f40b8778a6a42db3c4515b2f9eaf"
PLAYWRIGHT = "mcr.microsoft.com/playwright:v1.63.0-noble@sha256:eff16c30e6f3f4af0a03fa4b706120d5e9b0891c344a27d64559aff5900a4a27"


def run(*command, **kwargs):
    return subprocess.run([str(value) for value in command], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", nargs="?", default="once-campfire-goose:app")
    parser.add_argument("--verification", type=Path)
    parser.add_argument("--output", type=Path, default=Path("build/browser-production"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    name = "campfire-browser-" + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix="campfire-browser-") as temporary:
        work = Path(temporary)
        os.chmod(work, 0o755)
        verification = args.verification.resolve() if args.verification else work / "verification"
        if not args.verification:
            run("git", "init", verification, stdout=subprocess.DEVNULL)
            run("git", "-C", verification, "fetch", "--depth=1", "https://github.com/basecamp/once-campfire-verification.git", REVISION)
            run("git", "-C", verification, "checkout", "--detach", "FETCH_HEAD", stdout=subprocess.DEVNULL)
        git = ["git", "-c", f"safe.directory={verification}", "-c", "core.autocrlf=true", "-c", "core.filemode=false", "-C", verification]
        assert run(*git, "rev-parse", "HEAD", capture_output=True, text=True).stdout.strip() == REVISION
        assert not run(*git, "status", "--porcelain", "--untracked-files=no", capture_output=True, text=True).stdout.strip()
        context = work / "browser"
        context.mkdir()
        hashes = {}
        for file in ("package.json", "package-lock.json", "smoke.mjs"):
            source = verification / "browser" / file if file == "smoke.mjs" else verification / file
            shutil.copyfile(source, context / file)
            hashes[file] = hashlib.sha256(source.read_bytes()).hexdigest()
        (context / "Dockerfile").write_text(f"FROM {PLAYWRIGHT}\nWORKDIR /tests\nCOPY package*.json ./\nRUN npm ci\nCOPY smoke.mjs ./\nENTRYPOINT [\"node\", \"smoke.mjs\"]\n")
        image = "once-campfire-goose:shared-browser"
        with (args.output / "build.log").open("w") as log:
            run("docker", "build", "-t", image, context, stdout=log, stderr=subprocess.STDOUT)
        with socket.socket() as available:
            available.bind(("127.0.0.1", 0))
            port = available.getsockname()[1]
        environment = work / "server.env"
        environment.write_text(f"HTTP_PORT={port}\nSECRET_KEY_BASE={secrets.token_hex(64)}\nDISABLE_SSL=true\n")
        os.chmod(environment, 0o600)
        launch = ["docker", "run", "-d", "--name", name, "--network", "host", "--env-file", environment]
        for folder in ("db", "files", "logs"):
            (work / folder).mkdir()
            os.chmod(work / folder, 0o777)
            launch += ["-v", f"{work / folder}:/rails/storage/{folder}"]
        try:
            run(*launch, args.image, stdout=subprocess.DEVNULL)
            with (args.output / "smoke.log").open("w") as log:
                smoke = subprocess.run(["docker", "run", "--rm", "--network", "host", image, "--base", f"http://127.0.0.1:{port}"], stdout=log, stderr=subprocess.STDOUT)
            if smoke.returncode != 0:
                print((args.output / "smoke.log").read_text())
                raise SystemExit(f"browser smoke failed with exit status {smoke.returncode}")
            inspected = json.loads(run("docker", "image", "inspect", args.image, capture_output=True, text=True).stdout)[0]
            (args.output / "receipt.json").write_text(json.dumps({"passed": True, "verification_revision": REVISION,
                "playwright_image": PLAYWRIGHT, "files_sha256": hashes, "application_image": inspected["Id"],
                "application_revision": inspected["Config"]["Labels"].get("org.opencontainers.image.revision")}, indent=2) + "\n")
            print((args.output / "smoke.log").read_text())
        finally:
            with (args.output / "server.log").open("w") as log:
                subprocess.run(["docker", "logs", name], stdout=log, stderr=subprocess.STDOUT, check=False)
            subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            # The image's user owns what it wrote; on Linux the runner can't delete that until the image opens it up.
            subprocess.run(["docker", "run", "--rm", "-v", f"{work}:/w", "--entrypoint", "find", args.image, "/w/db", "/w/files", "/w/logs",
                "-mindepth", "1", "-user", "1000", "-exec", "chmod", "a+rwX", "{}", "+"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


if __name__ == "__main__":
    main()
