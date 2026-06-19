# PR: additive raw-bytes I/O door (`mm_*_raw`) across all four backends

> **Paste-ready PR description.** Title suggestion:
> *"Add an additive raw-bytes I/O door (`mm_in_open_raw` / `mm_out_send_raw`)"*
> Suggested labels: `enhancement`. Branch: `feat/raw-bytes-api` (3 commits atop
> `bb705e8`). Implements the feature discussed in #<feature-issue-number>.

---

Hi Joseph 👋

This is the raw-bytes door you were open to ("I like the no-opinion option") —
implemented across all four backends, strictly additive, with nothing in the
existing `mm_message` / UMP API touched. It gives callers that want to own MIDI
semantics themselves (our case: an Erlang binding, `midiio`) a way to deal in
exact wire bytes instead of the decoded struct.

It mirrors a pattern you already shipped: alongside the struct API and the UMP
door (`mm_in_open_ump`, `mm_out_send_ump`, `mm_ump_callback`, `MM_CAP_UMP`) this
adds a third parallel door — a `_raw` sibling per entry point, its own callback
type, its own capability bit.

## What's added (public surface)

```c
/* one complete message per inbound callback, exact wire bytes */
typedef void (*mm_raw_callback)(mm_device* dev,
                                const uint8_t* data, size_t len,
                                double timestamp, void* userdata);

mm_result mm_in_open_raw(mm_context* ctx, mm_device* dev, uint32_t idx,
                         mm_raw_callback cb, void* userdata);
mm_result mm_in_open_virtual_raw(mm_context* ctx, mm_device* dev,
                                 mm_raw_callback cb, void* userdata);
mm_result mm_out_send_raw(mm_device* dev, const uint8_t* data, size_t len);

#define MM_CAP_RAW (1u << 5)   /* advertised by mm_context_caps where supported */
```

Plus two internal device fields (`raw_callback`, `is_raw`) alongside the existing
`ump_callback` / `is_ump`. Lifecycle is unchanged — raw inputs open/start/stop/
close exactly like struct inputs.

## Semantics

Raw mode is a faithful byte pipe:

- **Byte-exact, no rewriting** — no note-on-velocity-0 → note-off folding, no
  status normalization. What's on the wire is what crosses the callback.
- **One complete message per inbound callback** — a channel/system message as its
  full bytes; a SysEx as the whole `F0…F7` (reassembled across packets where the
  backend fragments it); and a system-real-time byte (`F8`–`FF`) arriving inside
  another message delivered as its **own** single-byte callback, kept out of the
  surrounding SysEx.
- **Outbound is byte-exact and uncapped** — large SysEx to a virtual source works.
- **Timestamp** keeps its existing meaning, surfaced as a callback parameter
  (there's no struct to carry it in raw mode).

## Per-backend status

| Backend | `mm_in_open_raw` | `mm_in_open_virtual_raw` | `mm_out_send_raw` | Notes |
|---------|:---:|:---:|:---:|-------|
| CoreMIDI | ✅ | ✅ | ✅ | Read-proc gains an `is_raw` framing branch; output uses a packet list sized to the payload (no length cap). |
| ALSA | ✅ | ✅ | ✅ | Uses ALSA's canonical `snd_midi_event_decode`/`encode`; "raw" means minimidio still owns the event↔byte conversion but hands you bytes. |
| WinMM | ✅ | `MM_NO_BACKEND` | ✅ | No virtual ports on WinMM (matches `mm_in_open_virtual`). Output frames the byte stream into `midiOutShortMsg` / `midiOutLongMsg`. |
| WebMIDI | ✅ | `MM_NO_BACKEND` | ✅ | No virtual ports in the Web MIDI API. The backend already forwarded raw byte arrays internally, so this was mostly wiring. |

`MM_CAP_RAW` is advertised by all four backends. The two `mm_in_open_virtual_raw`
stubs return `MM_NO_BACKEND` because those platforms have no virtual-port concept
— intentional, not a gap.

## Strictly additive

The existing `mm_message` decode paths, the UMP paths, and all `mm_out_send*`
bodies are unchanged. Each backend's raw inbound branch is a single guarded
insertion (`if (dev->is_raw) { … return; }`) at the top of the read handler,
ahead of the struct path. (Each slice was reviewed with a `git diff` to confirm
no existing logic moved.)

## A note on the related bugs

If you saw the companion issues (velocity-0 folding inconsistency, CoreMIDI
real-time-in-SysEx, the CoreMIDI virtual-source SysEx cap): the raw path sidesteps
the first two *by construction* (there's nothing to fold or absorb when you're
forwarding literal bytes), and `mm_out_send_raw` already sizes its buffers to the
payload so it has no cap. But this PR deliberately does **not** modify the
existing struct functions — those fixes are kept as separate PRs against their own
issues, so this one stays purely additive. Happy to send those next if useful.

## Testing — and where we're honest about gaps

- **CoreMIDI** — `tests/raw_loopback.c` runs a virtual-port loopback on macOS:
  byte-exact short messages, velocity-0 pass-through, a >256-byte SysEx round-trip,
  and a real-time byte injected mid-SysEx (asserts the clock arrives separately and
  the SysEx payload stays clean). All pass.
- **ALSA** — the same harness runs in a Linux VM (it uses two MIDI clients, since
  ALSA hides a client's own ports from its enumeration). All cases pass, including
  velocity-0 pass-through (which ALSA's struct path folds, but the raw path doesn't).
- **WinMM** — cross-compile-checked with `zig cc -target x86_64-windows-gnu
  -lwinmm`. We don't have a Windows + loopMIDI setup, so a live round-trip is
  **not** yet done — the output framing has been unit-tested in isolation, but
  real-hardware delivery is untested. Flagging that honestly.
- **WebMIDI** — builds to wasm with `emcc`. A browser round-trip isn't automated
  here; the path is a verbatim forward over the byte-array sender the struct API
  already uses.

`tests/raw_loopback.c` (loopback) and `tests/raw_compile_check.c` (a tiny TU that
exercises the new call sites) are included; both are dependency-free C in the
style of `examples/`.

## One caveat

Line references in the commits and companion issues are against `bb705e8`. The
findings are structural, but please sanity-check anything specific against current
HEAD.

## Provenance

Human-directed, AI-assisted — the same workflow your `AUTHORSHIP.md` describes.

---

Totally understand if you'd like changes to naming, structure, or scope — it's
your library and your taste, and we're glad to revise. Thanks again for being
open to the raw door. 🎹
