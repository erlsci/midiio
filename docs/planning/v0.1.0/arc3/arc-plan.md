# Arc 3 — Inbound transport & conformance (plan-of-record)

> SDLC step 4 for arc 3. Capability: open an input device, receive
> `{midi_in, Dev, <<Bytes>>, TsNanos}` — one complete, status-complete message
> per delivery — to a single owner pid; then prove the whole transport with a
> byte-level virtual-loopback conformance suite that `midi` can build its
> integration test on top of. This is the **last arc of v0.1.0**; it closes the
> success criteria in `PROJECT-DEFINITION.md`. Design refs: `DESIGN.md` §1
> (surface), §3 (inbound threading + term shape + timestamp), §5 (handle =
> identity), §7 (lifecycle/reentrancy, owner mutex), §9 (testing/conformance).

## The crux: cross-thread delivery (concretizing §3) ⚑

Outbound (arc 2) was driven *from* the owning Erlang process — synchronous, no
foreign threads. Inbound inverts that and is **the genuine new risk of v0.1.0**:
minimidio invokes our `mm_callback` on a **non-ERTS background thread** (the
CoreMIDI read-proc thread / an ALSA per-device `pthread` / the WinMM callback
thread), and we must hand a term to an Erlang process *from there*. The contract
(`minimidio.h:353`: "Called from a background thread. Do NOT call
mm_in_stop/close from within") shapes the whole arc.

**Decision (⚑ — confirm before CC builds):** the recv callback builds the term in
a **process-independent environment** and posts it with `enif_send` from the
foreign thread, touching no scheduler state:

```c
/* recv_cb(mm_device *dev, const mm_message *msg, void *userdata)
   userdata = the kept midiio_dev_res*  */
ErlNifEnv *menv = enif_alloc_env();
ERL_NIF_TERM bytes = serialize_to_binary(menv, msg);   /* inbound raw seam */
ERL_NIF_TERM ts    = enif_make_int64(menv, host_monotonic_ns(msg));
ERL_NIF_TERM term  = enif_make_tuple4(menv, am_midi_in,
                         enif_make_resource(menv, res), bytes, ts);
ErlNifPid owner; enif_mutex_lock(res->owner_lock);     /* §7: pid read cross-thread */
owner = res->owner; enif_mutex_unlock(res->owner_lock);
enif_send(NULL, &owner, menv, term);                   /* caller_env = NULL */
enif_free_env(menv);
```

Three sub-decisions fall out, each a place CC must not improvise:

1. **Resource lifetime across the thread (⚑).** The background thread holds a raw
   `midiio_dev_res*` as `userdata`. The resource must **not** be GC-freed while
   the callback is registered. `open_input` / `start_input` does
   `enif_keep_resource`; `stop_input` / `close` / the destructor does
   `enif_release_resource` — exactly once, on the same `live`-style guard as
   slice-1 cleanup. This is the inbound analogue of arc-2's destructor discipline
   and the easiest place to leak or use-after-free. ASan owns proving it.

2. **The device resource grows an owner + mutex (⚑ — refines arc-2/slice1).**
   Arc-2 shipped `midiio_dev_res = { mm_context ctx; mm_device dev; int live; }`.
   Arc 3 extends it to carry `ErlNifPid owner;` and an `ErlNifMutex *owner_lock;`
   (or a per-resource lock), because the recv thread reads the pid while
   `set_owner/2` may write it (`DESIGN.md` §7). Output devices simply never set an
   owner — the field is inert for them. Flag if you'd rather split input/output
   into two resource types instead of one shared struct; the plan's position is
   **one struct, owner inert for outputs** (uniform `close/1`, one destructor).

3. **The inbound raw seam.** Symmetric to arc-2's outbound seam: one function
   `serialize_to_binary(menv, msg)` turns an `mm_message` back into the exact wire
   bytes (the inverse of arc-2's adapter). Same upstream gate — native
   `mm_in_open_raw` has **not** shipped (confirmed against the pinned header; only
   `mm_in_open` (`:564`) / `mm_in_open_virtual` (`:577`) exist), so the interim
   inbound adapter lives behind the seam and is the swap point when it lands. The
   SysEx pointer in `msg` is **callback-lifetime only** (`DESIGN.md` §3, Finding
   A.3) — copy it into the binary *during* the callback, never alias it.

**Timestamp (R5 / §3).** Emit **integer nanoseconds, host-monotonic**, raw (not
rebased), so devices on a host share an origin. The struct's `double timestamp`
"seconds since open" comment is wrong — the value's real domain is
mach/`CLOCK_MONOTONIC` since boot; convert to int64 ns. Zero/absent (some
CoreMIDI paths) passes through as `0` = "now". Whether it is directly comparable
to `midi`'s `erlang:monotonic_time` send clock is **to be verified, not
promised**.

## Slice breakdown

**Slice 1 — input lifecycle + recv → `enif_send`.** The data-bearing slice.
- `open_input(Index, OwnerPid) -> {ok, Dev}`: per-device embedded context (the
  arc-2 model), `mm_in_open(&ctx, &dev, Index, recv_cb, res)`; set
  `res->owner = OwnerPid`; `enif_keep_resource`. *(Surface note: `DESIGN.md` §1
  wrote `open_input(Ctx, Index, OwnerPid)`; per the arc-2 ⚑ the device owns its
  context, so this is `open_input(Index, OwnerPid)` — a **bare index**,
  matching `open_output/1`. Flag if you want the `Ctx` param back for
  forward-compat.)*
- `start_input/1`, `stop_input/1` → `mm_in_start`/`mm_in_stop` (`:568`/`:569`).
- `set_owner(Dev, Pid) -> ok`: mutex-guarded write of `res->owner` (§7).
- `close/1`: **reuses the slice-1 unified close** — extend `do_dev_cleanup` to
  `mm_in_stop` + `mm_in_close` + `enif_release_resource` for inputs, alongside
  the existing `mm_out_close` for outputs, still `live`-guarded and port-before-
  context.
- The recv callback + process-independent env + inbound raw seam + int64-ns
  timestamp, per the crux. **No conformance taxonomy yet** — slice 1 proves *one*
  message arrives intact to the owner; slice 2 proves *all* of them do.
- Verified headlessly with a **virtual destination** (`mm_in_open_virtual`,
  `:577`) fed by an arc-2 `send` in the same VM — the first real loopback.

**Slice 2 — virtual-loopback conformance + quirk cases.** The proof slice; no new
public surface.
- Open a **virtual source** (arc-2 `open_output_virtual`) + a **virtual
  destination** (`open_input` on `mm_in_open_virtual`) in one VM; `send` each
  member of the message taxonomy and assert the **exact bytes** arrive in the
  `{midi_in, ...}` term (`DESIGN.md` §9). This is the byte-level transport
  conformance — independent of `midilib`'s codec (R7), **Erlang-drivable** so
  `midi` builds its through-terms integration test on top (R8).
- **PropEr** for the bytes⇄`mm_message` bridge across both seams: no dropped
  status, correct data-byte count, 14-bit song-position intact, SysEx of varied
  lengths byte-exact. This is where arc-2/slice2's deferred round-trip property
  finally closes.
- **Explicit quirk cases (U1–U3, S1)** from `DESIGN.md` §9, each **green or a
  disclosed expected-fail with a tracked rationale**: U1 large-SysEx on a
  CoreMIDI virtual source (cap — upstream); S1 inbound SysEx spanning more than
  one packet (flush the suspected truncation); plus the backend note-on-vel-0
  pass-through (R6 — assert midiio does **not** normalize it).

> **Upstream gate (both slices):** if the maintainer ships `mm_in_open_raw` by
> the time this arc runs, the inbound seam targets it directly and the interim
> adapter is deleted — **nothing above the seam changes.** If not (the state
> today), the adapter lives behind the seam as designed.

## What's deliberately out of arc 3 (and out of v0.1.0)

Multicast/fan-out inbound (one owner pid; fan-out is `midi`'s job, R3); virtual
ports as a **public** surface (used internally for the loopback only); UMP /
MIDI 2.0; WinMM bring-up + CI; WebMIDI/Emscripten; `send_batch/2` (NEW-1, still
open with `midi`); `enif_monitor_process`-based prompt owner-death cleanup
(§7 baseline is GC-of-handle; monitor is noted, not built). All named and tracked
in `PROJECT-DEFINITION.md`, not dropped.

## Sizing notes & risks

- **Slice 1 is the riskiest in the project after arc1/slice1** — it's the only
  cross-thread `enif_send` path. The resource-lifetime keep/release (crux #1) and
  the owner mutex (crux #2) are where a leak or a use-after-free hides; ASan over
  open→start→deliver→stop→close→GC, looped, is the load-bearing test, exactly as
  the arc-2 device-lifecycle loop was.
- **Slice 2 depends on virtual ports working** on the host; U1 caps its
  large-SysEx assertions on CoreMIDI (disclosed expected-fail, not a failure).
- **The interim inbound adapter is throwaway**, isolated behind the seam; the
  `mm_*_raw` swap stays a one-file change.
- If slice 1 won't fit one context with iteration headroom (the recv path + the
  resource-struct change + the timestamp domain together), **split it**: lifecycle
  (open/start/stop/close/set_owner + keep/release) as slice 1a, the recv callback
  + seam + timestamp as slice 1b. Decide at the cc-prompt, disclose if so.

## Close-out

Arc 3 closes — and **v0.1.0's planning arc completes** — when: an owner process
receives `{midi_in, Dev, <<Bytes>>, TsNanos}`, one complete message per delivery,
byte-exact w.r.t. what minimidio delivers; the virtual-loopback suite round-trips
the taxonomy green (U1–U3/S1 green-or-disclosed); a crashing owner leaks no OS
handle (destructor + release path); and the specified-vs-delivered diff across
all three arcs shows no silent drops. Then the v0.1.0 success criteria in
`PROJECT-DEFINITION.md` are all met or explicitly-deferred-with-rationale.
