# Ledger — arc2/slice2: `send/2` over the raw seam + dirty-I/O

> CC implements + fills **CC evidence**; CDC verifies independently with evidence
> access (reads the code/diff/test output, not CC's summary). Severity:
> **S1** blocker / **S2** major / **S3** minor. Headless-CI rows note where
> hardware is required. Five-iteration cap.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | A single seam fn `midiio_dev_send_raw(res, bytes, len)` is the only path `send/2` takes; the interim adapter is private to it | code read: one static fn; the NIF wrapper does arg/handle/dirty only, no byte-parsing; adapter not referenced elsewhere | S1 | ✓ | `c_src/midiio_send.h:71` defines the one seam fn; the adapter lives entirely in its body. `send_nif` (`midiio_nif.c`) does only resource/binary/length/live checks + result mapping — no `mm_message`/`mm_out_send` anywhere in the wrapper. **Refinement (disclosed):** seam typed `mm_device*` not `midiio_dev_res*` (rationale in header + closing report); name/arity unchanged | |
| 2 | `send/2` registered in `nif_funcs` with `ERL_NIF_DIRTY_JOB_IO_BOUND` | grep `nif_funcs` in `midiio_nif.c`: the `{"send",2,...}` row carries the dirty-I/O flag | S1 | ✓ | `midiio_nif.c` `nif_funcs[]`: `{"send", 2, send_nif, ERL_NIF_DIRTY_JOB_IO_BOUND}` — the only dirty NIF | |
| 3 | Channel messages route to `mm_out_send` with correct type/channel/data | code read: `0x80–0xEF` → `mm_make_message`/struct fill → `mm_out_send`; eunit real-hw or virtual send of note-on/off returns `ok` | S1 | ✓ | `midiio_send.h` `0x80..0xEF` branch → `mm_make_message(b,...)` → `mm_out_send`. eunit `send_channel_messages_test_` (note on/off, poly, CC, 2-byte PC/ChPress, pitch bend) → `ok` on macOS | |
| 4 | SysEx (`0xF0…0xF7`) routes to `mm_out_send_sysex` with the whole binary | code read: `bytes[0]==0xF0` branch passes `(bytes,len)` unchanged; eunit: a small SysEx via virtual output → `ok` | S1 | ✓ | `midiio_send.h`: `if (b==0xF0) return mm_out_send_sysex(dev, bytes, len)` — whole binary, no copy. eunit `send_sysex_test_` → `ok` | |
| 5 | System common + real-time bytes map to the right `mm_message_type` | code read against `mm_out_send`'s switch: `0xF1→MTC_QF`, `0xF2→SONG_POSITION` (14-bit pack `b1\|(b2<<7)`), `0xF3→SONG_SELECT`, `0xF6→TUNE_REQUEST`, `0xF8/FA/FB/FC/FE/FF→CLOCK/START/CONTINUE/STOP/ACTIVE_SENSE/RESET` | S2 | ✓ | `midiio_send.h` by-hand `switch (b)` exactly mirrors `mm_out_send`'s switch (minimidio.h:907), incl. `song_position = bytes[1]\|(bytes[2]<<7)`. eunit `send_system_bytes_test_` covers F1/F2/F3/F6 + all six real-time bytes → `ok` | |
| 6 | Closed/input device → `{error, not_open}` (no crash) | eunit: `open` a virtual output, `close`, then `send(Dev, <<16#90,60,100>>)` → `{error, not_open}` | S1 | ✓ | `send_nif` live gate returns `{error,not_open}` for a closed device (and minimidio's `!is_open` guard backs it). eunit `send_closed_device_test_` → `{error,not_open}` | |
| 7 | Unrecognized/unframable leading status → `{error, {unsupported_status, B}}` | eunit: `send(Dev, <<16#F4,1,2>>)` → `{error, {unsupported_status, 16#F4}}`; `B` is an integer in the tuple, tag atom pre-made in `init_statics` | S1 | ✓ | seam returns `MIDIIO_UNSUPPORTED_STATUS` for `0xF4/F5/F7/F9/FD`; wrapper builds `{error,{unsupported_status, enif_make_uint(b)}}` with pre-made `am_unsupported_status` (`init_statics`). eunit `send_unsupported_status_test_`: F4 → `{error,{unsupported_status,16#F4}}`, plus F5/F9/FD | |
| 8 | Oversized SysEx (> `MM_SYSEX_BUF_SIZE` = 4096) → `{error, invalid_arg}` | eunit: `send(Dev, <<16#F0, (binary:copy(<<0>>,5000))/binary, 16#F7>>)` → `{error, invalid_arg}` | S2 | ✓ | `mm_out_send_sysex` guards `size>MM_SYSEX_BUF_SIZE → MM_INVALID_ARG`; wrapper maps `MM_INVALID_ARG → {error,invalid_arg}`. eunit `send_oversized_sysex_test_` (5000-byte payload) → `{error,invalid_arg}` | |
| 9 | Malformed input crashes (let-it-crash, §6) — not swallowed | eunit `?assertError`: short channel msg `<<16#90,60>>`; leading data byte `<<60,100>>`; empty `<<>>` each raise (badarg/function_clause); no catch-all wraps the adapter | S1 | ✓ | wrapper validates before the seam: empty / `b<0x80` / known-status-wrong-length → `enif_make_badarg`. No `try`/catch-all anywhere. eunit `send_malformed_crashes_test_`: `?assertError(badarg, …)` for short / data-first / empty | |
| 10 | No normalization — bytes emitted exactly as given (R6) | code read: no vel-0/status rewriting anywhere on the send path; the binary reaches `mm_out_send`/`_sysex` byte-for-byte | S2 | ✓ | SysEx is passed as the verbatim binary; channel/system messages reconstruct the exact status/data the caller sent (`mm_make_message`/by-hand fill, then `mm_out_send` re-serializes identically). No vel-0 or running-status rewriting on the path | |
| 11 | `send/2` `-nifs`/`-export`/`nif_error` stub + `-spec`; module doc updated | grep `src/midiio.erl`: `send/2` present in `-nifs`/`-export`; `?NOT_LOADED` stub; `-spec` matches the slice doc; the "send/recv arrive in later arcs" line is updated | S2 | ✓ | `src/midiio.erl`: `send/2` in `-nifs` + `-export`; `?NOT_LOADED` stub; `-spec` = slice-doc union; EDoc added; moduledoc now names arc-2 send + "Inbound (recv) arrives in arc 3" | |
| 12 | Binary handled without an over-living copy | code read: `enif_inspect_binary`; bytes consumed within the call (SysEx is memcpy'd inside `mm_out_send_sysex`, so no NIF-side copy must outlive the call) | S2 | ✓ | `send_nif` uses `enif_inspect_binary`; `bin.data` is read within the call only. No `enif_alloc`/`enif_make_copy` of the payload; SysEx memcpy happens inside `mm_out_send_sysex` into the device buffer | |
| 13 | Send path takes no lock; relies on per-device-process serialization | code read: `send_nif`/seam acquire no mutex; the per-device-context model (slice 1) is what makes this safe; note in the closing report | S2 | ✓ | neither `send_nif` nor `midiio_dev_send_raw` touches `g_uninit_lock` or any mutex. Unlocked `res->live` read is safe (resource reachable as an arg ⇒ no concurrent destructor; per-device process serializes open/send/close). Noted in closing report | |
| 14 | Real-hardware send works (macOS) | macOS, destination present: `open_output(0)`, `send(<<16#90,60,100>>)` then `<<16#80,60,0>>` → `ok` ×2; observably emits (manual) | S2 | ⚐ deferred | No external MIDI instrument/listener on the build box to *observe* emission. The send-to-wire path is exercised by the virtual-output sends (rows 3–5, which use `MIDIReceived`/ALSA subscriber delivery) and the ASan send loop. Audible/observable hardware confirmation deferred to a manual run with a synth — same posture as slice-1's real-hardware row | |
| 15 | `rebar3 xref` + `dialyzer` clean (the new `send/2` spec, incl. the tuple error) | run both; zero findings; the `{unsupported_status, byte()}` union dialyzes | S2 | ✓ | `rebar3 as test check` ran xref + dialyzer with zero findings; the `ok \| {error,not_open} \| {error,{unsupported_status,byte()}} \| {error,invalid_arg}` spec dialyzes clean | |
| 16 | `rebar3 eunit` green (existing + new send tests) | run; all pass, including the error/crash-shape cases | S1 | ✓ | **macOS: 26/26 pass** (19 prior + 7 send). **Linux/ALSA: 26/26 pass** via `make vm-test` (real `snd-virmidi` sequencer; the send rows actually executed) | |
| 17 | `rebar3 as test check` green (coverage gate dormant — `midiio` excluded) | run the alias; exit 0; do **not** re-introduce a `midiio` line-coverage floor for the new NIF stub | S1 | ✓ | `rebar3 as test check` → exit 0 on macOS (compile, xref, dialyzer, eunit, cover). Coverage gate stayed dormant (`midiio` excluded); no floor added for the `send/2` stub | |
| 18 | ASan clean over the send path | extend `c_src/test/midiio_asan.c`: virtual output → loop `midiio_dev_send_raw` over each channel type, each system byte, a small SysEx → close/uninit; `make asan` → `ASAN-OK` | S2 | ✓ | `midiio_asan.c` send block drives `midiio_dev_send_raw` ×200 over every channel type, all 10 system bytes, the unframable `0xF4`, and a SysEx (memcpy path). `make asan` → `ASAN-OK`, zero leaks on **macOS** and on **Linux LeakSanitizer** (via `make vm-test`) | |
| 19 | Seam is re-pointable: swapping to native `mm_out_send_raw` is a one-function change | code read: confirm the seam body is the only place adapter logic lives; a `// TODO(upstream): replace body with mm_out_send_raw when it ships` marks the swap point | S3 | ✓ | `midiio_send.h:71` seam body is the only adapter site; `TODO(upstream)` marks the one-line swap. `mm_device*` signature already matches the expected native shape, so the swap is body-only | |

## Notes / disclosed deferrals

- **No inbound, so no byte-exact receipt assertion this slice.** Correctness of
  the bytes on the wire is verified by the virtual/real send path + the
  `mm_out_send` switch being minimidio's own canonical serializer; the
  **byte-level virtual-loopback round-trip** that proves receipt is arc-3/slice2
  (`DESIGN.md` §9). Disclosed — no faked round-trip.
- **PropEr round-trip deferred to arc 3** for the same reason. A forward-only
  adapter property was **not** added this slice (the deterministic eunit set
  covers every route + the reserved-byte and length boundaries); if added later it
  does not assert receipt.
- **Real-hardware audible send (row 14)** deferred — no instrument/listener on the
  build box. Send-to-wire is covered by virtual sends + ASan.
- **Static-dirty tradeoff (D3, ⚑):** CoreMIDI/WinMM fast sends pay dirty-dispatch
  latency. Accepted for v0.1.0 (row 2 is correct as specified); the conditional
  fast path is a measured post-ship decision, not a row here.
- **Linux/ALSA send** — promoted from disclosed-deferred to **actually run**: the
  `make vm-test` harness (multipass VM with a real ALSA sequencer) executes the
  full eunit suite incl. the send rows + the ASan send loop on Linux. Result
  recorded in the closing report. CI's hosted ubuntu leg still skips them (no
  sequencer), same gate as the other runtime rows.
- **Coverage:** the new NIF stub adds uncovered `midiio.beam` lines — expected and
  fine (module excluded from the gate; eunit + ASan are the real verification).
- Out of scope: `send_sysex` public fn, `send_batch`, inbound, UMP, public
  virtual ports.

## Closing

CC writes `closing-report.md`; CDC writes `cdc-verification.md`. Done when all S1
rows close and no S2 remains open without a written disposition. This slice
closing **completes arc 2's capability** — the arc-2 close-out
(specified-vs-delivered diff) runs once both arc-2 slices have CDC sign-off.
