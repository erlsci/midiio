# CC assignment — Slice 01: CoreMIDI raw I/O for minimidio

You are the implementer (IC) for one slice of an additive feature in **minimidio**,
a single-header C MIDI library. The architects have already made every design
decision; your job is to implement faithfully against the ledger, run the tests,
and report a per-row disposition with evidence. Do **not** re-litigate design — if
something is wrong or impossible, raise an amendment request rather than working
around it silently.

## Read first (in this order)

1. `collaboration-framework/templates/LEDGER_DISCIPLINE.md` — the protocol you report under.
2. `./ledger.md` — your acceptance criteria (15 rows). This defines "done."
3. `./slice-doc.md` — the full design, decisions D1–D7, and the framing algorithm.
4. The design of record: `../../../minimidio-raw-api-and-findings.md` (§4 API, §5 semantics).

## Where to work

- Edit `minimidio.h` and add `tests/raw_loopback.c` **in the minimidio clone**:
  `/Users/oubiwann/lab/c/minimidio`.
- Create a feature branch first, e.g. `git checkout -b feat/raw-bytes-api`. That
  branch is the eventual PR.
- These planning docs live in the `midiio` repo and must **not** be added to the
  minimidio clone or the PR.

## The one hard rule: strictly additive

No existing function's behavior may change. You are adding a parallel door. In
particular:

- Do **not** modify the existing struct decode loop in `mm__cm_read_proc`, the
  `mm_out_send*` bodies, or any existing field's meaning.
- Do **not** fix U1 / U3 / U2 in the existing functions — those are separate PRs.
  Your new raw path is correct *by construction*; that is new code, not an edit.
- Ledger rows F-14 and F-15 verify this. `git diff` must show only additions plus
  the single `if (dev->is_raw) { … return; }` dispatch line at the top of the read proc.

## What to build (summary — full detail in slice-doc.md)

**Shared scaffolding (D1):** `mm_raw_callback` typedef (after `mm_ump_callback`,
~line 356); `MM_CAP_RAW = 1u << 5` in the cap enum (~line 339); `raw_callback` +
`is_raw` fields on `mm_device` (next to `ump_callback`/`is_ump`); three public
declarations near lines 564–589. Mirror the existing `_ump` door throughout.

**CoreMIDI (D2–D5):**
- `mm_in_open_raw` / `mm_in_open_virtual_raw` — clone `mm_in_open` (line 848) and
  `mm_in_open_virtual` (line 975); set `dev->raw_callback = cb; dev->is_raw = 1;`
  instead of `dev->callback`.
- `mm_out_send_raw` — byte-exact, **no length cap**. Size a `MIDIPacketList` to
  the payload (heap buffer of `sizeof(MIDIPacketList) + len`); `MIDIReceived` for
  virtual, `MIDISend` for real. Do **not** reuse the stack-`sizeof(pl)` idiom from
  `mm_out_send_sysex` (that is the U1 cap).
- Add `size_t sysex_pos;` to `mm__dev_coremidi` (~line 445) for cross-packet SysEx.
- Add `if (dev->is_raw) { mm__cm_raw_dispatch(pl, dev); return; }` at the top of
  `mm__cm_read_proc`, and implement `mm__cm_raw_dispatch` per the framing
  pseudocode and the `data_byte_count` table in slice-doc.md §D4. Honor: real-time
  (`≥0xF8`) delivered as its own 1-byte callback even mid-SysEx; whole SysEx
  reassembled across packets; one complete message per callback.
- `mm_context_caps` (line 819) gains `| MM_CAP_RAW`.

**Stubs (D6):** in the WinMM, ALSA, and WebMIDI sections, define all three raw
functions returning `MM_NO_BACKEND` (like `mm_in_open_ump` at line 873). Their
`mm_context_caps` do not advertise `MM_CAP_RAW`.

**Harness (D7):** `tests/raw_loopback.c`, modelled on `examples/virtual.c`.
Records arrivals via the raw callback into a synchronized capture buffer; sends
crafted buffers; pumps the run loop; asserts. Print exactly one line `PASS T<n>`
per passing case to stdout, and exit non-zero on the first failure.

**Loopback topology — read slice-doc §D7 carefully; the obvious wiring is wrong.**
Two separate virtual ports don't auto-connect. Primary path: `mm_out_open_virtual`
(create a virtual source) → find it via `mm_in_count`/`mm_in_name` → open it with
`mm_in_open_raw(idx)` (which connects). Then `mm_out_send_raw` on the source hits
the virtual `MIDIReceived` branch — so **T3 must use this path** (that's where the
no-cap proof lives). Add one case via `mm_in_open_virtual_raw` + `mm_out_open(idx)`
to cover that function. If intra-process loopback doesn't work at runtime, flag it
as a ledger amendment rather than forcing it. Cases:

- **T1** send `90 3C 40` → receive exactly `90 3C 40`.
- **T2** send `90 3C 00` → receive exactly `90 3C 00` (unfolded).
- **T3** send a 300-byte SysEx (`F0` + 298 data + `F7`) → receive one callback,
  full length, intact `F0…F7`.
- **T4** send `F0 7E 00 … F8 … F7` (F8 mid-stream) → receive a 1-byte `F8`
  callback AND a SysEx callback whose payload contains no `0xF8`.
- **T5** `mm_context_caps(&ctx) & MM_CAP_RAW` is non-zero.
- **T6** (additive) also open a *struct-mode* virtual destination, send a note-on,
  and assert it still decodes to `MM_NOTE_ON` with the right data — proving the
  shared read proc is unbroken.

## Reporting (closing-report.md)

When the ledger is fully closed, write `closing-report.md` in this directory with
a **per-row walk** — every one of the 15 rows, its final status (`done` /
`deferred` / `no-op`), and its evidence (commit SHA + the `Verify` command's
output). Do not summarise; do not write "deviations: none." Fill the ledger's
Evidence column as you go, not at the end. Name any row you marked `done` but feel
uncertain about. Then hand back to CDC for independent verification.

## If you get stuck

Five-iteration budget. If the read-proc framing fights you past iteration 3, stop
and flag it — it may mean the slice needs splitting (a 01b for the harness/framing),
which is an architect call, not a grind.
