# Slice 03 — WinMM + WebMIDI raw I/O — Closing Report (CC → CDC)

*Implementer (CC) hand-back for independent verification.*
*Implementation commit: `66bb4e1` on branch `feat/raw-bytes-api` (parent
`107107f`, the slice-02 close). Source greps reproducible anywhere; compile
rows use the toolchains noted per row.*

All 13 ledger rows reached a final status: **11 done, 2 deferred** (DEF-1,
DEF-2), 0 no-op. The deferrals are by ledger design — neither backend has an
in-loop runtime path — and carry reasons + re-entry conditions. No row was
silently dropped; no runtime pass was faked. This slice closes the arc: every
backend is now either fully raw-capable or honestly stubbed.

---

## Verification reality (why two rows are deferred, not done)

- **WinMM has no virtual ports** (the source itself directs users to loopMIDI),
  so the virtual-loopback harness cannot run there. A byte-exact round-trip needs
  a Windows host + loopMIDI, which is not in this dev loop (macOS + a Linux VM).
- **WebMIDI needs a browser** with a Web MIDI implementation; there is no
  headless assert harness.

So the acceptance bar here is **compile-checks + structural audit**, exactly as
the slice-doc agreed. Both compile cleanly; the byte-forward logic is thin and
reviewable; the two round-trips are `deferred` with concrete re-entry conditions.

## Toolchains used

- WinMM cross-compile: **zig 0.16.0** (`-target x86_64-windows-gnu -lwinmm`).
- WebMIDI: **emcc 5.0.7** (`-sASYNCIFY`).
- Regression: host `cc` (CoreMIDI) and the `midiio-test` Multipass VM (ALSA).

All four were available, so no compile row needed deferring for a missing
toolchain.

---

## Additive proof (ADD-1 context)

`git diff 107107f -- minimidio.h` deletions are only:
1. the two caps lines (`return MM_CAP_MIDI1;` → `… | MM_CAP_RAW;`) on WinMM and
   WebMIDI (WIN-3 / WEB-3);
2. the four replaced one-line raw **stub** bodies (`mm_in_open_raw` and
   `mm_out_send_raw` on each backend) — replaced by real implementations, which
   is exactly what WIN-1 / WEB-1 require; and
3. one stale `/* … stub for now */` comment.

The struct-decode branches of `mm__wm_in_proc`, the parse loop of
`mm__web_dispatch_raw`, and every `mm_out_send*` body are **byte-for-byte
unchanged**. Both raw inbound branches are pure insertions at the top of their
handlers, guarded by `if (dev && dev->is_raw)` (placed *before* the
`!dev->callback` guard, since `callback` is NULL in raw mode). The two
`mm_in_open_virtual_raw` stubs are untouched.

---

## Per-row walk (all 13)

> SHA `66bb4e1`. Source greps run at the clone root (any host).

**WEB-1 — WebMIDI `mm_in_open_raw` + `mm_out_send_raw` real — DONE.**
`grep -c MM_NO_BACKEND` over their context = **0**. `mm_in_open_raw` mirrors
`mm_in_open` (sets `web.input_idx`, `raw_callback`, `is_raw`); `mm_out_send_raw`
forwards to `mm__web_out_send_raw_js` (the same JS sender `mm_out_send` uses).

**WEB-2 — raw inbound branch in `mm__web_dispatch_raw` — DONE.**
`if (dev && dev->is_raw) { if (dev->raw_callback && data && size>0)
dev->raw_callback(…); return; }` at the very top — before the `!dev->callback`
guard and the parse loop. Web MIDI delivers one complete message per event, so
the bytes are forwarded verbatim (no framing).

**WEB-3 — WebMIDI caps advertise `MM_CAP_RAW` — DONE.**
`return MM_CAP_MIDI1 | MM_CAP_RAW;`.

**WEB-4 — WebMIDI `mm_in_open_virtual_raw` stays `MM_NO_BACKEND` — DONE.**
Body unchanged: `{ (void)…; return MM_NO_BACKEND; }`. Intentional (no virtual
ports in the Web MIDI API), mirrors `mm_in_open_virtual`.

**WIN-1 — WinMM `mm_in_open_raw` + `mm_out_send_raw` real — DONE.**
`grep -c MM_NO_BACKEND` over their context = **0**. `mm_in_open_raw` mirrors
`mm_in_open` with `raw_callback`/`is_raw`. `mm_out_send_raw` walks the buffer:
short messages packed into `midiOutShortMsg`, a whole `F0…F7` via
`midiOutLongMsg` (heap buffer sized to the payload — byte-exact, no length cap).

