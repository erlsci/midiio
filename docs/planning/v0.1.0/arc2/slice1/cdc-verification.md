# CDC verification — arc2/slice1 (output device resource + lifecycle)

> Independent verification with evidence access (read the committed
> `midiio_nif.c` lifecycle code and the eunit/ASan sources directly; re-ran the
> **verbatim-extracted** destructor under sanitizers; OTP/ALSA-coupled runs
> accepted on CC's macOS + Linux-VM + CI evidence — the sandbox has no root, OTP,
> or `libasound2-dev`). Commit reviewed: `8c770c0` (output device resource +
> lifecycle). **Verdict: PASS.** Slice 1 is **CDC-closed.** No S1/S2 findings; one
> forward-consistency note carried into arc 3. Written ~24h after the closing
> report; the slice-2 work that landed since does not regress it (it strengthens
> the Linux story — see below).

## Independently reproduced (not accepted on summary)

- **The destructor is correct — verified by execution of the real source.** I
  extracted `do_dev_cleanup` and the `midiio_dev_res` struct **verbatim** from
  `midiio_nif.c` (`:53–57`, `:143–156` — diffed the extract against the file, not
  retyped) and ran them under `-fsanitize=address,undefined` against mocked
  `mm_out_close` / `mm_context_uninit` that record call order. Results:
  - a live device → cleanup returns 1, `live` flips to 0, **port closed before
    context** (recorded order: `mm_out_close` then `mm_context_uninit`),
    `uninit_count` +1 — **rows 8, 9**;
  - a **second** call (double `close`, or the GC destructor after an explicit
    close) → returns 0, **no** second `mm_out_close`/`mm_context_uninit`,
    `uninit_count` unchanged — **rows 6, 8** (exactly-once, no double-free);
  - a **never-live** resource (the partial-failure case) → returns 0, no cleanup
    — **row 7**.
  This is the slice's load-bearing claim (a destructor that double-frees or
  mis-orders would be a memory-safety bug), and it is provably right.

- **Resource registration (row 1)** — `init_statics` (`:190–194`) opens
  `midiio_device` with `dtor_device` and the **passed `flags`** (so `load` →
  `RT_CREATE`, `upgrade` → `RT_TAKEOVER`, riding the F1 path) right after
  `midiio_context`. The single shared `init_statics` means load and upgrade can't
  diverge.

- **Embedded per-device context (row 2)** — `midiio_dev_res = { mm_context ctx;
  mm_device dev; int live; }` (`:53–57`); `open_output` does `mm_context_init`
  (`:439`) then `mm_out_open(&res->ctx, …)` (`:445`). No shared/registry context,
  no cross-resource keep — exactly the arc-2 ⚑ model.

- **Partial-failure cleanup (row 7)** — `open_output` (`:446–450`): if `mm_out_open`
  fails after `mm_context_init` succeeded, it calls `mm_context_uninit(&res->ctx)`
  directly, leaves `live==0`, then `enif_release_resource`. Because `live` stays 0,
  the immediate GC destructor no-ops (confirmed by the execution check above), so
  the context is uninited **exactly once** with no leak and no double-free. The
  `mm_context_init`-failed branch (`:440–443`) correctly does *not* uninit
  (nothing was initialised).

- **`open`/`close` finalisation order** — `device_ok` (`:410–416`) sets `live=1`,
  `enif_make_resource`, then `enif_release_resource` (Erlang term becomes sole
  owner). `live=1` is set while we hold the only reference and before the term
  exists, so it is unobservable to any other thread — safe to leave unlocked.

- **`close_device` (rows 5, 6)** — `:490–501`: `enif_get_resource` (badarg on a
  foreign term → let it crash), then `do_dev_cleanup` → `ok` if it ran, `{error,
  not_open}` otherwise.

- **Legible per-device name (row 10)** — `snprintf(name, …, "midiio-out:%u", idx)`
  (`:437`); virtual path uses `"midiio-out:virtual"`.

