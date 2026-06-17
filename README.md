# midiio

*Cross-platform realtime MIDI I/O for the BEAM.*

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

    $ rebar3 compile
