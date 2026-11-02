# Third-party source

The schema in `data/schema.sql`, templates under `views/templates`, and frontend files under `assets/reference` come from
37signals' Campfire and its Rust rewrite at revision `6dae2fd3c1a2dce61ca11beb731bcce2b42b67ad`.
They retain the [MIT license](views/MIT-LICENSE) and any license notices embedded in files.
Template provenance and hashes are in `views/source.json`; asset hashes are in `views/assets.json`.

Goose and the Goose HTTP/hash/compression/TLS/SQLite packages are fetched separately at the
revisions in `dependencies.json`; their original license files remain in their checkouts.
goose-tls links OpenSSL 3 (Apache-2.0), which the Linux image installs as `libssl3t64` for
HTTPS bot webhooks; its notices are under `/usr/share/doc/libssl3t64/`.
SQLite is prepared with FTS5 enabled and the WAL observation shim in `sqlite_wal.c` appended.
`prepare.py` accepts only the pinned original files or that exact patch.

The Linux image uses libqrencode (LGPL-2.1-or-later) to encode session-transfer
URLs. Its Debian package installs its copyright and license notices under
`/usr/share/doc/libqrencode4/`; the Goose application renders the resulting matrix as SVG.
