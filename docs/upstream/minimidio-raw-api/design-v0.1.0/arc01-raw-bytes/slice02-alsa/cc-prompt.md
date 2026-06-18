# CC assignment — Slice 02: ALSA raw I/O for minimidio

You are the implementer (IC) for the ALSA backend of the raw-bytes feature. The
shared scaffolding (typedef, `MM_CAP_RAW`, `mm_device` fields, public decls) and
the CoreMIDI implementation already landed in slice 01; ALSA currently has stub
functions returning `MM_NO_BACKEND`. Your job: make ALSA real, extend the test
harness to pass on Linux, and report per-row with evidence. Do not re-decide
design — raise an amendment request instead of working around the ledger.

## Read first (in this order)

1. `collaboration-framework/templates/LEDGER_DISCIPLINE.md` — the protocol.
2. `./ledger.md` — your 14 acceptance criteria.
3. `./slice-doc.md` — full design, decisions D1–D6, the inbound/outbound algorithms.
4. Design of record: `../../../minimidio-raw-api-and-findings.md` (§5 semantics, §6 ALSA).

## Where to work

- Same clone, same branch as slice 01: `/Users/oubiwann/lab/c/minimidio`,
  branch `feat/raw-bytes-api`. Continue on it (or branch from it).
- **Behavioral testing runs in the existing midiio-NIF Multipass VM** (it has
  `gcc`, `libasound2-dev`, and `snd-seq`). Make sure the clone is reachable in the
  VM (via your existing mount, or `multipass transfer`). Confirm the VM first
  (ledger A-0) before building anything.

## The one hard rule: strictly additive

No existing behavior changes. In particular **do not touch** the per-type
`switch (ev->type)` in `mm__alsa_recv_thread`, the `mm_out_send` / `mm_out_send_sysex`
bodies, or the existing vel-0 fold (line 1406) — that fold is a *separate* PR
(its ticket), not this work. Your raw path bypasses the fold by construction
because it uses `snd_midi_event_decode`, which is new code, not an edit. Ledger
A-12/A-13 verify this.

## What to build (summary — full detail in slice-doc.md)

**Device state (D1):** add `snd_midi_event_t* midi_ev;` to `mm__dev_alsa`
(struct ~line 474). Allocate it in the raw input opens
(`snd_midi_event_new(MM_SYSEX_BUF_SIZE, …)` + `snd_midi_event_no_status(…, 1)` on
the decoder); lazily in `mm_out_send_raw`; free in `mm_in_close` / `mm_out_close`.

**Raw inbound (D2):** in `mm__alsa_recv_thread`'s drain loop (~line 1365), add
`if (dev->is_raw) { … continue; }` **before** the `switch`, parallel to the
existing `if (dev->is_ump)` branch. SysEx events → accumulate into
`da->sysex_buf`/`sysex_pos` (mirror the struct accumulator at 1492–1510), deliver
whole on `0xF7`. All other events → `snd_midi_event_decode` into a small buffer →
`raw_callback`. Never touch `dev->callback` (NULL in raw mode).

**Raw outbound (D3):** `mm_out_send_raw` — guard like the other sends; ensure
`da->midi_ev` exists; `snd_midi_event_reset_encode`; loop
`snd_midi_event_encode` over the buffer, sending each produced event via the
existing `mm__alsa_send_ev` helper (line 1651). Byte-exact, no cap (encode
assembles `F0…F7` into one variable SysEx event).

**Opens (D4):** `mm_in_open_raw` ≈ `mm_in_open` (1520); `mm_in_open_virtual_raw`
≈ `mm_in_open_virtual` (1764). Set `dev->raw_callback = cb; dev->is_raw = 1;`
(leave `callback` NULL) and allocate `da->midi_ev`.

**Caps (D5):** add `MM_CAP_RAW` to the ALSA `mm_context_caps` bitmask (line 1253).

**Harness (D6):** extend `tests/raw_loopback.c` to compile and pass on Linux.
Same API-level loopback as slice 01's corrected primary path: `mm_out_open_virtual`
(virtual source) → find it via `mm_in_count`/`mm_in_name` → `mm_in_open_raw(idx)`
(connects intra-client) → `mm_out_send_raw` on the source → received by the raw
input thread. Put platform differences under `#ifdef`: the pump is just a
`usleep` long enough for the recv thread to deliver (no `CFRunLoop` on Linux), and
the build line is `-lasound -lpthread`. Keep cases T1–T6 identical in intent;
print `PASS T<n>` per pass, exit non-zero on first failure.

## Reporting (closing-report.md)

When the ledger is fully closed, write `closing-report.md` here with a **per-row
walk** of all 14 rows — final status + evidence (commit SHA + `Verify` output,
including the VM command lines). No prose summary; no "deviations: none." Fill the
ledger Evidence column as you go. Name any `done`-with-uncertainty. Then hand back
to CDC.

## If you get stuck

Five-iteration budget. If `snd_midi_event` decode/encode or the intra-client
loopback fights you past iteration 3, stop and flag it — that's an architect
call, not a grind. The most likely subtlety is running-status on decode (fixed by
`snd_midi_event_no_status`) or SysEx chunk reassembly (the accumulator).
