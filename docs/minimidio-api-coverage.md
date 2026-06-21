# minimidio API coverage (midiio v0.1.0)

> How much of the minimidio public API midiio v0.1.0 exposes, measured against the
> vendored pin **`bb705e8` (`v0.5.0-dev`)** — the surface midiio compiles against
> (`c_src/minimidio.lock`). Re-confirm against the lock if it has moved.
>
> **Headline:** every minimidio function in midiio's scope — the **MIDI-1.0,
> codec-free device-transport** surface — is covered. What's *not* covered is, in
> every case, a **named non-goal** of the transport layer (UMP/MIDI 2.0, MTC time
> helpers, and public virtual-port opening), not a gap. Of the 24 public functions:
> **16 covered + 2 partial = 18 implemented (~75%), 6 deferred-by-design (~25%)** —
> the deferred quarter being exactly UMP / MIDI 2.0 (2) and the MTC time-code
> helpers (3), plus public virtual-input open (1).

## Scope framing

midiio is the transport layer of the erlsci MIDI family: it discovers ports and
moves **raw MIDI 1.0 bytes** to/from the OS, with **no codec**. Anything that
interprets bytes (UMP↔MIDI-1 conversion, MTC time math, message structs) belongs
to `midi` one layer up. So the coverage target is minimidio's MIDI-1.0 transport
API; UMP and the MTC helpers are deliberately out of scope and consumed (if ever)
above midiio.

## Function coverage

Legend: ✅ covered · ◑ partial / internal · ⏸ deferred (named non-goal).

### Context + capabilities

| minimidio | midiio | Status |
|-----------|--------|--------|
| `mm_context_init` | `context_open/0` | ✅ |
| `mm_context_uninit` | `context_close/1` | ✅ |
| `mm_context_caps` | `caps/1` (decoded to a map) | ✅ |
| `mm_result_string` | error codes surfaced as atoms (`{error, Atom}`); `result_atom/1` test NIF | ◑ result codes are mapped to atoms rather than the C string |

### Device enumeration

| minimidio | midiio | Status |
|-----------|--------|--------|
| `mm_in_count` | `list_inputs/1` | ✅ |
| `mm_in_name` | `list_inputs/1` | ✅ |
| `mm_out_count` | `list_outputs/1` | ✅ |
| `mm_out_name` | `list_outputs/1` | ✅ |

### Input (inbound)

| minimidio | midiio | Status |
|-----------|--------|--------|
| `mm_in_open` | `open_input/2` | ✅ |
| `mm_in_start` | `start_input/1` | ✅ |
| `mm_in_stop` | `stop_input/1` | ✅ |
| `mm_in_close` | `close/1` (input branch) | ✅ |
| `mm_in_open_ump` | — | ⏸ UMP / MIDI 2.0 (not MIDI-1.0 transport) |
| `mm_in_open_virtual` | used internally by the conformance loopback; not a public call | ⏸ public virtual-port opening not exposed in v0.1.0 |

### Output (outbound)

| minimidio | midiio | Status |
|-----------|--------|--------|
| `mm_out_open` | `open_output/1` | ✅ |
| `mm_out_send` | `send/2` (channel + system messages, via the raw seam) | ✅ |
| `mm_out_send_sysex` | `send/2` (SysEx, routed internally) | ✅ |
| `mm_out_close` | `close/1` (output branch) | ✅ |
| `mm_out_open_virtual` | `open_output_virtual/0` | ◑ exposed only as test/scaffolding (drives the loopback), not a supported public surface |
| `mm_out_send_ump` | — | ⏸ UMP / MIDI 2.0 |

### Message + time helpers

| minimidio | midiio | Status |
|-----------|--------|--------|
| `mm_make_message` | consumed by the send seam (`midiio_send.h`) | ✅ internal — midiio's API is raw bytes, so the struct constructor is used, not re-exposed |
| `mm_mtc_push` | — | ⏸ MTC is a codec/time concern → `midi`'s layer |
| `mm_mtc_rate_string` | — | ⏸ MTC helper |
| `mm_mtc_to_seconds` | — | ⏸ MTC helper |

## Capability bits (`mm_context_caps`)

`caps/1` decodes the full bitfield into a map regardless of scope, so callers can
*see* every capability even where midiio doesn't yet act on it:

| Bit | `caps/1` key | Acted on in v0.1.0 |
|-----|--------------|--------------------|
| `MM_CAP_MIDI1` | `midi1` | ✅ the whole transport targets MIDI 1.0 |
| `MM_CAP_VIRTUAL_IN` | `virtual_in` | ◑ decoded + reported; no public open-virtual-input |
| `MM_CAP_VIRTUAL_OUT` | `virtual_out` | ◑ decoded + reported; `open_output_virtual/0` is test scaffolding |
| `MM_CAP_UMP` | `ump` | ⏸ decoded + reported; UMP I/O deferred |
| `MM_CAP_MIDI2` | `midi2` | ⏸ decoded + reported; MIDI 2.0 deferred |

## Backend coverage

minimidio has four backends; midiio v0.1.0 is **built and tested on two**:

| Backend | Platform | midiio v0.1.0 |
|---------|----------|---------------|
| CoreMIDI | macOS | ✅ built + tested in CI (full runtime: virtual loopback, conformance, ASan) |
| ALSA sequencer | Linux | ✅ built + tested (CI build/load everywhere; full runtime on a host with `/dev/snd/seq` — the `make vm-test` multipass harness) |
| WinMM | Windows | ⏸ compiled by minimidio, **not yet wired or tested by midiio** (roadmap) |
| Web MIDI | Emscripten/Wasm | ⏸ present upstream, **not yet built or tested by midiio** (roadmap) |

## Summary

The **in-scope MIDI-1.0 transport API is fully covered**: context lifecycle,
capability introspection, input + output enumeration, the full input lifecycle
(open/start/stop/close + owner handoff), and the full output path (open/send —
including SysEx — /close), on CoreMIDI and ALSA. Every uncovered function is a
deliberate non-goal of the codec-free transport layer:

- **UMP / MIDI 2.0** (`mm_in_open_ump`, `mm_out_send_ump`, `MM_CAP_UMP`/`MM_CAP_MIDI2`)
  — byte-level UMP↔MIDI-1 handling is a codec concern for `midi`.
- **MTC time helpers** (`mm_mtc_push`, `mm_mtc_rate_string`, `mm_mtc_to_seconds`)
  — time-code math is semantic, not transport.
- **Public virtual-port opening** (`mm_in_open_virtual`; `mm_out_open_virtual`
  exposed only as test scaffolding) — virtual ports back the conformance loopback;
  promoting them to a supported public surface is post-v0.1.0.

The native raw-bytes API midiio helped land upstream (`mm_*_raw` + `MM_CAP_RAW`)
arrived **after** the `bb705e8` pin, so it is **not** part of this 0.1.0 coverage;
adopting it is v0.2.0 arc 1 (`docs/planning/v0.2.0/arc1/`), which swaps the interim
adapter for the native path.
