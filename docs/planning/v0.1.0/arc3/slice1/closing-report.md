# Closing report — arc3/slice1: input lifecycle + recv → enif_send (+ F1 close)

> CC's per-row walk (full table in `ledger.md`). The highest-risk slice of
> v0.1.0 — the only cross-thread `enif_send` path — **and** the structural close of
> the carried-over arc2/slice2 finding **F1**. Host: macOS arm64 (CoreMIDI),
> OTP 28. Date: 2026-06-18. Iteration: 1. **Done in one context, not split.**

## What was built

**Job B — F1 close (done first).** `midiio_dev_res` grew a per-device
`ErlNifMutex *lock` (+ `is_input`, `owner`, `kept`). It is created in every
`open_*` (`new_device`) and **destroyed last in the destructor** (after the final
cleanup, never while held). `send_nif` now does the `live`-check **and** the
`mm_out_send*` deref under `res->lock`; `do_dev_cleanup` tears the device down
under the same lock. The unlocked-`live`-read UAF from arc2/slice2 is gone by
construction. The shared `g_uninit_count` became `atomic_int` (device cleanup no
longer runs under the global lock).

**Job A — inbound delivery.**
- `open_input(Index, Owner)`: per-device embedded context, `mm_in_open(…, recv_cb,
  res)`, `enif_keep_resource` (the backend thread holds `res`), partial-failure
  cleanup. `start_input`/`stop_input` → `mm_in_start`/`mm_in_stop`; the keep is
  released **after** `mm_in_stop`, exactly once (`kept`-guarded), by whichever of
  stop/close/dtor reaches it first. `set_owner/2` writes `owner` under the lock.
  `close/1`/`do_dev_cleanup` extended for inputs (`mm_in_stop`+`mm_in_close`).
- `recv_cb` (backend thread): a process-independent `enif_alloc_env` per delivery;
  bytes via the new inbound seam `c_src/midiio_recv.h` (`midiio_msg_to_bytes`, the
  inverse of `midiio_send.h`) with **SysEx `memcpy`'d during the callback** (never
  aliasing the callback-lifetime pointer); host-monotonic **int64 ns** timestamp;
  owner read under the lock; `enif_send(NULL, …)`; `enif_free_env`.
- Erlang: `open_input/2`, `start_input/1`, `stop_input/1`, `set_owner/2` with
  stubs + specs; `am_midi_in` pre-made.

## Disposition

**20 of 21 rows done; 1 disclosed-deferred (row 21, Linux/`make vm-test`).** All
S1 rows closed. Highlights:

- **F1 closed (rows 3–6) — the headline.** The send-vs-close tripwire is clean
  over 25 BEAM rounds (real `send_nif`/`do_dev_cleanup`), and the standalone
  lock-discipline tripwire is **ASan- *and* TSan-clean** (50× pthread send-vs-close).
- **One message intact (row 11).** The owner receives
  `{midi_in, In, <<16#90,60,100>>, Ts}` with `Dev =:= In` (R2 identity), byte-exact
  bytes, integer timestamp — the first real loopback, on the first try.
- **Cross-thread safety (rows 12–13).** Process-independent env, `NULL` caller_env,
  SysEx copied during the callback; ASan-clean over the seam + input lifecycle.
- **set_owner redirect (row 10)** and **input close/double-close (row 9)** pass.
- `rebar3 as test check` green (31 tests, dialyzer/xref clean, coverage dormant).

## Disclosed decisions / deviations

1. **`kept` field added** to `midiio_dev_res` (beyond the slice-doc's `is_input`/
   `owner`/`lock`): the recv-thread keep must be released **exactly once** across
   {stop_input, close, dtor}, which needs a flag. Documented in the struct comment.
2. **Input keep ⇒ explicit stop/close required (limitation).** While the keep is
   held (open→stop), the resource refcount is ≥ 1, so a *dropped* input handle
   that was never stopped/closed will not GC-collect (the GC-of-handle §7 baseline
   applies cleanly to outputs and to inputs *after* stop/close). Prompt-monitor
   cleanup (`enif_monitor_process`) is explicitly out of scope for v0.1.0; this is
   the accepted residual, to be closed when monitor-cleanup lands.
3. **Sanitizer tripwire is a faithful replica.** The BEAM-loaded `.so` can't be
   ASan/TSan-instrumented, so the standalone tripwire mirrors the per-device-lock
   discipline with a `pthread_mutex` (same check-and-use vs teardown shape). The
   *real* `send_nif`/`do_dev_cleanup` are exercised by the BEAM tripwire (no crash).
4. **Loopback uses a virtual output source + real `open_input`** (no
   `open_input_virtual` test NIF needed): `open_output_virtual` is a system source,
   and a real `open_input` connects to it — headless-safe on CoreMIDI / snd-virmidi.

## Out of scope (untouched)

The conformance taxonomy + U1–U3/S1 quirks (slice 2), UMP, WinMM, public virtual
ports, `send_batch`, and monitor-based owner-death cleanup. Slice 1 proves **one**
message arrives + F1 closed; both are done.
