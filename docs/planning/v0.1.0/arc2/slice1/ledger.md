# Ledger — arc2/slice1: output device resource + lifecycle

> CC implements + fills **CC evidence**; CDC verifies independently. Severity:
> **S1** blocker / **S2** major / **S3** minor. Headless-CI rows note where
> hardware is required. Five-iteration cap.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | `midiio_device` resource type opened in `init_statics` (load `RT_CREATE` / upgrade `RT_TAKEOVER`) | code read: the type is opened alongside `midiio_context` with the passed flag; survives upgrade | S1 | ✅ done | `init_statics` opens `midiio_device` with `dtor_device` and the passed `flags` (`midiio_nif.c:179–184`), right after `midiio_context`; `load`→`RT_CREATE`, `upgrade`→`RT_TAKEOVER` (the existing F1 path). | |
| 2 | Device resource embeds its own `mm_context` (per-device context) | code read: `struct { mm_context ctx; mm_device dev; int live; }`; `open_output` calls `mm_context_init` then `mm_out_open(&r->ctx, …)` | S1 | ✅ done | `typedef struct { mm_context ctx; mm_device dev; int live; } midiio_dev_res;` (`:47–51`). `open_output` → `mm_context_init(&res->ctx, name)` (`:427`) then `mm_out_open(&res->ctx, &res->dev, idx)` (`:433`). No shared/registry context. | |
| 3 | `open_output(Index)` returns `{ok, Dev}` with an opaque device handle (distinct type from `context()`) | eunit (hardware or virtual): `{ok, R}`, no exception; a foreign `make_ref()` is rejected by `close/1` with `badarg` | S1 | ✅ done | eunit `open_output_virtual_opaque_test`: `{ok, D}`, `is_reference(D)`, `not is_binary(D)`, `?assertError(badarg, midiio:close(make_ref()))`. Real-hw run: `open_output(0)` → `{ok,#Ref<…>}`. `device()` is a distinct opaque type. | |
| 4 | Out-of-range index → `{error, out_of_range}` | eunit (headless-safe): `open_output(100000)` → `{error, out_of_range}` | S1 | ✅ done | eunit `open_output_out_of_range_test` → `{error, out_of_range}` (`mm_out_open` returns `MM_OUT_OF_RANGE` → `result_to_atom`). | |
| 5 | `close(Dev)` → `ok` on a live device | eunit lifecycle (virtual or hardware) | S2 | ✅ done | eunit `open_output_close_roundtrip_test` (virtual) → `ok`; real-hw run `close(D)` → `ok`. | |
| 6 | Double `close` → `{error, not_open}`, no crash | eunit: open, close, close again | S2 | ✅ done | eunit `open_output_double_close_test`: 2nd close → `{error, not_open}`, no crash. | |
| 7 | Partial-failure cleanup: `mm_out_open` failure after `context_init` uninits the context (no leak) | code read: the `out_open`-failed branch calls `mm_context_uninit` before returning `{error,_}`; ASan shows no leak on the forced-failure path | S2 | ✅ done | `open_output` `out_open`-failed branch calls `mm_context_uninit(&res->ctx)` before `enif_release_resource` + `{error,_}` (`midiio_nif.c:434–438`); `live` stays 0 so the dtor doesn't re-uninit. **ASan forced-failure loop** in `midiio_asan.c` (init → `mm_out_open` with an out-of-range index → `mm_context_uninit`, ×200) → `ASAN-OK`, no leak. | |
| 8 | Destructor reclaims **both** the port and the per-device context, exactly once, no double-free | eunit: open in a child proc, let it die, GC → `uninit_count` +1 (the per-device context); ASan: no double-free / use-after-free over the lifecycle loop | S1 | ✅ done | eunit `device_gc_runs_destructor_once_test` (child opens virtual device, dies, GC → `uninit_count` +1) and `device_close_then_gc_no_double_uninit_test` (close +1, dtor +0). ASan device loop (init→out_open_virtual→out_close→uninit, ×200) → `ASAN-OK`. | |
| 9 | Cleanup order is port-then-context; single `live`-guarded path shared by `close` + destructor | code read: one guarded cleanup fn; `mm_out_close` before `mm_context_uninit`; `live` flips once | S2 | ✅ done | `do_dev_cleanup` (`midiio_nif.c:133`): under `g_uninit_lock`, `if (live)` → `mm_out_close(&res->dev)` (`:138`) **then** `mm_context_uninit(&res->ctx)` (`:139`), `live=0`, `count++`. Both `close_device` (`:485`) and `dtor_device` (`:148`) funnel through it. | |
| 10 | Per-device context has a legible distinct name | code read: `mm_context_init` name is e.g. `"midiio-out:<Index>"`, not a bare default | S3 | ✅ done | `snprintf(name, sizeof name, "midiio-out:%u", idx)` (`:425`) → `mm_context_init(&res->ctx, name)`. Virtual path uses `"midiio-out:virtual"`. | |
| 11 | `-nifs`/`-export`/`nif_error` stubs + `-spec` for `open_output/1`, `close/1`; opaque `device()` type | grep `src/midiio.erl` | S2 | ✅ done | `src/midiio.erl`: `open_output/1`, `close/1` (+ `open_output_virtual/0` test) in `-nifs`/`-export`; `?NOT_LOADED` stubs with a `-spec` each; `-type device() :: term().` exported. | |
| 12 | Real-hardware open works (macOS) | macOS with a destination present: `open_output(0)` → `{ok, Dev}`; `close` → `ok` | S2 | ✅ done | Shell + eunit `open_output_real_hardware_test` (opens `0` when `list_outputs` non-empty): `open_output(0)` → `{ok,#Ref<…>}`, `close` → `ok` on this macOS box (15 destinations). Headless → no-op (virtual path covers lifecycle). | |
| 13 | `rebar3 xref` + `dialyzer` clean (the `device()` type) | run both | S2 | ✅ done | `rebar3 as test check`: xref zero findings; dialyzer "Analyzing 2 files", zero warnings (the `device()`/`open_output`/`close` specs check). | |
| 14 | `rebar3 eunit` green | run; all tests pass (existing 12 + new) | S1 | ✅ done | `All 19 tests passed` (12 prior + 7 device tests). | |
| 15 | `rebar3 as test check` green | run the alias; exit 0 (coverage stays dormant — `midiio` excluded) | S1 | ✅ done | `rebar3 as test check` → exit 0; coverage `No coverdata found` (gate dormant — `midiio` excluded, per slice-5 item 1; the new stubs did **not** require any floor change). | |
| 16 | ASan clean over the device lifecycle | extend `midiio_asan.c` (init → out_open via virtual port → out_close → uninit, looped) → `ASAN-OK` | S2 | ✅ done | `c_src/test/midiio_asan.c` device loop added (×200: `mm_context_init` → `mm_out_open_virtual` → `mm_out_close` → `mm_context_uninit`, + guarded-double-close no-ops); `make asan` → `ASAN-OK`, exit 0. | |

## Notes / disclosed deferrals

- **Hardware vs headless:** rows 3/5/6/8/16 need a way to open a device without a
  real destination — prefer `mm_out_open_virtual` **as test scaffolding** (works
  headless). Row 12 is the real-hardware confirm (macOS). If the virtual-port test
  path proves awkward, disclose and fall back to hardware + code-read, marking the
  headless lifecycle rows for the CI/Linux pass.
- **Linux:** the `alsa` `mm_out_open` path is verified by code read on CC's macOS
  box; the CI (arc1/slice5 `ci.yml`) exercises it on the ubuntu leg if the runner
  provides a sequencer — same re-entry as the other deferred-Linux rows.
- **Coverage:** the new NIF stubs add more uncovered `midiio.beam` lines — that's
  fine and expected (the module is excluded from the gate; eunit + ASan are the
  real verification). Do **not** re-introduce a `midiio` line-coverage floor.
- Out of scope: send, the raw seam, dirty NIFs, inbound, input devices, UMP,
  batch, public virtual ports.

## Closing

CC writes `closing-report.md`; CDC writes `cdc-verification.md`. Done when all S1
rows close and no S2 remains open without a written disposition.
