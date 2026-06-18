# CC assignment — arc3/slice1 remediation: close-deadlock + started-input leak

> A focused remediation of two CDC findings on `6466293`
> (`arc3/slice1/cdc-verification.md`): an **S1 deadlock** on the input close path
> and an **S2 leak** of a started-and-abandoned input. Both live in the same
> place (the input lifecycle / per-device lock), so fix them together. The F1
> output close, the recv path, and everything else in slice 1 are **correct — do
> not touch them** beyond what these two fixes require. CDC re-verifies on close.

## Posture

Peer-frame, write-to-the-floor. Load **collaboration-framework** + **erlang-
guidelines**. The `enif_monitor_process` mechanics (the `down` callback, the
`ErlNifResourceTypeInit` struct, the keep/free interaction inside `down`) are
**exactly the kind of thing to take from the substrate cards, not memory** —
`otp-erts/nif-resources.md` (resource type init + monitor `down`),
`nif-thread-safety.md`. Where the exact `down`-vs-free ordering is uncertain,
**read the card / the `erl_nif` ref and report what it actually guarantees.**

## Required reading

1. `arc3/slice1/cdc-verification.md` — the S1 (deadlock) and S2 (leak) findings.
2. `c_src/midiio_nif.c` — `do_dev_cleanup` (`:165–202`), `dtor_device`,
   `recv_cb` (`:492`), `open_input`/`start_input`/`stop_input`/`set_owner`,
   `init_statics` (resource-type registration), `new_device`.
3. `c_src/minimidio.h` — **ALSA `mm_in_stop` `:1607–1613`** (it `pthread_join`s the
   recv thread — that join is why the lock-ordering matters).

## Fix 1 — S1 deadlock: move the join OUTSIDE `res->lock`

**The bug:** `do_dev_cleanup` holds `res->lock` across `mm_in_stop` (`:176`), which
`pthread_join`s the recv thread; but `recv_cb` needs `res->lock` to read `owner`
(`:522`). Close-during-active-delivery → the close thread joins (holding the lock)
while the recv thread blocks on the lock → deadlock.

**The fix** — restructure `do_dev_cleanup` so the lock guards only the `live` flip,
and the teardown (the join) runs unlocked:

```c
enif_mutex_lock(res->lock);
int was_live = res->live;
if (was_live) res->live = 0;            /* flip under the lock — exactly-once */
int release_keep = 0;
if (res->kept) { res->kept = 0; release_keep = 1; }
enif_mutex_unlock(res->lock);
if (was_live) {                          /* teardown OUTSIDE the lock */
    if (res->is_input) { mm_in_stop(&res->dev); mm_in_close(&res->dev); }
    else               { mm_out_close(&res->dev); }
    mm_context_uninit(&res->ctx);
    atomic_fetch_add(&g_uninit_count, 1);
}
if (release_keep) enif_release_resource(res);
return was_live;
```

**Why this still closes F1 (verify, don't take on faith):** `send_nif` derefs the
handles only when `live==1` *and* under `res->lock`. Cleanup sets `live=0` under
the same lock **before** any teardown. So either send ran fully (under the lock)
before cleanup flipped `live`, or send sees `live==0` and returns `{error,
not_open}` without a deref. A `recv_cb` firing in the post-flip gap reads `owner`
under the (now-free) lock and sends a last in-flight message against a still-valid
resource; `mm_in_stop` then joins it cleanly. No deadlock, F1 intact.

## Fix 2 — S2 leak: `enif_monitor_process` the owner

**The bug:** a started input whose owner drops the handle without stop/close leaks
— the recv-thread keep pins the refcount, so the dtor never fires.

**The fix** — monitor the owner; on its death, run cleanup:

- Open the **device** resource type with a `down` callback via
  `ErlNifResourceTypeInit` (dtor + down), in `init_statics` (both `RT_CREATE` and
  `RT_TAKEOVER` paths — use the init-struct form). Output resources simply never
  arm a monitor.
- `midiio_dev_res` gains an `ErlNifMonitor monitor;` (+ a flag if you need to know
  it's armed).
- `open_input`: after the keep, `enif_monitor_process(env, res, &res->owner,
  &res->monitor)` (handle the rare failure — if it returns non-zero the owner is
  already dead; clean up).
- `set_owner`: under the lock, `enif_demonitor_process` the old monitor, set the
  new `owner`, `enif_monitor_process` the new one.
- The **`down` callback** (owner died): call `do_dev_cleanup(res)` — it stops the
  recv thread, closes, releases the keep. It is `live`/`kept`-guarded and now
  joins outside the lock (Fix 1), so it's safe from `down`. **Verify against the
  card:** the resource is alive during `down`; releasing the keep there is the
  standard "let the dtor reclaim" pattern — confirm the down→keep-release→free
  ordering is sound (no use of `res` after the release in `down`).
- Idempotency: owner-death and an explicit `close` can race — both funnel through
  the guarded `do_dev_cleanup`, so exactly one tears down. Confirm.

## Fix 3 — the regression tests (these are the point)

- **Close-during-active-delivery (proves S1):** open a virtual input + a virtual
  output in one VM; run a tight high-rate `send` loop feeding the input; from
  another process `close` the input; **assert no hang** (a timeout that the
  pre-fix code would trip). Loop it; run under ASan. This is the test that would
  have caught the deadlock.
- **Owner-death cleanup (proves S2):** `open_input`+`start_input` in a child
  process; the child dies **without** stop/close; assert the device is reclaimed
  — `uninit_count` increments (same counter the slice-1 GC tests use), no leak.
- Keep the existing 31 tests green.

## Fix 4 — the vm-test record

Correct `arc3/slice1/ledger.md` row 21: `make vm-test` **exists** (`mk/docker.mk`,
included in `Makefile`, `scripts/vm-test.sh`); the deferral reason is "multipass
not set up on this host," re-entry = run it locally with multipass or rely on the
slice-5 CI ubuntu leg — not "add the missing target."

## Done

`do_dev_cleanup` joins outside the lock; the deadlock test passes (would hang
pre-fix); the owner-death test reclaims the device; F1 still closed (send-vs-close
tripwire still clean); `enif_monitor_process` armed for inputs, demonitor on
set_owner; all tests green; `rebar3 as test check` green; `make asan` `ASAN-OK`;
the started-input leak is gone so the "crashing owner leaks no OS handle" criterion
holds for inputs too. Capture the join-under-lock deadlock as a `NIF-LEARNINGS`
entry (a sharp `[GAP]`: never `pthread_join` a callback-bearing thread while
holding a lock the callback takes). Update the ledger rows + write a closing
report; CDC re-verifies. Five-iteration cap.

## Ledger

See `remediation-ledger.md`.