- **eunit faithfulness (rows 3–6, 8)** — read `test/midiio_tests.erl`: the device
  cases assert exactly their rows — opacity + `?assertError(badarg, close(make_ref()))`,
  out-of-range, close round-trip, double-close → `{error,not_open}`, and the two
  `uninit_count` delta tests (child opens a virtual device → dies → GC → +1; close
  +1, dtor +0). The `uninit_count`/0 test NIF makes the exactly-once claim
  observable from Erlang. Not a rubber stamp.

- **ASan harness (row 16)** — read `c_src/test/midiio_asan.c`: drives the device
  lifecycle (`mm_out_open_virtual` → `mm_out_close` *port-first* →
  `mm_context_uninit`), the double-close guard at the **minimidio** level
  (`mm_out_close` on a closed dev → `MM_NOT_OPEN`; second `mm_context_uninit` →
  `MM_INVALID_ARG` — so even a bypassed `live` guard can't double-free), and the
  partial-failure path (out-of-range `mm_out_open` → `mm_context_uninit`). Good
  defence-in-depth: the NIF `live` guard is tested from Erlang, the primitive
  idempotence from C.

## Accepted on CC's evidence (sandbox cannot reproduce)

No OTP/rebar3/ALSA/root in the verification sandbox, so accepted on CC's macOS +
Linux-VM + CI evidence (same posture as the arc1/slice5 and arc2/slice2 CDCs):
**row 12** (real-hardware `open_output(0)` on macOS, 15 destinations), **row 13**
(xref + dialyzer clean, incl. the `device()` opaque type), **row 14** (eunit
green), **row 15** (`rebar3 as test check` exit 0), and the backend-coupled run of
**row 16** (`make asan` → `ASAN-OK` on macOS + Linux LSan). I independently
exercised the destructor guard logic and the cleanup ordering at the C level.

## Forward-consistency note (no action this slice; tracked into arc 3)

`do_dev_cleanup` is **output-only**: it always calls `mm_out_close`. That is
correct for slice 1 (only output devices exist), but arc 3 introduces input
devices, and the unified `close/1` must then branch — `mm_in_stop` + `mm_in_close`
for inputs vs `mm_out_close` for outputs — inside the same `live`-guarded path.
This is **already captured** in `arc3/arc-plan.md` (slice 1: "extend
`do_dev_cleanup` … for inputs … still `live`-guarded and port-before-context").
Recorded here so the arc-2→arc-3 seam is explicit, not implied.

## Relationship to slice-2 finding F1

Slice 2's F1 (the unlocked `live` read on the *send* path) does **not** apply to
slice 1: every `live` transition here is under `g_uninit_lock` (in
`do_dev_cleanup`), and the only unlocked write (`device_ok` setting `live=1`) is on
an unshared resource. The asymmetry F1 flags — *cleanup is lock-guarded, but the
slice-2 send read is not* — is sharpened by this slice being fully correct: the
locking discipline exists and works; slice 2 simply chose to skip it on the hot
path under the single-owner contract. Resolve that asymmetry in arc-3's
owner/mutex work (F1 disposition), not here.

## Linux story — strengthened since the closing report

Slice 1's closing report deferred the Linux/ALSA lifecycle to CI. The slice-2 work
added a `make vm-test` harness (multipass VM with a real `snd-virmidi`
sequencer) that runs the **full** eunit suite — including the slice-1 device
lifecycle tests (`open_output_*`, the `uninit_count` GC tests) — plus the ASan
device loop on Linux. So the slice-1 lifecycle rows that were macOS-only at close
are now **actually executed on Linux** too. Net improvement; recorded for the
trending log.

## Close

All S1 rows independently confirmed or accepted-on-evidence with rationale; no S2
open; no findings; one forward-consistency note (output-only `do_dev_cleanup` →
arc 3 extends it) and F1's asymmetry sharpened. **Slice 1 is CDC-closed.**

**Arc-2 close-out — gate now clear.** With slice 1 *and* slice 2 both CDC-closed,
arc 2's capability — open an output → `send` a complete message byte-exact →
`close`, no handle leak on owner crash — is delivered and independently verified.
Arc 2 can run its **specified-vs-delivered close-out** (the `ARCS.md` arc-2
capability diff) now. Two items travel forward into arc 3, both disclosed: **F1**
(send-path lock asymmetry → owner/mutex work) and the **output-only
`do_dev_cleanup`** extension. Neither blocks the close-out.
