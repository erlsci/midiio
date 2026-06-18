# Closing report — arc2/slice2: `send/2` over the raw seam + dirty-I/O

> CC self-report. Pairs with `ledger.md` (per-row CC evidence) and the
> forthcoming `cdc-verification.md` (independent CDC verdict). Written to the
> floor: what the work *achieves*, with deferrals named, not what it could.

## What landed

The outbound data path. A `midi`-shaped caller can now `open_output` →
`send(Dev, <<bytes>>)` a complete MIDI message byte-exact → `close`. With slice 1's
crashing-owner-leaks-nothing guarantee already in place, **arc 2's capability is
complete.**

- **The raw seam** — `c_src/midiio_send.h`: `midiio_dev_send_raw(dev, bytes, len)`,
  the single C entry point all of `send/2` funnels through, plus the interim
  status-parsing adapter wholly inside its body. `midiio_expected_len` (the
  status→fixed-length table, derived from `mm_out_send`'s own switch) is the one
  helper the wrapper shares for length validation.
- **The NIF wrapper** — `send_nif` in `c_src/midiio_nif.c`: resource/binary checks,
  the R1 length validation (let-malformed-crash via `badarg`, decided *before* the
  seam so the crash is clean Erlang-side), the liveness gate, and result mapping
  (`ok` / `{error,not_open}` / `{error,{unsupported_status,B}}` / `{error,invalid_arg}`
  / mechanical `result_to_atom` for backend `MM_ERROR`). Registered
  `ERL_NIF_DIRTY_JOB_IO_BOUND` — the first and only dirty NIF.
- **Erlang surface** — `midiio:send/2` in `-nifs`/`-export`, the slice-doc `-spec`,
  `?NOT_LOADED` stub, EDoc, and an updated moduledoc.
- **ASan** — a send loop in `c_src/test/midiio_asan.c` driving the seam ×200 over
  every channel type, all ten system bytes, the unframable `0xF4`, and a SysEx
  (the memcpy-into-the-4096-buffer path).
- **eunit** — seven `send/2` rows: channel ok, SysEx ok, system bytes ok,
  closed→`not_open`, `0xF4`→`unsupported_status`, oversized→`invalid_arg`, and the
  three malformed crashes.

## The one design refinement (disclosed)

The slice-doc and ledger row 1 typed the seam `midiio_dev_send_raw(midiio_dev_res
*res, …)`. **I typed it `mm_device *dev` instead.** Rationale:

1. The seam only ever touches `res->dev` — nothing else from the resource.
2. **Ledger row 18 requires the standalone ASan harness to call the seam
   directly**, and that program has no `midiio_dev_res` type. A `midiio_dev_res*`
   seam is uncallable from the harness; an `mm_device*` seam is exactly what the
   harness already holds.
3. `mm_out_send` itself takes `mm_device*`, so native `mm_out_send_raw` almost
   certainly will too — making `mm_device*` *more* faithful to "the symbol
   re-pointed at native `mm_out_send_raw`," not less.

The function **name and arity are unchanged**; the NIF wrapper passes `&res->dev`.
This is a refinement that makes the seam strictly more re-pointable and unblocks
the ledger-mandated ASan reuse — flagged here rather than applied silently. If CDC
prefers the literal `midiio_dev_res*` signature, the cost is duplicating the
adapter for the harness; I recommend keeping `mm_device*`.

## Verification (calibrated)

I **ran** the following (not "believe"):

- **macOS (CoreMIDI):** `rebar3 as test check` → exit 0 — compile, xref + dialyzer
  zero findings, **26/26 eunit** (19 prior + 7 send), cover. `make asan` →
  `ASAN-OK`.
- **Linux (ALSA), via `make vm-test`** (multipass VM with a real `snd-virmidi`
  sequencer): **26/26 eunit** with `/dev/snd/seq` present — the send rows actually
  execute on ALSA, including the `mm_out_send` switch, the dirty-I/O drain, and the
  SysEx memcpy. `make asan` → `ASAN-OK` under LeakSanitizer.
- A direct `erl` smoke of every route confirmed the exact returns (`note_on…clock`
  → `ok`; `0xF4` → `{error,{unsupported_status,244}}`; 5000-byte SysEx →
  `{error,invalid_arg}`; closed → `{error,not_open}`; short/data-first/empty →
  `badarg`).

## No lock on the send path (row 13)

Neither `send_nif` nor the seam takes `g_uninit_lock` or any mutex. The unlocked
`res->live` read is safe: the resource is an argument, so it is reachable and its
GC destructor cannot race the call, and the per-device-process model (DESIGN §2/D2:
one embedded `mm_context` per device) serializes open/send/close for a given
device. This is the payoff of the per-device-context decision — the realtime send
path is lock-free by construction, not by luck.

## Disclosed deferrals (no silent drops)

- **Byte-exact receipt** is not asserted — arc 2 has no inbound path. The bytes on
  the wire are verified by the virtual/real send returning `ok` over minimidio's
  canonical serializer; the virtual-loopback round-trip that proves receipt is
  arc-3 (`DESIGN.md` §9). Not faked.
- **PropEr forward-only adapter property** — not added. The deterministic eunit set
  already covers every route plus the reserved-byte and length boundaries; the
  property's value (random coverage) is marginal without receipt, which is arc 3.
  Stated, not buried.
- **Real-hardware audible send (row 14)** — deferred: no external instrument/listener
  on the build box to *observe* emission. The send-to-wire path is exercised by the
  virtual sends and ASan; audible confirmation is a manual run with a synth.
- **Static-dirty latency tradeoff (D3 ⚑)** — accepted for v0.1.0; the conditional
  fast path is a post-ship measured decision, not this slice.

## Spec-vs-delivered diff

Everything in the slice-doc "What to build" shipped: the seam, the interim adapter
(routing table exactly as specified, incl. the 14-bit song-position pack and the
reserved-byte sentinel), the dirty-I/O flag, the error mapping, the let-it-crash
asymmetry, the Erlang surface, the ASan send loop, the eunit set. The only
deviation is the seam's parameter type (`mm_device*`, disclosed above). No silent
additions; no scope softening.

## Status

All S1 rows closed; the two open S2s (row 14 real-hardware, the optional PropEr) are
deferred **with written rationale**, not dropped. Arc 2's capability — open → send
→ close, byte-exact, no leak on owner crash — is complete. The arc-2 close-out
(specified-vs-delivered diff across both slices) runs once CDC signs off slices 1
and 2.
