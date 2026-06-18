# CDC re-verification — arc3/slice1 remediation (S1 deadlock + S2 leak)

> Independent re-read of the remediation commits `4ebd708` (the two fixes) +
> `851f522` (the Linux/ALSA record), against the findings in `cdc-verification.md`.
> This is the *re*-verification — the first pass found the S1 deadlock and S2 leak;
> this pass checks the fixes close them without regressing F1.
>
> **Verdict: PASS — with two tracked residuals, both in `set_owner` (the ownership-
> handoff path), neither memory-unsafe, neither blocking arc 3.** One of the two
> CC disclosed; the other I found in this pass. A cheap `set_owner` hardening is
> recommended before `undermidi`/live-coding leans on ownership handoff.
>
> **Evidence boundary (disclosed):** I verified the *logic* by code-read and the
> two regression tests by reading them. I did **not** re-run the runtime — this
> sandbox has no ALSA `/dev/snd/seq` and no Erlang, and the deadlock only
> reproduces where `mm_in_stop` actually `pthread_join`s (ALSA). My runtime
> confidence therefore rests on CC's reported `make vm-test` run (Ubuntu 24.04,
> real ALSA, 33 green + ASAN-OK). The deadlock test's discriminating power *is* on
> Linux, and that is where it was exercised — so the evidence is the right shape;
> I simply can't independently re-run it from here. If you want a second runtime
> witness, re-run `make vm-test` on the macpro's multipass.

## ✅ Fix 1 — S1 deadlock: join now outside the lock (correct)

`do_dev_cleanup` (`midiio_nif.c`, `4ebd708`) now takes `res->lock` **only** to
snapshot+flip `live` and snapshot+clear `kept`, then **unlocks** before
`mm_in_stop`/`mm_in_close`/`mm_out_close`/`mm_context_uninit`. The keep is released
**last**, after the teardown. I traced the three properties that matter:

- **Deadlock gone.** The `pthread_join` inside `mm_in_stop` runs with the lock
  released, so an in-flight `recv_cb` that needs `res->lock` (to read `owner`)
  acquires it, sends its last message, and returns — then the join completes. The
  exact lock-ordering cycle from the first pass (`close holds lock → join → waits`
  vs `recv wants lock`) is broken.
- **`res` stays valid across the join.** The recv-thread keep is still held during
  teardown (released only after the join), so the in-flight `recv_cb` dereferences
  a live resource. Correct.
- **Exactly-once preserved.** The `live` flip is under the lock, so exactly one
  caller (of close/stop/dtor/down) sees `was_live==1` and tears down; the rest
  no-op. `release_keep` is gated on the same locked `kept` snapshot, so the keep is
  released exactly once. The `did`→`was_live` return rename is semantically inert.

**F1 still closed (re-verified, not taken on faith).** `send_nif` is unchanged: the
`live` check **and** `midiio_dev_send_raw` both run under `res->lock`, and cleanup
flips `live=0` under that same lock *before* any teardown. So a concurrent
send-vs-close either runs the send fully under the lock (live==1) or sees live==0
and returns `{error, not_open}` with no deref. The slice-2 UAF stays closed.

## ✅ Fix 2 — S2 leak: owner monitor + down callback (correct)

- **Registration.** The device resource type is now opened with
  `enif_init_resource_type` and an `ErlNifResourceTypeInit{dtor, NULL, down_device,
  3, NULL}` — `members=3` correctly declares `{dtor, stop=NULL, down}`. Same
  `CREATE`/`TAKEOVER` flags as before, so it survives the F1 upgrade path.
- **Arming.** `open_input` sets `res->owner` *before* arming
  `enif_monitor_process(env, res, &res->owner, &res->monitor)` (verified the
  ordering — owner is assigned at the top of `open_input`, monitor near the end).
  A non-zero return (owner already dead) triggers `do_dev_cleanup` + `{error,
  not_open}` — the keep is released, no leak. `monitored=1` on success.
- **`down_device`.** Sets `monitored=0` then calls the guarded `do_dev_cleanup`,
  and touches `res` no further — so the keep-release (which can drop the refcount
  to 0 and free) is the last action. Correct ordering; matches the `nif-resources`
  card (resource alive for the duration of `down`, "let the dtor reclaim").
- **Composition with Fix 1.** `down_device`'s cleanup calls `mm_in_stop` (join);
  this is deadlock-free *only because* Fix 1 moved the join outside the lock. The
  two fixes compose exactly as the remediation prompt required.
