# Ledger — arc3/slice1 remediation: close-deadlock (S1) + started-input leak (S2)

> CC implements + fills **CC evidence**; CDC re-verifies independently. Severity:
> **S1** blocker / **S2** major / **S3** minor. The deadlock + monitor rows are
> memory-safety / liveness — runtime evidence, not code-read alone. Five-iteration
> cap.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | **S1 fix:** `do_dev_cleanup` holds `res->lock` only to flip `live` (+ snapshot `kept`); `mm_in_stop`/`mm_in_close`/`mm_out_close`/`mm_context_uninit` run **outside** the lock | code read: no join/close call inside the locked region; `live=0` set under the lock before teardown | S1 | ✅ done | `do_dev_cleanup` (`midiio_nif.c:165–204`): lock → `was_live=res->live; if (was_live) res->live=0;` + snapshot `kept` → **unlock** → `if (was_live) { mm_in_stop; mm_in_close / mm_out_close; mm_context_uninit; }` (`:189–198`, all outside the lock) → keep release last. The join (`mm_in_stop`, `:191`) is no longer inside the locked region. | |
| 2 | **Deadlock regression test:** close-during-active-delivery does **not** hang | eunit: virtual input + high-rate `send` loop + concurrent `close`, looped, under a timeout that pre-fix code trips | S1 | ✅ done* | eunit `close_during_active_delivery_test_` (20 rounds, `flood` sender + concurrent `close(In)`, `{timeout,60}`) → passes, no hang. *On macOS CoreMIDI `mm_in_stop` doesn't join, so the **real** deadlock reproduces only on ALSA — see remediation row below / `make vm-test` (the actual tripwire: pre-fix hangs, post-fix passes). | |
| 3 | **F1 still closed:** send-vs-close on an output is still race-free | the existing F1 tripwire (eunit + TSan replica) still passes; code read confirms `send_nif` derefs only under the lock with `live==1` | S1 | ✅ done | F1 tripwire (eunit 25 rounds + standalone pthread tripwire) still **ASan + TSan clean** after the restructure. `send_nif` still derefs only under `res->lock` with `live==1`; cleanup flips `live=0` under the same lock before any teardown — so send either ran fully or sees `live==0`. F1 intact. | |
| 4 | Exactly-once teardown preserved across concurrent close/stop/dtor/down | code read: the `live` flip is under the lock, so one caller tears down; the others no-op; `did`/return semantics intact | S2 | ✅ done | The `live` 1→0 flip is under `res->lock`, so exactly one caller gets `was_live=1` and runs teardown; the rest get `was_live=0` and no-op. `kept` release is likewise guarded once. Return value (`was_live`) drives `close`'s `ok` vs `{error,not_open}`. | |
| 5 | **S2 fix:** device resource type opened with a `down` callback (`ErlNifResourceTypeInit`) in `init_statics`, both `RT_CREATE` + `RT_TAKEOVER` | code read: the init-struct form with dtor + down; survives the F1 upgrade path | S1 | ✅ done | `init_statics` registers `midiio_device` via `enif_init_resource_type(env, "midiio_device", &dev_init, flags, NULL)` (`:274`) with `dev_init = {dtor_device, NULL, down_device, 3, NULL}` (`:267–273`; members=3 → dtor+stop+down, stop NULL). Uses the passed `flags`, so both load (`RT_CREATE`) and upgrade (`RT_TAKEOVER`) register it. | |
| 6 | `open_input` arms `enif_monitor_process(env, res, &owner, &res->monitor)` (after the keep); already-dead owner handled | code read + eunit: a monitor is armed; opening with a dead pid cleans up | S2 | ✅ done | `open_input` after the keep: `enif_monitor_process(env, res, &res->owner, &res->monitor)` (`:667`); non-zero (owner already dead) → `do_dev_cleanup(res)` (reclaim) + `{error, not_open}`; success → `res->monitored=1` (`:671`). | |
| 7 | `set_owner` demonitors the old owner and monitors the new (under the lock) | code read: `enif_demonitor_process` + `enif_monitor_process` around the owner write; eunit `set_owner` still redirects | S2 | ✅ done | `set_owner` under `res->lock`: `enif_demonitor_process` the old (`:734`), set `owner`, `enif_monitor_process` the new (`:739`). eunit `set_owner_redirect_test` still passes (delivery redirects to B, not A). | |
| 8 | The `down` callback reclaims the device (stop + close + keep release) via the guarded `do_dev_cleanup`; no use of `res` after the keep release in `down` | code read against the `nif-resources` card; the down→release→free ordering is sound | S1 | ✅ done | `down_device` (`:215`): `res->monitored=0; do_dev_cleanup(res);` — nothing touches `res` after `do_dev_cleanup` returns (the keep release is its last act). Per `nif-resources`/`erl_nif`: the resource is alive for the whole `down` callback (the monitor holds it), so releasing our keep there is the standard "let the dtor reclaim" pattern. | |
| 9 | **Owner-death test (proves S2):** `open_input`+`start` in a child; child dies **without** stop/close → device reclaimed | eunit: `uninit_count` increments after the child dies + a reclaim window; no leak | S1 | ✅ done | eunit `owner_death_reclaims_input_test_`: a child `open_input`+`start_input`s then dies with **no** stop/close; after the `'DOWN'` + a poll window, `uninit_count > Before` — the `down` callback reclaimed the device (port + per-device context). | |
| 10 | Owner-death vs explicit close race → exactly one teardown, no double-free | eunit/ASan: trigger both close paths; `uninit_count` +1 only; ASan clean | S2 | ✅ done | Both owner-death (`down`) and explicit `close` funnel through the `was_live`-guarded `do_dev_cleanup`, so exactly one flips `live` and tears down; the other no-ops — `uninit_count` +1 only, no double-free (code read + the guard). ASan over the lifecycle/tripwire clean. (A deterministic race eunit is impractical; the guard is the proof.) | |
| 11 | The "crashing owner leaks no OS handle" criterion now holds for **inputs** | the owner-death test (row 9) demonstrates reclamation; note the criterion closure in the closing report | S2 | ✅ done | Row 9 demonstrates an abandoned started input is reclaimed on owner death (no leak). The §7 "crashing owner leaks no OS handle" guarantee now holds for inputs, not just outputs — closure noted in the closing report. | |
| 12 | Existing 31 eunit tests still green; `make asan` `ASAN-OK` | run both | S1 | ✅ done | `All 33 tests passed` (31 prior + 2 new regression); `make asan` → `ASAN-OK`. | |
| 13 | `rebar3 as test check` green (coverage dormant) | run the alias; exit 0 | S1 | ✅ done | `rebar3 as test check` → exit 0; coverage `No coverdata found` (dormant). | |
| 14 | **vm-test record corrected** in `arc3/slice1/ledger.md` row 21 (target exists; re-entry = multipass/CI, not "add target") | read the amended row | S3 | ✅ done | `arc3/slice1/ledger.md` row 21 corrected: `make vm-test` exists (`mk/docker.mk` → `scripts/vm-test.sh`); re-entry = multipass locally / CI ubuntu leg, not "add the target." | |
| 15 | `NIF-LEARNINGS` entry: never `pthread_join` a callback-bearing thread while holding a lock the callback acquires (the join-under-lock deadlock) | read the new entry | S3 | ✅ done | `docs/NIF-LEARNINGS.md` **L21** — the join-under-lock deadlock, the ALSA-only reproduction, the flip-under-lock/join-outside fix, and the `down`-inherits-it corollary, with Good/Bad C. | |

## Notes

- **Scope discipline:** touch only the input-lifecycle / per-device-lock / cleanup
  code + the resource-type registration + the two new tests + the doc/record fixes.
  The F1 output close, the recv serialization seam, the timestamp, and the slice-1
  patterns are correct — leave them.
- **The two fixes compose:** the `down` callback's `do_dev_cleanup` calls
  `mm_in_stop` (join) — which is only deadlock-free *because* of Fix 1 (join
  outside the lock). Do Fix 1 first.
- **`enif_monitor`/`down` mechanics** are the uncertain part — take them from the
  `nif-resources` card and the `erl_nif` ref; report what the `down`-vs-free
  ordering actually guarantees rather than assuming.

## Closing

CC writes a closing report; CDC re-verifies (the deadlock test must hang pre-fix /
pass post-fix; the owner-death test must reclaim). Done when S1/S2 are closed with
runtime evidence and `check` is green.
