# Dependency patches

The application applies no patches. Every dependency in
[`dependencies.json`](../dependencies.json) is an unpatched tag of its upstream repository,
among them goose-http `v0.5.18` (`86fdeec31d911d4394d797a397660d6fed96ae5d`), and bootstrap
verifies each pinned revision and rejects tracked modifications. A dependency entry can still
name a patch file here with its SHA-256 and resulting tree, which bootstrap checks before
building.

Earlier pins and patches, kept in Git history:

- The fan-out work once pinned on goose-http's `campfire-fanout` branch (`v0.5.11-campfire.3`)
  was merged upstream in `v0.5.14`.
- The worker-dispatch patch was dropped: it measured no faster than the existing pipeline
  ([report](../docs/worker-dispatch.md)).
- The send-copy patch ([goose-http PR #3](https://github.com/kaitk/goose-http/pull/3)) was retired
  on 2026-10-23 after the maintainer measured a 13–28% loss when the server is the bottleneck
  ([report](../docs/send-copy-pr.md)).

Comparisons in older reports describe the builds they name, some of them patched.
