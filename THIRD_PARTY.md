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

`qr.goose` ports rqrcode_core 2.1.0's QR encoder (MIT, copyright 2008 Duncan Robertson), the one
Rails' `QrCodeController` uses, so that join and transfer QR codes match Rails module for module.
Its license is in `licenses/rqrcode_core-LICENSE.txt`, and the image installs it under
`/usr/share/doc/once-campfire-goose/`.

The Linux image builds libvips 8.16.1 (LGPL-2.1-or-later) from its release tarball and links it
dynamically (`/usr/local/lib/libvips.so.42`) for image analysis and variants, with the Ubuntu
codec libraries it uses (libjpeg-turbo, libspng, libpng, libwebp, libtiff, libheif and its
libde265 and aom plugins, libexif, lcms2, cgif, libimagequant, highway, GLib, expat), whose
copyright notices their packages install under `/usr/share/doc/`.

The Linux image builds FFmpeg 7.1.5 (LGPL-2.1-or-later; configured without its GPL or nonfree
parts) from Debian's `ffmpeg_7.1.5-0+deb13u1` source package and runs its `ffmpeg` and `ffprobe`
executables, linked dynamically to its own libraries under `/usr/local/lib`, to analyze videos and
audio and draw video previews. Its license and Debian's copyright file are installed under
`/usr/local/share/doc/ffmpeg/`; it decodes AV1 with Ubuntu's dav1d (BSD-2-Clause), whose notice
`libdav1d7` installs under `/usr/share/doc/`.

`data/marcel.txt` holds the content type tables of Marcel 1.1.0 (MIT; its magic data derive
from Apache Tika, Apache-2.0, and freedesktop.org's shared-mime-info), converted by
`scripts/marcel_tables.py` from `crates/storage/src/tables.rs` of basecamp/once-campfire-rust
(MIT), which dumped them from the reference image's bundle.
