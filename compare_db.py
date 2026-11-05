"""Reads of an app's SQLite database for the comparison scripts.

A bind-mounted database can't be read from the host while the container runs: on Docker Desktop the WAL index
(-shm) isn't shared across the VM boundary, so committed rows can be missed. A read is instead made from a copy
of the database taken with `docker cp` (the .sqlite3 and its -wal), which SQLite opens by rebuilding the index.
"""
import sqlite3
import subprocess
import tempfile
from pathlib import Path


def exists(container):
    return subprocess.run(["docker", "inspect", container], capture_output=True).returncode == 0


def query(work, container, sql, *args):
    """Rows for `sql` from a consistent copy of the container's database, or from `work` once it's gone."""
    if not exists(container):
        with sqlite3.connect(Path(work) / "db/production.sqlite3", timeout=10) as db:
            return db.execute(sql, args).fetchall()
    with tempfile.TemporaryDirectory() as copy:
        subprocess.run(["docker", "cp", f"{container}:/rails/storage/db/.", copy], check=True, capture_output=True)
        (Path(copy) / "production.sqlite3-shm").unlink(missing_ok=True)  # A copied index can't be trusted.
        db = sqlite3.connect(Path(copy) / "production.sqlite3", timeout=10)
        try: return db.execute(sql, args).fetchall()
        finally: db.close()


def one(work, container, sql, *args):
    """The only row's first column; a missing row is an error, not None."""
    rows = query(work, container, sql, *args)
    if not rows: raise LookupError(f"no row for {sql!r} {args!r}")
    return rows[0][0]
