# Closing report — arc3/slice1 remediation: close-deadlock (S1) + started-input leak (S2)

> CC's per-fix walk (full table in `remediation-ledger.md`). Two CDC findings on
> `6466293` closed together (both live in the input-lifecycle / per-device-lock
> code). Host: macOS arm64 (CoreMIDI), OTP 28. Date: 2026-06-18. Iteration: 1.

## Fix 1 — S1 deadlock: join outside the lock

**Bug.** `do_dev_cleanup` held `res->lock` across `mm_in_stop`, which on ALSA
`pthread_join`s the recv thread — but `recv_cb` needs that same lock to read
`owner`. Close-during-active-delivery → the closing thread joins (holding the
lock) while the recv thread blocks on the lock → deadlock.

**Fix.** The lock now guards only the `live` flip (exactly-once) + the `kept`
snapshot; the teardown — including the join — runs **outside** the lock. The keep
is released **last** (after the join), so an in-flight `recv_cb` keeps `res` valid
until the join completes.

**F1 still closed (verified, not assumed).** `send_nif` derefs the handles only
when `live==1` and under `res->lock`; cleanup flips `live=0` under the same lock
**before** any teardown. So send either ran fully under the lock before the flip,
or sees `live==0` and returns `{error, not_open}` with no deref. The F1 tripwire
(eunit 25 rounds + standalone pthread replica) is still **ASan- and TSan-clean**.

## Fix 2 — S2 leak: monitor the owner

**Bug.** A started input whose owner drops the handle without stop/close leaked —
the recv-thread keep pins the refcount, so the dtor never fires.

**Fix.** The device resource type is now registered via `enif_init_resource_type`
with a `down` callback (`ErlNifResourceTypeInit{dtor, NULL, down, 3, NULL}`).
`open_input` arms `enif_monitor_process` on the owner (after the keep; a
not-alive owner is reclaimed immediately and reported `{error, not_open}`);
`set_owner` demonitors the old owner and monitors the new under the lock. The
`down` callback runs the guarded `do_dev_cleanup` — which, thanks to Fix 1, joins
outside the lock, so reclaiming from `down` is deadlock-free. **Ordering checked
against the `nif-resources` card:** the resource is alive for the whole `down`
callback, and `do_dev_cleanup` releases the keep as its last act (nothing touches
`res` after), so the down→release→free sequence is sound.

**Owner-death vs explicit close** both funnel through the `was_live`-guarded
cleanup, so exactly one tears down (no double-free).

## Evidence

- **Deadlock regression (row 2):** `close_during_active_delivery_test_` (20 rounds,
  high-rate `flood` sender + concurrent `close`, `{timeout,60}`) passes.
  **Proven on real ALSA:** `make vm-test` (Ubuntu 24.04 multipass VM with a real
  `/dev/snd/seq`, where `mm_in_stop` *does* `pthread_join` the recv thread — the
  platform that actually deadlocks) ran `rebar3 as test check && make asan` →
  **All 33 tests passed + ASAN-OK**. Pre-fix this hangs on ALSA; post-fix passes.
  (macOS/CoreMIDI also passes — no join there.)
- **Owner-death reclaim (row 9):** `owner_death_reclaims_input_test_` — a child
  `open_input`+`start`s then dies with no stop/close; `uninit_count` increments
  via the `down` callback. No leak.
- 33 eunit tests green; `make asan` `ASAN-OK`; `rebar3 as test check` exit 0; F1
  TSan-clean.

## Criterion closure

The arc-3 capability's *"closing/crashing the owner leaks no handle"* now holds for
**inputs** too (it already held for outputs): an abandoned started input is
reclaimed on owner death by the monitor. The output close (F1) and the recv path
were correct and were left untouched, per the remediation's scope discipline.

## Disclosed residuals

- **Narrow set_owner-vs-old-owner-death race:** if the *current* owner dies exactly
  as `set_owner` redirects to a new owner, the old owner's `down` may still fire
  (the monitor was already triggered) and tear the device down. No UAF/double-free
  (the guarded `do_dev_cleanup` is idempotent) — at worst a spurious close on a
  death-during-redirect. Acceptable for v0.1.0; noted.
- **Linux/ALSA** is the platform where the deadlock actually reproduces; `make
  vm-test` was run as the genuine Linux closure — **passed** (33 tests + ASAN-OK on
  Ubuntu 24.04 with a real sequencer), which also exercises the slice-1/slice-3
  deferred-Linux rows (Linux load, `alsa` backend, the LeakSanitizer leak-half).
- **NIF-LEARNINGS L21** captures the join-under-lock deadlock as a sharp `[GAP]`.
