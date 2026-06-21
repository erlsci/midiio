# midiio

[![Build Status][gh-actions-badge]][gh-actions]
[![Erlang Versions][erlang-badge]][versions]
[![Tag][github-tag-badge]][github-tag]

[![Project Logo][logo]][logo-large]

*Cross-platform realtime MIDI I/O for the BEAM*

`midiio` is an Erlang NIF over the single-header
[minimidio](https://github.com/octetta/minimidio) C library. It is the
**transport layer**: it discovers MIDI devices and moves raw MIDI bytes to and
from the operating system's MIDI ports in real time. v0.1.0 is built and tested on
**CoreMIDI** (macOS) and the **ALSA sequencer** (Linux); minimidio's **WinMM**
(Windows) and **Web MIDI** (Emscripten) backends are on the roadmap but not yet
exercised by `midiio`.

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

**`0.1.0`** — the MIDI 1.0 transport layer is complete and tested: device
discovery, output (open / `send` / close, including SysEx), and inbound (open /
start / stop / close with per-process ownership), byte-exact with no
normalization. Built and tested on macOS (CoreMIDI) and Linux (ALSA), OTP 24–29.

See [minimidio API coverage](docs/minimidio-api-coverage.md) for exactly what is
covered and what is deferred (UMP / MIDI 2.0, MTC helpers, WinMM / Web MIDI).

The next milestone (v0.2.0) swaps the interim send/recv adapter for minimidio's
native raw-bytes API — merged upstream from midiio's own proposal — with no change
to the Erlang API above the seam.

## Build

`midiio` builds a NIF, so it needs a C toolchain. On Linux you also need the ALSA
sequencer development headers:

    # Debian/Ubuntu
    sudo apt-get install libasound2-dev

Then build, and (optionally) run the full gate — eunit + PropEr + dialyzer + xref,
plus the AddressSanitizer lifecycle harness:

    rebar3 compile
    rebar3 as test check
    make asan

## Usage

`midiio` deals in **raw MIDI bytes** — you bring the message representation. A
status-complete message goes out as a binary; inbound messages arrive as
`{midi_in, Device, Bytes, TimestampNanos}` to the owning process.

### Discover devices

```erlang
{ok, Ctx} = midiio:context_open(),
Outputs = midiio:list_outputs(Ctx),   %% [{Index, Name}], e.g. [{0, <<"IAC Driver Bus 1">>}]
Inputs  = midiio:list_inputs(Ctx),    %% same shape
#{backend := Backend} = midiio:caps(Ctx),
ok = midiio:context_close(Ctx).
```

### Play a note

```erlang
{ok, Ctx} = midiio:context_open(),
[{Idx, _Name} | _] = midiio:list_outputs(Ctx),
ok = midiio:context_close(Ctx),

{ok, Out} = midiio:open_output(Idx),
ok = midiio:send(Out, <<16#90, 60, 100>>),   %% note-on:  middle C (60), velocity 100
timer:sleep(500),
ok = midiio:send(Out, <<16#80, 60, 0>>),      %% note-off: middle C
ok = midiio:close(Out).
```

### Receive inbound MIDI

```erlang
{ok, Ctx} = midiio:context_open(),
[{Idx, _Name} | _] = midiio:list_inputs(Ctx),
ok = midiio:context_close(Ctx),

{ok, In} = midiio:open_input(Idx, self()),   %% deliver to this process
ok = midiio:start_input(In),
receive
    {midi_in, In, Bytes, TsNanos} ->
        io:format("MIDI in: ~p at ~p ns~n", [Bytes, TsNanos])
after 5000 ->
    io:format("(no MIDI received)~n")
end,
ok = midiio:stop_input(In),
ok = midiio:close(In).
```

`send/2` takes one complete message and routes channel / system / SysEx
internally; it does **not** normalize (a note-on with velocity 0 stays a note-on).
SysEx is just a binary that starts with `16#F0` and ends with `16#F7`.

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
[erlang-badge]: https://img.shields.io/badge/erlang-24%20to%2029-blue.svg
[versions]: https://github.com/erlsci/midiio/blob/master/.github/workflows/ci.yml
[github-tag]: https://github.com/erlsci/midiio/tags
[github-tag-badge]: https://img.shields.io/github/tag/erlsci/midiio.svg
