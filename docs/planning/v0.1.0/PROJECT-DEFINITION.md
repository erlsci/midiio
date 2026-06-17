# midiio v0.1.0 — Project Definition

> SDLC step 2 (bounded scope). Sits above the design doc (`DESIGN.md`) and the
> arc/slice breakdown (`ARCS.md`). Evidence and rationale live in
> `workbench/RESEARCH-nif.md`, `workbench/RESPONSE-to-midi-needs.md`, and the two
> upstream notes; this document draws the boundary, not the reasoning.

## What midiio is

midiio is the **transport layer** of the erlsci MIDI family: an Erlang NIF over
the single-header [minimidio](https://github.com/octetta/minimidio) C library
that moves **raw MIDI wire bytes** to and from the operating system's MIDI ports
in real time (CoreMIDI / WinMM / ALSA; WebMIDI later). It discovers devices and
ferries bytes; it has no opinion about what the bytes mean.

Consumers (all in the erlsci / ut-proj family): **midi** (the codec+glue layer,
being planned in parallel), and through it **undermidi**, **underack**, and
**undertone**.

## The contract, stated precisely

The "codec-free" principle has a sharp definition now, because minimidio forced
the question (`RESEARCH-nif.md` Findings A/B; `RESPONSE-to-midi-needs.md`):

- **midiio presents a raw-bytes boundary.** `send(Ref, <<bytes>>)` outbound;
  `{midi_in, Ref, <<bytes>>, Ts}` inbound. One complete, status-complete MIDI
  message per delivery (midi R1).
- **No Erlang message vocabulary, no codec, no midilib dependency.** midiio never
  emits `{note_on, ...}`-style terms and never interprets a message's meaning.
  `midibin` (in midilib) owns wire⇄term encoding on both ends, one layer up.
- **No normalization.** midiio passes through exactly what minimidio gives it,
  including the backend-dependent note-on-vel-0 quirk; `midi` owns the single
  normalization point (midi R6).
- **Byte boundary, struct engine.** minimidio is message-structured internally,
  so midiio bridges bytes⇄`mm_message` behind a **stable internal raw seam**.
  The maintainer is adding a native `mm_in_open_raw` / `mm_out_send_raw` path
  ("no opinion" mode); until it lands, the seam is implemented by a small,
  isolated interim adapter over the current struct API, swappable with no change
  above the seam.

## In scope for v0.1.0

1. Build wiring: vendored `minimidio.h`, NIF C source, rebar3 produces and loads
   the shared object on macOS + Linux; per-OS link flags.
2. Context lifecycle as a NIF resource object (`enif_alloc_resource` +
   destructor → `mm_context_uninit`).
3. Device enumeration: list inputs/outputs by index+name; expose backend atom +
   capability flags.
4. Device lifecycle as a resource object: open/close output and input; the
   device resource keeps its context alive; destructor closes OS handles.
5. Outbound: `send(Ref, <<bytes>>)` over the raw seam, routed normal-vs-SysEx
   internally, on a dirty I/O scheduler; tagged error returns.
6. Inbound: open/start/stop input; deliver `{midi_in, Ref, <<bytes>>, Ts}` to a
   single owner pid via `enif_send` from the backend thread; owner settable at
   open and re-settable.
7. Conformance: virtual-port byte-level loopback test, Erlang-drivable, covering
   the message taxonomy round-trip (transport level, independent of midilib's
   codec).
8. Targets: **macOS (CoreMIDI) and Linux (ALSA)**. OTP 27+.

## Explicit non-goals (v0.1.0)

- **No message codec / SMF / music theory.** Lives in midilib / midi / undermidi.
- **No scheduling, tempo, or playback clock.** That's the midi↔undermidi
  boundary; midiio timestamps inbound and sends outbound immediately (midi R5).
- **No multicast inbound.** One owner pid per input; fan-out is midi's job (R3).
- **No normalization of backend quirks** (vel-0 etc.) — midi owns it (R6).
- **No download/cmake build choreography** (the sp_midi anti-pattern); vendor the
  one header.

## Deferred — named and tracked, not dropped

- **Windows (WinMM)** backend bring-up and CI.
- **Virtual ports as a first-class feature** (CoreMIDI/ALSA support them;
  blocked for large SysEx by upstream U1). Used internally for the loopback test
  in v0.1.0, but not a supported public surface yet.
- **UMP / MIDI 2.0** (ALSA-only upstream today).
- **WebMIDI / Emscripten** target.
- **Batch send** (`send_batch(Ref, [Bin])`) — pending midi/undermidi's answer on
  outbound granularity (NEW-1).
- **Swap interim adapter → native `mm_*_raw`** when the upstream API ships.

## Success criteria

- `rebar3 compile` builds and loads the NIF on macOS and Linux with no manual
  steps; `rebar3 check` (xref + dialyzer + eunit + coverage) is green.
- From the shell: enumerate devices, open an output, `send/2` a note-on, and have
  it arrive (verified via a virtual loopback in CI; via real hardware manually).
- Inbound: open an input, receive `{midi_in, Ref, <<bytes>>, Ts}` for each
  message, one complete message per delivery, byte-exact w.r.t. what minimidio
  delivers.
- A crashing owner process leaks no OS handles (destructor path).
- Every minimidio quirk we depend on (U1–U3) is covered by a conformance test
  that is either green or an explicitly-disclosed skipped/expected-fail with a
  tracked rationale.

## Definition of done (the planning session)

`DESIGN.md` answers every §5 open question with a decision + rationale +
alternatives; `ARCS.md` lays out arcs→slices with a ledger skeleton; the first
slice has a `cc-prompt.md` + `ledger.md`. Anything unresolved is named and
tracked — no silent drops.
