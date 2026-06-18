# CDC verification — arc3/slice1 (input lifecycle + recv → enif_send; F1 close)

> Independent code read of `c_src/midiio_nif.c` (cleanup/dtor/recv/lifecycle),
> `c_src/midiio_recv.h`, and the relevant `minimidio.h` internals (the ALSA recv
> thread + `mm_in_stop`). Commit reviewed: `6466293`.
>
> **Verdict: CONDITIONAL — not yet a PASS.** One **S1 deadlock** (must fix before
> arc 3 proceeds), one **S2** gap against a stated success criterion (needs a
> disposition), and one CC claim corrected. The F1 close itself and the
> cross-thread recv path are **correct** — the S1 is a *different* lock-ordering
> bug the F1 lock introduced on the **input** path.

## ✅ Verified correct

- **F1 close (rows 3, 4) — sound.** `send_nif` checks `live` and calls
  `midiio_dev_send_raw` under `res->lock`; `do_dev_cleanup`'s teardown is under the
  same per-device lock; `g_uninit_count` is now `atomic_fetch_add` (correct, since
  device cleanup left the global lock). The send-vs-close UAF on **outputs** is
  genuinely closed — the eunit tripwire + the TSan-clean standalone replica are
  appropriate given the BEAM `.so` can't be instrumented.
- **Mutex lifecycle (row 2) — correct.** Created per-device in `new_device`,
  destroyed **last** in `dtor_device` after the final cleanup. The keep-release
  outside the lock (`:195–200`) with its re-entrancy reasoning is right: I traced
  it — the only path where releasing the keep would re-enter the dtor is the leak
  path, where the dtor never fires, so the double-release edge can't be hit.
- **recv_cb (rows 11–14) — correct.** Process-independent env per delivery;
  **SysEx `memcpy`'d during the callback** (never aliasing the callback-lifetime
  `msg->sysex`); int64-ns host-monotonic timestamp; owner read under the lock;
  `enif_send(NULL,…)` then `enif_free_env` (right in both success and failure).
- **The keep/restart invariant is *belt-and-suspenders*, not a bug.** The keep is
  held open→stop, so a `start→stop→start` re-arms the recv thread without
  re-acquiring it — but minimidio's `mm_in_stop` `pthread_join`s the thread, so the
  thread can never outlive teardown regardless of the keep. (That same join is
  what creates the S1 below.)

## 🔴 S1 — Deadlock: `mm_in_stop` (which `pthread_join`s) is called under `res->lock`

**`do_dev_cleanup` (`midiio_nif.c:173–193`)** holds `res->lock` across
`mm_in_stop(&res->dev)` (`:176`). On ALSA, `mm_in_stop` (`minimidio.h:1607–1613`)
sets `running=0` **then `pthread_join`s the recv thread** — it blocks until the
thread exits. But the recv thread, to finish an in-flight callback, calls
`recv_cb` → **`enif_mutex_lock(res->lock)` (`:522`)** to read `owner`. So:

```
close/dtor:   lock(res->lock) → mm_in_stop → pthread_join(recv) … waits forever
recv thread:  in recv_cb → lock(res->lock) … blocked (close holds it)
```

A classic lock-ordering deadlock. **Reachable in normal single-owner use:** an
owner that `open_input → start_input → (messages flowing) → close`s — if `close`
lands while a message is mid-delivery, the calling process hangs forever and the
recv thread is stuck. The tests miss it because they `close` only *after* the one
message is fully received (no in-flight callback). For a busy input, the window is
real.

**Fix (standard — don't join under a lock the joined thread takes):** in
`do_dev_cleanup`, take the lock only to **snapshot + flip `live`** (`was_live =
res->live; res->live = 0;`), **release the lock**, then do `mm_in_stop` /
`mm_in_close` / `mm_out_close` / `mm_context_uninit` **outside** it. A `recv_cb`
that fires in the gap locks the (now-free) lock, reads `owner`, sends a last
in-flight message against a still-valid resource, and returns; `mm_in_stop` then
joins it cleanly. The lock still serialises the `live`-flip so exactly one caller
tears down (the exactly-once semantics + the `did` return are preserved). `send_nif`
keeps its lock-around-check-and-use (that race is real and per-call-fast — no join
there).

**This blocks the slice's PASS.** It's a focused remediation (restructure one
function); re-verify with a close-during-active-delivery test (open_input + a
high-rate virtual source + concurrent close, looped — should not hang, ASan clean).

## 🟠 S2 — Started-input leak violates the "crashing owner leaks no OS handle" criterion

CC disclosed this honestly (L20): a `start`ed input whose owner drops/loses the
handle **without `stop`/`close`** leaks — the recv-thread keep pins the refcount
above GC, so the dtor never fires; the recv pthread + ALSA seq port + per-device
context all leak. **The gap:** `PROJECT-DEFINITION.md`'s success criterion is "a
crashing owner process leaks no OS handles," and the arc-3 plan deferred
`enif_monitor_process` *on the premise that GC-of-handle is the baseline*. That
premise is **false for started inputs** — the keep defeats GC-of-handle. So this
isn't merely a deferred nicety; it's a stated criterion that isn't met for the
input case.

**Disposition needed (architect's call), two options:**
1. **Close it:** add `enif_monitor_process` — open the device resource type with a
   `down` callback; monitor the owner at `open_input` (re-monitor on `set_owner`);
   the `down` callback releases the keep → dtor → cleanup. This is the standard fix
   and the honest one for a published library that promises crash-safety. Moderate,
   focused; natural as an arc3 remediation or folded into the S1 fix.
2. **Amend the criterion:** explicitly downgrade the promise to "outputs and
   stopped inputs leak no handle; a *started* input must be `stop`/`close`d by its
   owner," with the monitor tracked as post-v0.1.0. Honest, but weaker.

My recommendation: **(1)** — and since the recv thread also needs the lock fix
(S1), doing both in one arc3/slice1 remediation is coherent. Don't ship v0.1.0
silently not meeting the crash-safety criterion.

## ✏️ Correction — `make vm-test` exists (row 21)

CC's row-21 deferral cites "the `make vm-test` target … doesn't actually exist in
the repo." It **does**: `mk/docker.mk:65` (defines `vm-test`), `include mk/docker.mk`
at `Makefile:48`, and `scripts/vm-test.sh` is present (the other machine added them;
arc2/slice2 ran 26/26 through it). The real reason is just that **multipass isn't
set up on this macpro**. So the re-entry is "set up multipass and run `make
vm-test` locally" (or rely on the slice-5 CI ubuntu leg) — not "add the missing
target." Minor, but the record should be accurate.

## Bottom line

Excellent work on the F1 close and the cross-thread recv — both correct. But the
slice is **not done**: the F1 lock introduced an S1 deadlock on the input close
path (join-under-lock), and the input-leak is an S2 gap against a promised
criterion. Recommend a single focused **arc3/slice1 remediation**: (a) move the
join outside `res->lock`, (b) add `enif_monitor_process` for the started-input
leak, (c) add the close-during-active-delivery test, (d) fix the vm-test note.
Re-CDC after.
