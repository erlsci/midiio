# CDC verification — arc1/slice3 (enumeration + caps)

> Independent code read of `c_src/midiio_nif.c` (the slice-3 additions) + the
> eunit suite. Verdict: **PASS, no findings.** Commit `2106aea`.

## Signed by code read

- **Ascending, contiguous indices (row 3).** `enumerate` descends
  `for (i = n; i-- > 0;)` and head-conses (`:285–296`), so the list comes out
  `0..n-1` ascending. Correct and idiomatic.
- **Name-miss keeps the entry (row 4).** Every in-range `i` emits a cell;
  `name_fn`'s result is explicitly discarded (`(void)name_fn(...)`, `:288`), and
  `buf[0]='\0'` before the call means a non-writing failure yields an **empty
  binary**, not garbage. Dropping an entry would desync index↔reality — correctly
  avoided. Documented at `:269–274`.
- **No transform / no cache (row 11).** Name is `strlen`+`memcpy` into a fresh
  `enif_make_new_binary` (`:290–293`); `count_fn`/`name_fn` called live each
  invocation; no static table. Pass-through, as required (R6 / DESIGN §5).
- **caps map (rows 5, 7).** `enif_make_new_map` + six `enif_make_map_put`
  (`:331–337`); `backend` = the compile-time `g_backend_atom`; flags decode
  `c & MM_CAP_*` → `bool_atom`. Matches `mm_context_caps` (`minimidio.h:817`).
- **Bad handle → badarg (row 8).** All three funnel through `enif_get_resource`
  → `enif_make_badarg` on failure (`:306–307, :316–317, :327–328`).
- **Atoms pre-made (row 9).** Confirmed in `init_statics` (so they survive the F1
  upgrade path), no `enif_make_atom` on a runtime value.

## Deferred (unchanged)

- **Row 6 `alsa` backend branch** — code-read only (no Linux host), joins the
  deferred-Linux pile with slice-1 row 3 and the leak-half of slice-1 row 16.

## Minor note (not a finding)

`enumerate` uses a 256-byte stack buffer; a device name longer than 255 bytes is
truncated by `mm_*_name` (it takes `sizeof buf`). Acceptable — names are
display-only — but worth knowing if a device ever has a pathological name.

## The coverage erosion — elevating CC's disclosure to a tracked item

CC's disclosed floor drop (**30 → 20**) is the L17 erosion made concrete, and it
will keep happening every slice that adds NIFs. This is **not** a slice-3 defect —
slice 3 was right to disclose it rather than silently pass — but it should not be
"fixed" by lowering the floor again. See the recommendation below; it belongs to
the arc-1 hardening pass, not to slice 3.

**Recommended strategy (durable):** stop line-gating the NIF-binding module.
Exclude `midiio` from the cover metric (rebar3 `cover_excl_mods` or equivalent —
CC to confirm the exact key/behaviour) so the `min_coverage` gate measures
*real-logic* Erlang modules. There are none yet, so the gate is dormant now and
becomes meaningful automatically when the first pure-Erlang logic modules land
(the per-device `gen_server`, helpers — arc 2/3). Keep cover **reporting** on
(F1's real win — that `cover` instruments at all — stands). Document that the NIF
surface is verified by **eunit (behavioural) + ASan (C memory)**, not by
`midiio.beam` line %. This implements L17 and ends the mechanical decay.
