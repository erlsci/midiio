# CC assignment — arc2/slice2: `send/2` over the raw seam + dirty-I/O

> Self-contained. Read the arc plan + slice doc, then implement to the ledger.
> This slice **closes arc 2's capability** (open → send → close, byte-exact).
> CDC verifies on close. Five-iteration cap.

## Posture

Peer-frame, write-to-the-floor. Load **collaboration-framework** and
**erlang-guidelines** (lead with `11-anti-patterns.md`, then `03-error-handling.md`
for the `{ok,_}`/`{error,_}` + let-it-crash discipline, and `06-processes-and-
concurrency.md` for the dirty-scheduler reasoning). NIF mechanics from the
substrate cards (`otp-erts/nif-dirty-schedulers.md`, `nif-binaries.md`,
`nif-thread-safety.md`), not memory. Reuse the slice-1 patterns already in
`c_src/midiio_nif.c` — the device resource accessor, the `live` flag,
`result_to_atom`, atom pre-making in `init_statics`.

The single most important design idea here: **the raw seam.** Everything
`send/2` does funnels through one C function, `midiio_dev_send_raw`, so that when
upstream ships native `mm_out_send_raw` the interim adapter is deleted and
**nothing above the seam changes.** If you find yourself spreading
byte-parsing logic across the NIF wrapper, stop — it belongs behind the seam.

## Required reading

1. `docs/planning/v0.1.0/arc2/arc-plan.md` — slice 2 paragraph + the upstream
   gate note.
2. `docs/planning/v0.1.0/arc2/slice2/slice-doc.md` — the seam, the interim
   adapter routing table, dirty-I/O, error mapping, tests. **Build to this.**
3. `docs/planning/v0.1.0/DESIGN.md` §1 (`send/2` surface), §4 (D3 — static
   dirty-I/O + the tradeoff), §6 (error mapping).
4. `c_src/midiio_nif.c` — the slice-1 `midiio_device` resource, `do_dev_cleanup`
   / `live` pattern, `result_to_atom`, `init_statics`, `nif_funcs`.
5. `c_src/minimidio.h` — `mm_out_send` (`:903` CoreMIDI, plus the ALSA and WinMM
   bodies; each is a `switch (msg->type)`), `mm_out_send_sysex` (`:937`),
   `mm_make_message` (`:408`), the `mm_message` struct (`:315`), the
   `mm_message_type` enum (`:264` — note system types are unique constants, **not**
   `status>>4`), `MM_SYSEX_BUF_SIZE` (`:217`). Read `mm_out_send`'s switch to
   derive the status→fields mapping; do **not** reconstruct it from memory.

## What to build

**C (`c_src/midiio_nif.c`):**

- **The seam** — `static mm_result midiio_dev_send_raw(midiio_dev_res *res,
  const uint8_t *bytes, size_t len);`. Body = the interim adapter (slice-doc
  routing table):
  - `bytes[0]` in `0x80–0xEF` → build an `mm_message` (use `mm_make_message`
    for channel cases; verify the per-status data-byte length first) →
    `mm_out_send(&res->dev, &msg)`.
  - `bytes[0] == 0xF0` → `mm_out_send_sysex(&res->dev, bytes, len)` (pass the
    whole binary, `0xF0…0xF7`).
  - `0xF1/0xF2/0xF3/0xF6` and the system-real-time bytes → fill the `mm_message`
    by hand (`MM_SONG_POSITION` packs `bytes[1] | (bytes[2]<<7)` into
    `song_position`) → `mm_out_send`.
  - reserved/undefined leading byte (`0xF4 0xF5 0xF7 0xF9 0xFD`) → return a
    sentinel the wrapper turns into `{error, {unsupported_status, B}}`.
  - **Keep the adapter private to this seam.** It is the only place that knows
    minimidio is struct-based.
- **The NIF wrapper** — `send_nif(env, dev, bin)`:
  - `enif_get_resource` (badarg on a foreign term); `enif_inspect_binary`.
  - **Malformed → crash:** empty binary, leading data byte (`<0x80`), or a known
    status with the wrong length → `enif_make_badarg` (do not invent an error
    atom; §6 let-it-crash). Decide length-validation **before** calling the
    seam so the crash is in Erlang-land, clean.
  - Call `midiio_dev_send_raw`; map the result: `MM_SUCCESS`→`ok`,
    `MM_NOT_OPEN`→`{error, not_open}`, the unsupported-status sentinel →
    `{error, {unsupported_status, B}}`, everything else via `result_to_atom`
    (`MM_INVALID_ARG`→`{error, invalid_arg}` covers oversized SysEx).
  - Register in `nif_funcs` as `{"send", 2, send_nif, ERL_NIF_DIRTY_JOB_IO_BOUND}`.
- **`init_statics`:** pre-make the `unsupported_status` tag atom (and any others
  you add). Never build atoms from runtime input.

**Erlang (`src/midiio.erl`):**

- `send/2` in `-nifs`/`-export`; `?NOT_LOADED` stub; the `-spec` from the slice
  doc (`ok | {error, not_open} | {error, {unsupported_status, byte()}} | {error,
  invalid_arg}`). Update the module doc line that currently says "send/recv
  arrive in later arcs."

**ASan (`c_src/test/midiio_asan.c`):** add a send loop — open a virtual output,
drive `midiio_dev_send_raw` over each channel type, each system-common/real-time
byte, and a small SysEx; close + uninit. Exercise the SysEx memcpy path. Looped,
`ASAN-OK`, zero leaks.

## Constraints

- snake_case; `-spec` every export; `{ok,_}`/`{error, atom()|tuple()}`.
- **`send` is dirty I/O** (`ERL_NIF_DIRTY_JOB_IO_BOUND`) — the only dirty NIF so
  far. The per-device process serializes calls; **no lock on the send path.**
- No normalization (R6): bytes go out exactly as received.
- Tag the failures we can name; **crash the malformed ones.** Do not wrap the
  adapter in a catch-all that swallows bad input — that hides midilib's bugs.
- The seam is one re-pointable function; the adapter is isolated behind it.

## Out of scope (do not build)

`send_sysex` as a public function (routing is internal, R4); `send_batch/2`
(NEW-1, deferred); inbound / recv / `enif_send` / owner pid (arc 3); the
virtual-loopback **receipt** assertion (arc 3 — you verify send by shape/error +
real-hardware here); UMP; public virtual ports. You may use `mm_out_open_virtual`
**internally for tests**, as in slice 1.

## Done

Every ledger row closed or disclosed-deferred with a re-entry note; `rebar3 as
test check` green (coverage gate stays dormant — `midiio` excluded; the send NIF
is exercised by eunit + ASan, not line coverage); ASan clean over the send path;
the raw seam is a single function with the adapter behind it. Then write
`closing-report.md`; arc-2 close-out (specified-vs-delivered diff) follows once
CDC signs off slice 1 and slice 2. Five-iteration cap — needing more means the
slice was mis-sized; say so rather than grinding.
