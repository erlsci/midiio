# Ledger — arc2/slice2: `send/2` over the raw seam + dirty-I/O

> CC implements + fills **CC evidence**; CDC verifies independently with evidence
> access (reads the code/diff/test output, not CC's summary). Severity:
> **S1** blocker / **S2** major / **S3** minor. Headless-CI rows note where
> hardware is required. Five-iteration cap.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | A single seam fn `midiio_dev_send_raw(res, bytes, len)` is the only path `send/2` takes; the interim adapter is private to it | code read: one static fn; the NIF wrapper does arg/handle/dirty only, no byte-parsing; adapter not referenced elsewhere | S1 | ☐ | | |
| 2 | `send/2` registered in `nif_funcs` with `ERL_NIF_DIRTY_JOB_IO_BOUND` | grep `nif_funcs` in `midiio_nif.c`: the `{"send",2,...}` row carries the dirty-I/O flag | S1 | ☐ | | |
| 3 | Channel messages route to `mm_out_send` with correct type/channel/data | code read: `0x80–0xEF` → `mm_make_message`/struct fill → `mm_out_send`; eunit real-hw or virtual send of note-on/off returns `ok` | S1 | ☐ | | |
| 4 | SysEx (`0xF0…0xF7`) routes to `mm_out_send_sysex` with the whole binary | code read: `bytes[0]==0xF0` branch passes `(bytes,len)` unchanged; eunit: a small SysEx via virtual output → `ok` | S1 | ☐ | | |
| 5 | System common + real-time bytes map to the right `mm_message_type` | code read against `mm_out_send`'s switch: `0xF1→MTC_QF`, `0xF2→SONG_POSITION` (14-bit pack `b1|(b2<<7)`), `0xF3→SONG_SELECT`, `0xF6→TUNE_REQUEST`, `0xF8/FA/FB/FC/FE/FF→CLOCK/START/CONTINUE/STOP/ACTIVE_SENSE/RESET` | S2 | ☐ | | |
| 6 | Closed/input device → `{error, not_open}` (no crash) | eunit: `open` a virtual output, `close`, then `send(Dev, <<16#90,60,100>>)` → `{error, not_open}` | S1 | ☐ | | |
| 7 | Unrecognized/unframable leading status → `{error, {unsupported_status, B}}` | eunit: `send(Dev, <<16#F4,1,2>>)` → `{error, {unsupported_status, 16#F4}}`; `B` is an integer in the tuple, tag atom pre-made in `init_statics` | S1 | ☐ | | |
| 8 | Oversized SysEx (> `MM_SYSEX_BUF_SIZE` = 4096) → `{error, invalid_arg}` | eunit: `send(Dev, <<16#F0, (binary:copy(<<0>>,5000))/binary, 16#F7>>)` → `{error, invalid_arg}` | S2 | ☐ | | |
| 9 | Malformed input crashes (let-it-crash, §6) — not swallowed | eunit `?assertError`: short channel msg `<<16#90,60>>`; leading data byte `<<60,100>>`; empty `<<>>` each raise (badarg/function_clause); no catch-all wraps the adapter | S1 | ☐ | | |
| 10 | No normalization — bytes emitted exactly as given (R6) | code read: no vel-0/status rewriting anywhere on the send path; the binary reaches `mm_out_send`/`_sysex` byte-for-byte | S2 | ☐ | | |
| 11 | `send/2` `-nifs`/`-export`/`nif_error` stub + `-spec`; module doc updated | grep `src/midiio.erl`: `send/2` present in `-nifs`/`-export`; `?NOT_LOADED` stub; `-spec` matches the slice doc; the "send/recv arrive in later arcs" line is updated | S2 | ☐ | | |
| 12 | Binary handled without an over-living copy | code read: `enif_inspect_binary`; bytes consumed within the call (SysEx is memcpy'd inside `mm_out_send_sysex`, so no NIF-side copy must outlive the call) | S2 | ☐ | | |
| 13 | Send path takes no lock; relies on per-device-process serialization | code read: `send_nif`/seam acquire no mutex; the per-device-context model (slice 1) is what makes this safe; note in the closing report | S2 | ☐ | | |
| 14 | Real-hardware send works (macOS) | macOS, destination present: `open_output(0)`, `send(<<16#90,60,100>>)` then `<<16#80,60,0>>` → `ok` ×2; observably emits (manual) | S2 | ☐ | | |
| 15 | `rebar3 xref` + `dialyzer` clean (the new `send/2` spec, incl. the tuple error) | run both; zero findings; the `{unsupported_status, byte()}` union dialyzes | S2 | ☐ | | |
| 16 | `rebar3 eunit` green (existing + new send tests) | run; all pass, including the error/crash-shape cases | S1 | ☐ | | |
| 17 | `rebar3 as test check` green (coverage gate dormant — `midiio` excluded) | run the alias; exit 0; do **not** re-introduce a `midiio` line-coverage floor for the new NIF stub | S1 | ☐ | | |
| 18 | ASan clean over the send path | extend `c_src/test/midiio_asan.c`: virtual output → loop `midiio_dev_send_raw` over each channel type, each system byte, a small SysEx → close/uninit; `make asan` → `ASAN-OK` | S2 | ☐ | | |
| 19 | Seam is re-pointable: swapping to native `mm_out_send_raw` is a one-function change | code read: confirm the seam body is the only place adapter logic lives; a `// TODO(upstream): replace body with mm_out_send_raw when it ships` marks the swap point | S3 | ☐ | | |

## Notes / disclosed deferrals

- **No inbound, so no byte-exact receipt assertion this slice.** Correctness of
  the bytes on the wire is verified by real-hardware send (row 14) + the
  `mm_out_send` switch being minimidio's own canonical serializer; the
  **byte-level virtual-loopback round-trip** that proves receipt is arc-3/slice2
  (`DESIGN.md` §9). Disclose this in the closing report — do not fake a
  round-trip without an inbound path.
- **PropEr round-trip deferred to arc 3** for the same reason. A forward-only
  adapter property (well-formed → routes/lengths OK; reserved → `unsupported_status`)
  is optional here; if added, it does **not** assert receipt. State the boundary.
- **Static-dirty tradeoff (D3, ⚑):** CoreMIDI/WinMM fast sends pay dirty-dispatch
  latency. Accepted for v0.1.0 (row 2 is correct as specified); the conditional
  fast path is a measured post-ship decision, not a row here.
- **Linux/ALSA send** is verified by code read on CC's macOS box; CI's ubuntu leg
  exercises it where the runner provides a sequencer — same re-entry as the other
  deferred-Linux rows from slice 1.
- **Coverage:** the new NIF stub adds uncovered `midiio.beam` lines — expected and
  fine (module excluded from the gate; eunit + ASan are the real verification).
- Out of scope: `send_sysex` public fn, `send_batch`, inbound, UMP, public
  virtual ports.

## Closing

CC writes `closing-report.md`; CDC writes `cdc-verification.md`. Done when all S1
rows close and no S2 remains open without a written disposition. This slice
closing **completes arc 2's capability** — the arc-2 close-out
(specified-vs-delivered diff) runs once both arc-2 slices have CDC sign-off.