- **Idempotency.** Owner-death and an explicit `close` both funnel through the
  `live`-guarded `do_dev_cleanup`, so exactly one tears down; the keep can't
  double-release (`kept` guard). No double-free.

**Both regression tests assert what's claimed.**
`close_during_active_delivery_test_` loops 20× — loopback + a flood feeding the
input + `close` mid-delivery, under `{timeout, 60}`; the timeout *is* the
hang-detector (pre-fix this hangs, post-fix it returns). Its discriminating power
is on ALSA (CoreMIDI's `mm_in_stop` doesn't join), and that is the leg vm-test ran.
`owner_death_reclaims_input_test_` spawns a child that opens+starts then dies
without stop/close, waits for `DOWN`, then asserts `uninit_count` increments within
5 s — a true reclaim witness. Skips cleanly when no virtual source is enumerable
(headless), runs for real on vm-test.

## 🟠 Residual R1 (CC-disclosed) — `set_owner` vs old-owner death → spurious close

If `set_owner(Dev, P2)` lands in the same window the old owner P1 dies, P1's
`down_device` can fire and tear the device down even though ownership just moved to
a live P2. **No UAF** — `do_dev_cleanup` is `live`-guarded and idempotent; a later
P2 death re-enters and no-ops. The cost is a *live* owner losing its device. CC
disclosed this accurately. Narrow (requires the handoff to race death delivery),
no memory unsafety.

## 🟡 Residual R2 (found this pass) — `set_owner` to an already-dead pid silently re-opens S2

`set_owner` demonitors the old owner *first*, writes `owner=pid`, then arms a new
monitor only `if (is_input && enif_monitor_process(...) == 0)`. If the **new** pid
is already dead, `enif_monitor_process` returns `>0`, `monitored` stays `0`, and
the function returns `am_ok`. Net effect: a started input now has **no monitor**
and a **dead nominal owner** — nobody will ever reclaim it. This silently
re-opens the very S2 leak Fix 2 closed, *and* it disarms the previously-good
monitor on P1 (demonitored before the failed re-arm), and it reports success.

Reachability is narrow (handing ownership to an already-dead process is a caller
error), there's no memory unsafety, and the normal open→start→close lifecycle is
unaffected — so this is **S3**, a tracked residual, not a blocker. But it matters
more than pure theory for this family: `undermidi`/live-coding will use ownership
handoff on hot reload, and a reload racing a crash could hit it.

**Recommended hardening (cheap, fixes both R1 and R2):** in `set_owner`, arm the
**new** monitor *before* demonitoring the old, and only commit (`owner=pid`,
demonitor old) if the new monitor succeeds; on failure leave the old owner+monitor
intact and return `{error, owner_not_alive}`. That makes handoff atomic and
all-or-nothing: a dead target can't disarm a good monitor (R2), and a racing death
of the old owner after a successful re-point hits the *new* monitor path, not a
spurious cleanup of a live device (R1 narrows to the unavoidable ERTS demonitor
race only). Also consider taking `res->lock` around `down_device`'s `monitored=0`
write (currently unlocked — a benign int race with `set_owner`), though `down`
must not hold the lock when calling `do_dev_cleanup` (non-recursive mutex).

## Bottom line

The S1 deadlock and S2 leak are **genuinely closed**, with the right runtime
evidence obtained on the platform that actually deadlocks (ALSA via vm-test). F1
stays closed; the two fixes compose as designed; the two new tests are real
tripwires. The remaining exposure is confined to `set_owner` (ownership handoff):
R1 (disclosed, spurious close on a death race) and R2 (found here, silent leak +
monitor-disarm on handoff to a dead pid). Both are S3, memory-safe, and out of the
normal lifecycle. **PASS.** Recommend the `set_owner` monitor-new-before-demonitor-
old hardening as a small arc3/slice2 pickup (or a micro-remediation) before
`undermidi` exercises handoff — and a second `make vm-test` witness on the macpro
if you want runtime confirmation independent of CC's run.

## Process note (verified)

NIF-LEARNINGS L21 ("never `pthread_join` a callback-bearing thread while holding a
lock the callback takes") is present and correctly states the general rule. The
`rm -rf priv` near-misses CC disclosed are a real footgun — the saved memory + the
fact that `priv/` holds tracked logo PNGs means a `make clean` that nukes `priv`
wholesale is the latent hazard; worth a `.gitignore`-aware clean target if it
recurs.
