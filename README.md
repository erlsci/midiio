# midiio

[![Build Status][gh-actions-badge]][gh-actions]
[![Erlang Versions][erlang-badge]][versions]
[![Tag][github-tag-badge]][github-tag]

[![Project Logo][logo]][logo-large]

*Cross-platform realtime MIDI I/O for the BEAM*

`midiio` is an Erlang NIF over the single-header
[minimidio](https://github.com/octetta/minimidio) C library. It is the
**transport layer**: it discovers MIDI devices and moves raw MIDI bytes to and
from the operating system's MIDI ports (CoreMIDI on macOS, WinMM on Windows,
ALSA sequencer on Linux, Web MIDI under Emscripten) in real time.

It is deliberately **codec-free**. `midiio` has no opinion about what the bytes
mean and does not depend on `midilib` — if you want raw realtime MIDI in the
BEAM and bring your own message representation, this is all you need. If you
want messages encoded/decoded for you and Standard MIDI File support, use the
[`midi`](https://github.com/erlsci/midi) umbrella instead.

## Where it sits

```
minimidio.h ─► midiio  (transport: raw bytes ⇄ OS ports)     midilib  (codec + .mid files, pure Erlang)
                            └────────────────┬────────────────────┘
                                          midi  (one batteries-included API)
```

| Library | Layer | Native build? |
|---------|-------|---------------|
| [midilib](https://github.com/erlsci/midilib) | message codec + Standard MIDI File read/write | no (pure Erlang) |
| **midiio** | realtime device I/O (NIF) | yes (vendors minimidio) |
| [midi](https://github.com/erlsci/midi) | the whole enchilada: codec + I/O behind one API | yes (via midiio) |

## Status

Early placeholder — `0.0.1`. The NIF, build wiring, and public API are under
active development; the API will change. Published to Hex to reserve the name.

## Build

    rebar3 compile

## Updating the vendored minimidio

`midiio` **vendors** (does not fork) the single-header
[minimidio](https://github.com/octetta/minimidio) library — MIT, © Joseph
Stewart / `octetta`. The copy is pinned to an exact upstream commit and lives in:

| File | Role |
|------|------|
| `c_src/minimidio.h` | the vendored header that gets compiled into the NIF |
| `c_src/minimidio.LICENSE` | upstream's MIT license text (kept per MIT's notice requirement) |
| `c_src/minimidio.lock` | provenance manifest: commit SHA, version, date, sha256, author |

minimidio publishes **no git tags or releases**, so the deterministic pin is the
**commit SHA**. The version string (e.g. `v0.5.0-dev`) is recorded for humans but
is not a reliable handle.

**See the current pin:**

    cat c_src/minimidio.lock

**Bump or roll back** — find the commit you want on
[GitHub](https://github.com/octetta/minimidio/commits/main) and pass its SHA
(rollbacks work the same way; just pick an older commit):

    make vendor-minimidio SHA=<commit-sha>      # pin an exact commit
    make vendor-minimidio REF=main              # pull the latest main, then pin its SHA

This fetches `minimidio.h` + `LICENSE` at that commit, updates the lock, and makes
**two commits**:

1. **Commit A** — `minimidio.h` + `minimidio.LICENSE`, authored as the *upstream*
   developer (read from the pinned commit). This keeps `git blame`/`git log`
   correctly attributing the C code to its creator, not to us.
2. **Commit B** — `minimidio.lock`, authored by you (our metadata, not theirs).

**Preview without committing** — write the files and print the commit commands:

    make vendor-minimidio SHA=<commit-sha> NO_COMMIT=1

**Verify integrity** — fail if the in-tree header has drifted from the lock
(re-hashes `c_src/minimidio.h`; offline; also runs in CI):

    make minimidio-verify

Re-pinning the commit already in the lock is a no-op. The tooling is
`scripts/vendor-minimidio.sh` (POSIX `sh`; needs `curl`, `git`, and a sha256 tool);
`scripts/test-vendor-minimidio.sh` runs its offline unit tests.

[//]: ---Named-Links---

[logo]: priv/images/logo-250px.png
[logo-large]: priv/images/logo-2000px.png
[gh-actions-badge]: https://github.com/erlsci/midiio/workflows/ci/badge.svg
[gh-actions]: https://github.com/erlsci/midiio/actions
[erlang-badge]: https://img.shields.io/badge/erlang-22%20to%2029-blue.svg
[versions]: https://github.com/erlsci/midiio/blob/master/.github/workflows/cicd.yml
[github-tag]: https://github.com/erlsci/midiio/tags
[github-tag-badge]: https://img.shields.io/github/tag/erlsci/midiio.svg
