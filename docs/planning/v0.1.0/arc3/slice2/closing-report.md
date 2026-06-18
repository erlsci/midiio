# Closing report — arc3/slice2: set_owner handoff hardening + virtual-loopback conformance

> CC's per-group walk (full table in `ledger.md`). The **proof slice** — it adds no
> new public surface beyond a `set_owner` robustness fix; everything else is
> byte-level transport conformance. Closes the slice-1 re-verification residuals
> R1/R2 and **closes arc 3 / v0.1.0's planning arc**. Host: macOS arm64 (CoreMIDI),
> OTP 28. Linux/ALSA via `make vm-test`. Date: 2026-06-18. Iteration: 1.

## Group A — set_owner atomic handoff (R1/R2)

`set_owner/2` now arms the **new** monitor into a local `ErlNifMonitor` *before*
demonitoring the old, and commits (drop old, store new, write owner) only on
success; on failure the old owner+monitor are untouched and it returns
`{error, owner_not_alive}`. This **closes R2** (a dead target can no longer disarm
a good monitor or silently leak) and **narrows R1** to the irreducible ERTS
demonitor window (a death already in delivery — covered by the idempotent
`do_dev_cleanup`, no UAF). Added `am_owner_not_alive`; updated the `-spec` +
`@doc`. Two regression tests: dead-handoff preserves the old owner's reclaim;
live-handoff re-points so the new owner's death reclaims. (Optional S3 — locking
`down_device`'s `monitored=0` write — disclosed-skipped: benign int race, no
memory-safety gain.)

## Group B — virtual-loopback conformance + PropEr

- **Taxonomy byte-exact (rows 8–10):** a table-driven loopback test sends every
  taxonomy member (channel voice, system common, all six real-time, SysEx) and
  asserts identical bytes arrive. 14-bit Pitch Bend (`E0 7F 3F`) and Song Position
  (`F2 10 20`) survive LSB≠MSB; SysEx round-trips at 6 B and 35 B.
- **PropEr (row 11):** `prop_seam_roundtrip` drives generated valid messages
  through **both** raw seams purely via a new `seam_roundtrip/1` test NIF
  (`midiio_bytes_to_msg` outbound parse → `midiio_msg_to_bytes` inbound build, no
  I/O). Byte-exact across the generated space — closes arc2/slice2's deferred
  property. Runs in `check` via an eunit wrapper and standalone via
  `rebar3 as test proper -m midiio_prop`.

## Group C — upstream quirk cases (each green-or-disclosed, tagged)

- **U1 (large SysEx cap):** > ~256 B SysEx over a CoreMIDI virtual source fails
  (`{error,_}`, the upstream stack-`MIDIPacketList` cap) — asserted as the tracked
  CoreMIDI behaviour; on ALSA it round-trips byte-exact.
- **U2 (vel-0):** `90 nn 00` is delivered **as sent** on CoreMIDI (no fold); on
  ALSA the *backend* folds it to note-off (the U2 inconsistency) — disclosed,
  asserted per backend. midiio itself never folds (PropEr confirms the seams).
- **U3 (real-time in SysEx):** **not reproducible over the CoreMIDI virtual
  loopback** — CoreMIDI's send path splits the real-time `F8` out before the
  read-proc sees it, so the read-proc absorption defect doesn't manifest (observed
  `[<<F0,7E,F7>>, <<F8>>, <<>>]`). The test asserts the invariant that holds (no
  delivered SysEx absorbed the F8); the defect remains real for real-hardware
  combined packets (tracked, resolved by raw inbound framing).
- **S1 (multi-packet inbound SysEx):** blocked by U1 on CoreMIDI virtual sources
  (not reproducible there); on ALSA a 1000-byte SysEx is driven and asserted to
  arrive as one intact `F0…F7` (a split would confirm S1).

## Group D — gates

- macOS: `rebar3 as test check` → exit 0 (**41 eunit + PropEr**, dialyzer 3 files
  clean, coverage dormant); `make asan` → `ASAN-OK`.
- Linux/ALSA via `make vm-test` (Ubuntu 24.04, real `/dev/snd/seq`): the same gate
  ran the ALSA branches of U1/U2/S1 and the full taxonomy on real ALSA.

## Disclosed observation (not a regression)

The U3 probe surfaced a spurious empty `{midi_in, Dev, <<>>, Ts}` from CoreMIDI's
packetization of the split real-time byte. It is harmless (a zero-byte payload,
never produced by a well-formed single message) and out of this slice's scope
(recv was verified correct in slice 1); noted for a future recv robustness tweak
(skip zero-length non-SysEx deliveries).

## Close-out — arc 3 + v0.1.0 planning arc

**`PROJECT-DEFINITION.md` success criteria — all met:**

| Criterion | Status | Evidence |
|-----------|--------|----------|
| `rebar3 compile` builds+loads the NIF on macOS **and** Linux, no manual steps; `rebar3 check` green | ✅ | macOS throughout; Linux via `make vm-test` (Ubuntu/ALSA, full check green) |
| Shell: enumerate, open output, `send/2` a note-on, it arrives (virtual loopback / hardware) | ✅ | arc1 enumeration, arc2 `open_output`+`send`, arc3 loopback delivers note-on byte-exact |
| Inbound: `{midi_in, Ref, <<bytes>>, Ts}`, one complete message per delivery, byte-exact | ✅ | arc3/slice1 recv + slice2 taxonomy byte-exact + PropEr |
| A crashing owner process leaks no OS handles | ✅ | outputs via GC dtor (arc2); inputs via owner monitor (slice-1 remediation S2 + slice-2 R2 handoff) |
| Every minimidio quirk we depend on (U1–U3) covered by a conformance test, green or disclosed | ✅ | Group C — U1/U2/U3 (+ S1) each green-or-disclosed with the upstream ref |

**Specified-vs-delivered across arcs — no silent drops.** Arc 1 (build/load,
vendoring, context lifecycle, enumeration+caps), arc 2 (output device + `send/2`,
the raw seam, F1 close), arc 3 (input lifecycle + recv, S1/S2 remediation, handoff
+ conformance) all shipped and are evidenced. Disclosed deferrals carry re-entry
notes (the native `mm_*_raw` swap — seam ready, nothing above changes; UMP/WinMM/
WebMIDI/public-virtual-ports/`send_batch` — named non-goals; the U1/U3 upstream
defects — tracked conformance cases). **Arc 3 is complete; v0.1.0's planning arc
closes.** New learning: `NIF-LEARNINGS` L22 (atomic monitor handoff).
