# arc3/slice1 — input lifecycle + recv → enif_send (+ the F1 structural close)

> Plan-of-record. Parent: `arc3/arc-plan.md`. The **data-bearing inbound slice**
> and the **cross-thread risk peak of v0.1.0**. It also **structurally closes the
> carried-over arc2/slice2 finding F1** (the send/close UAF) — because the
> per-device lock arc 3 needs for the owner pid is the same lock that guards
> send/close/teardown. Design refs: `DESIGN.md` §3 (inbound threading, term shape,
> timestamp), §5 (handle = identity), §7 (lifecycle, owner mutex), §9 (testing);
> `arc3/arc-plan.md` crux #1–#3; `RESEARCH-nif.md` Findings A (parsed inbound,
> SysEx copy) and the L01/L03/L04/L05 learnings.

## Two jobs, one lock

**Job A — inbound delivery.** Open an input device, and when minimidio's callback
fires on a **non-ERTS background thread**, hand the owner process
`{midi_in, Dev, <<Bytes>>, TsNanos}` — one complete message per delivery, via
`enif_send` from that foreign thread.

**Job B — close F1 (carried over).** arc2/slice2's `send_nif` reads `res->live`
*unlocked* and then dereferences the device handles, racing `close/1`'s teardown →
a use-after-free reachable from safe Erlang (two processes sharing one `device()`).
The fix is a **per-device mutex** that guards the device's critical sections. Arc 3
needs that mutex anyway (the recv thread reads `owner` while `set_owner/2` writes
it), so we add it **once** and have it guard *all* of: owner R/W, `send`'s
live-check-and-use, and cleanup's teardown. F1 is then closed by construction; the
arc2/slice2 doc-remediation already states the contract this makes real.

## Surface (Erlang)

```erlang
-spec open_input(Index :: non_neg_integer(), Owner :: pid()) ->
        {ok, device()} | {error, atom()}.
-spec start_input(device()) -> ok | {error, atom()}.
-spec stop_input(device())  -> ok | {error, atom()}.
-spec set_owner(device(), pid()) -> ok.
%% close/1 is the existing unified close — extended to handle input devices.
%% Inbound (delivered to Owner): {midi_in, device(), <<Bytes>>, TsNanos :: integer()}
```

`open_input` takes a **bare index** (the device owns its context, per the arc-2 ⚑;
matches `open_output/1`). *(DESIGN §1 wrote `open_input(Ctx, Index, Owner)`; flag
if you want `Ctx` back.)*

## The resource grows (refines arc2/slice1)

```c
typedef struct {
    mm_context  ctx;
    mm_device   dev;
    int         live;
    int         is_input;     /* output devices never set an owner */
    ErlNifPid   owner;        /* the recv target; written by set_owner */
    ErlNifMutex *lock;        /* per-device; guards owner + send + cleanup */
} midiio_dev_res;
```

One struct, owner inert for outputs, one unified `close/1`, one destructor —
per the arc-plan crux #2. *(Flag if you'd rather split input/output into two
resource types; the plan's position is one struct.)*

## The per-device lock — what it guards (the F1 close)

The lock is created at **every** `open_*` (output too — this is the F1 retrofit)
and destroyed in the destructor **last** (after the final cleanup; never while
held). It guards three critical sections, all per-device (so **uncontended under
the single-owner contract** — the realtime latency intent of §4 D3 is preserved;
the lock only ever serializes the pathological cross-process race it exists to make
safe):

1. **`send_nif`** (retrofit): take the lock, check `live`, do the `mm_out_send*`
   call, release. Now a concurrent `close` cannot tear the handles down mid-send.
2. **cleanup** (`do_dev_cleanup`, retrofit): take the **per-device** lock (replace
   the global `g_uninit_lock` for device ops), check/flip `live`, `mm_*_close` +
   `mm_context_uninit`, release.
3. **owner R/W**: the recv thread reads `owner` under the lock; `set_owner/2`
   writes it under the lock.

## Inbound delivery (the cross-thread crux)

`recv_cb(mm_device *dev, const mm_message *msg, void *userdata)` runs on the
backend thread (`userdata` = the kept `midiio_dev_res*`):

- Build the term in a **process-independent env** (`enif_alloc_env` per delivery):
  `{midi_in, enif_make_resource(menv,res), BytesBin, TsNanos}`.
- **Inbound raw seam** `serialize_to_bytes(menv, msg)` — the inverse of arc-2's
  outbound adapter (`mm_message` → exact wire bytes); interim adapter behind the
  seam, the `mm_in_open_raw` swap point. **SysEx is callback-lifetime only**
  (Finding A.3) — `memcpy` it into the binary *during* the callback, never alias.
- **Timestamp**: integer **nanoseconds, host-monotonic** (R5; the struct's
  "seconds since open" comment is wrong — it's mach/`CLOCK_MONOTONIC` since boot);
  `0`/absent → `0` ("now").
- Read `owner` under the per-device lock; `enif_send(NULL, &owner, menv, term)`
  (caller_env NULL — not an ERTS thread); `enif_free_env(menv)`.

**Resource lifetime across the thread (crux #1 — leak/UAF hotspot).** The
background thread holds `res` as `userdata`, so it must not be freed while the
callback is registered: `open_input` does `enif_keep_resource`; the release happens
**after `mm_in_stop`** (no more callbacks) in `stop_input`/`close`/the destructor —
exactly once, on the `live`-style guard. ASan owns proving this.

## Testing

- **One message intact (the slice's core, headless):** open a **virtual
  destination** (`mm_in_open_virtual`) as the input + an arc-2 `open_output_virtual`
  in the same VM; `send` one note-on; assert the owner receives
  `{midi_in, Dev, <<16#90,60,100>>, Ts}` with `is_integer(Ts)`. The first real
  loopback. (Full taxonomy + quirks = slice 2.)
- **F1 concurrency tripwire (the green-by-construction test the F1 ledger defers
  here):** two processes share one output handle; one loops `send`, the other
  `close`s; under **ASan/TSan** there is **no** use-after-free / data race. This is
  what proves F1 closed.
- **Lifecycle ASan:** open→start→deliver→stop→close→GC, looped → `ASAN-OK`, zero
  leaks (the keep/release + the mutex-destroyed-last lifecycle).
- **Owner re-set:** `set_owner/2` redirects delivery; mutex-guarded; eunit.
- **Linux/ALSA:** run the above under `make vm-test` (the snd-virmidi harness) —
  the recv pthread path is ALSA-specific and now actually runnable on Linux.
- `rebar3 as test check` green; coverage stays dormant (`midiio` excluded).

## Sizing (per the arc-plan)

This is large (recv path + the resource/lock refit + timestamp + the F1 retrofit).
If it won't fit one context with iteration headroom, **split**: **1a** = lifecycle
(`open_input`/`start`/`stop`/`close`/`set_owner`) + the per-device lock + the F1
retrofit + keep/release + the tripwire (a minimal counting recv_cb proves the
thread fires); **1b** = the real recv term-build + inbound seam + timestamp + the
one-message loopback. Decide at the cc-prompt; disclose if you split.

## Acceptance

Every ledger row closed or disclosed-deferred; an owner receives one intact
`{midi_in, ...}`; **F1 is closed** (the tripwire is ASan/TSan-clean) and the
arc2/slice2 F1 record is updated to "closed here"; ASan clean over the inbound
lifecycle; `check` green. CDC verifies.
