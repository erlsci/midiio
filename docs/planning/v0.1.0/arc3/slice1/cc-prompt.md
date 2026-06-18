# CC assignment — arc3/slice1: input lifecycle + recv → enif_send (+ F1 close)

> Self-contained. Read the arc plan + slice doc, then implement to the ledger.
> This is the **highest-risk slice of v0.1.0** (the only cross-thread `enif_send`
> path) **and** it closes the carried-over arc2/slice2 finding **F1**. CDC verifies
> on close. Where the exact `enif_*` mechanics are uncertain, **take them from the
> substrate cards, not memory** — this slice is where a wrong signature segfaults
> the VM.

## Posture

Peer-frame, write-to-the-floor. Load **collaboration-framework** + **erlang-
guidelines**. NIF mechanics from the cards: `otp-erts/nif-thread-safety.md`
(enif_send from a non-ERTS thread, `enif_alloc_env`, the mutex API),
`nif-resources.md` (keep/release, the destructor), `nif-lifecycle.md`. Reuse the
existing patterns in `c_src/midiio_nif.c` (the device resource, `init_statics`,
`result_to_atom`, `device_ok`) and `c_src/midiio_send.h` (the outbound seam — the
inbound seam is its mirror).

## Required reading

1. `docs/planning/v0.1.0/arc3/arc-plan.md` (crux #1–#3) + `arc3/slice1/slice-doc.md`.
2. `docs/planning/v0.1.0/arc2/slice2/F1-remediation-cc-prompt.md` + its ledger +
   `arc2/slice2/cdc-verification.md` (**finding F1** — the UAF you're closing).
3. `c_src/minimidio.h` — `mm_in_open` (`:564`), `mm_in_open_virtual` (`:577`),
   `mm_in_start`/`mm_in_stop`/`mm_in_close` (`:568`/`:569`/`:570`), the `mm_callback`
   typedef + the "background thread" contract (`:353`), the `mm_message` struct
   (`:315`), and `mm_out_send`'s switch (`:903`) — read **backwards** for the
   inbound seam (mm_message → bytes), the inverse of `midiio_send.h`'s adapter.
4. `docs/NIF-LEARNINGS.md` L01 (cross-resource/keep), L03 (enif_send from thread),
   L04 (copy transient SysEx during the callback), L05 (mutex for shared state).

## What to build

### 1. The per-device lock + resource refit (the F1 close — do this first)

- Extend `midiio_dev_res` with `int is_input; ErlNifPid owner; ErlNifMutex *lock;`.
- Create `lock` in **every** `open_*` (output too); **destroy it in the destructor
  last** — after the final cleanup, never while held. (Resource memory is reachable
  while the handle is an argument, so no concurrent destructor races a live op;
  the destructor runs at refcount 0.)
- **Retrofit `send_nif`** (arc 2): take `res->lock`, check `live`, do the
  `mm_out_send*` call, release. **Retrofit `do_dev_cleanup`**: take `res->lock`
  (replace the global `g_uninit_lock` for *device* ops), check/flip `live`,
  `mm_*_close` + `mm_context_uninit`, release. Now send-vs-close cannot UAF.
- Keep the lock **per-device** (uncontended under single-owner → preserves §4 D3's
  realtime intent). Do **not** reach for the global lock on the send path.

### 2. Input lifecycle

- `open_input(Index, Owner)`: per-device embedded context (the arc-2 model);
  `mm_in_open(&res->ctx, &res->dev, Index, recv_cb, res)`; `res->is_input=1`;
  `res->owner = Owner`; **`enif_keep_resource(res)`** (the recv thread holds `res`).
  Partial-failure cleanup as in `open_output`.
- `start_input/1` → `mm_in_start`; `stop_input/1` → `mm_in_stop` **then**
  `enif_release_resource` (release only after stop, so no callback can fire against
  a released resource) — guarded so double-stop is a clean no-op.
- `set_owner(Dev, Pid)`: write `res->owner` under `res->lock`.
- Extend `close/1`/`do_dev_cleanup` for inputs: `mm_in_stop` + `mm_in_close`
  (alongside the existing `mm_out_close` for outputs), still `live`-guarded,
  port-before-context, and **release the keep** exactly once.

### 3. The recv callback (cross-thread)

`recv_cb(dev, msg, userdata=res)` on the backend thread:
- `ErlNifEnv *menv = enif_alloc_env();`
- bytes via the **inbound seam** `serialize_to_bytes(menv, msg)` (mirror of
  `midiio_send.h`; **`memcpy` SysEx into the binary during the callback** — the
  `msg->sysex` pointer is callback-lifetime only).
- `TsNanos` = host-monotonic int64 ns (R5; `0` if absent).
- `term = {midi_in, enif_make_resource(menv,res), Bytes, TsNanos}`.
- read `owner` under `res->lock`; `enif_send(NULL, &owner, menv, term)`;
  `enif_free_env(menv)`. (caller_env NULL; env invalidated on send.)

### 4. Erlang (`src/midiio.erl`)

`open_input/2`, `start_input/1`, `stop_input/1`, `set_owner/2` in
`-nifs`/`-export` with `?NOT_LOADED` stubs + `-spec`s; `close/1` spec unchanged.
Pre-make `am_midi_in` (and any new atoms) in `init_statics`. Update the moduledoc
(the F1 doc-remediation will have set the ownership contract — keep it consistent).

## Constraints

- The recv path touches **no scheduler state** — only the process-independent env +
  the per-device lock + `enif_send`. Do not call `mm_in_stop`/`close` from the
  callback (`:353`).
- One owner pid (no multicast — fan-out is `midi`'s job, R3). No normalization (R6).
- `-spec` every export; atoms pre-made; let a bad handle crash (`badarg`).

## Out of scope

The conformance taxonomy + quirk cases (U1–U3/S1) → **slice 2**; UMP; WinMM;
public virtual ports; `send_batch`; `enif_monitor_process` owner-death cleanup
(§7 baseline is GC-of-handle). Slice 1 proves **one** message arrives + F1 closed.

## Testing (see slice-doc)

One-message virtual loopback (headless); the **F1 tripwire** (two procs, shared
handle, send-vs-close, ASan/TSan-clean); lifecycle ASan loop; `set_owner` redirect;
**run under `make vm-test`** for the ALSA recv-pthread path. `rebar3 as test check`
green. If the slice won't fit one context, split 1a/1b per the slice-doc and
disclose.

## Done

Owner receives one intact `{midi_in, Dev, <<bytes>>, TsNanos}`; **F1 closed** (the
tripwire is clean) and the `arc2/slice2` F1 record updated to "structurally closed
in arc3/slice1"; ASan clean over the inbound lifecycle; `check` green; the inbound
seam is one re-pointable function. Write `closing-report.md`. Five-iteration cap —
needing more means split the slice, don't grind.