**WIN-2 — raw inbound branch in `mm__wm_in_proc` — DONE.**
`if (dev && dev->is_raw) { … return; }` at the top, before `!dev->callback`.
`MIM_DATA` → unpack `p1` into `1 + mm__wm_raw_data_bytes(status)` wire bytes;
`MIM_LONGDATA` → forward `lpData[0..dwBytesRecorded)`, then `midiInAddBuffer`.

**WIN-3 — WinMM caps advertise `MM_CAP_RAW` — DONE.**
`return MM_CAP_MIDI1 | MM_CAP_RAW;`.

**WIN-4 — WinMM `mm_in_open_virtual_raw` stays `MM_NO_BACKEND` — DONE.**
Body unchanged: `{ (void)…; return MM_NO_BACKEND; }`. Intentional (no virtual
ports on WinMM), mirrors `mm_in_open_virtual`.

**CC-1 — WinMM cross-compiles clean, no new warnings — DONE.**
`zig cc … -target x86_64-windows-gnu -lwinmm -Wall -Wextra` → **exit=0**. A fresh
build emits 3 warnings — 1 `-Wunknown-pragmas` (the MSVC
`#pragma comment(lib,"winmm.lib")` in the WinMM backend) and 2
`-Wunused-function` (the `mm__ump_*` helpers, unused on WinMM). Base `bb705e8`
emits the **identical** 3, so the raw additions add **zero** new warnings. (zig's
content-addressed cache makes warm rebuilds emit nothing — the comparison was run
on fresh builds of both.)

**CC-2 — WebMIDI builds to wasm clean — DONE.**
`emcc … -sASYNCIFY -o /tmp/web.js` → **exit=0**, producing `/tmp/web.js` +
`/tmp/web.wasm`.

**CC-3 — implemented backends still compile (regression) — DONE.**
CoreMIDI (host, `-framework CoreMIDI -framework CoreFoundation`) → exit=0; ALSA
(`midiio-test` VM, `-lasound -lpthread`) → exit=0. The compile-check TU builds on
all four backends.

**ADD-1 — additive, struct paths byte-unchanged — DONE.** See "Additive proof".

**DEF-1 — WinMM raw round-trip — DEFERRED.**
*Reason:* WinMM has no virtual ports; a byte-exact in-loop round-trip needs a
Windows host + loopMIDI, absent from this dev loop. *Re-entry:* a Windows host
with loopMIDI — two ports, `mm_in_open_raw` ↔ `mm_out_send_raw`, asserting
byte-exact note-on / vel-0 / SysEx / real-time (T1–T4 shape). The code path is
compile-checked (CC-1) and audited by inspection.

**DEF-2 — WebMIDI raw round-trip — DEFERRED.**
*Reason:* Web MIDI needs a browser; no headless assert harness exists.
*Re-entry:* a browser Web MIDI test (extend `examples/web_*` + `serve-wasm.sh`)
asserting byte-exact raw send/receive. The code path is wasm-build-checked (CC-2)
and audited.

---

## Items I am uncertain about (named, per protocol)

1. **WinMM `mm_out_send_raw` framing is reviewed, not run.** This is the one
   piece of real output logic. I audited it against the `data_bytes` table and
   `mm_out_send`'s packing, and the SysEx scan against `mm_out_send_sysex`, but
   it has **not** executed (DEF-1). Specific things for CDC to eyeball: the
   `1 + data_bytes(status)` advance for short messages, and that an interleaved
   real-time byte inside a SysEx is transmitted verbatim within the
   `midiOutLongMsg` payload (byte-exact on the wire; framing is the receiver's
   job, consistent with the design-of-record).
2. **WinMM SysEx output uses a heap buffer (no cap), a small deviation from
   "mirror `mm_out_send_sysex`".** I lifted the fixed-buffer cap to honor
   semantic rule 4 ("no length cap"), the same way CoreMIDI's U1 fix did, while
   keeping the prepare/long/unprepare dance. CDC may prefer the fixed 4096 buffer
   for a strict mirror — flagging the choice explicitly.
3. **The two compile rows prove type/signature/link correctness, not runtime
   behavior.** That gap is real and is exactly what DEF-1/DEF-2 track.

## Hand-back

Ledger fully resolved (11 done, 2 deferred). Requesting independent CDC
verification: re-run the source greps (WEB/WIN-1…4, ADD-1) and the compile rows
(CC-1 zig, CC-2 emcc, CC-3 host+VM), audit the WinMM `mm_out_send_raw` framing in
place of a runtime test, and confirm the two deferrals' reasons + re-entry
conditions. With this slice the arc is complete across all four backends.
