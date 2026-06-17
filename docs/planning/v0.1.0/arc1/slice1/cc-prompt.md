# CC assignment — arc1/slice1: build skeleton + NIF load + context resource

> The assignment the implementing context (CC) receives. Self-contained. Read the
> three reference docs first, then implement to the ledger. CDC verifies
> independently on close.

## Posture

Peer-frame, write-to-the-floor. Load the **collaboration-framework** and
**erlang-guidelines** skills. For NIF mechanics, the authoritative substrate is
the concept cards under
`knowledge/erlang/concept-cards/`: `otp-erts/erl-nif.md`,
`otp-erts/nif-resources.md`, `erlang-otp-action/nif-loading.md`,
`otp-erts/nif-thread-safety.md`. Don't write `enif_*` signatures or the dirty/env
APIs from memory — check the cards. This slice uses **no** dirty NIFs, **no**
`enif_send`, **no** threads; keep it to the load callback + resource lifecycle.

## Required reading (evidence, not summaries)

1. `docs/planning/v0.1.0/DESIGN.md` — §2 (resource objects & per-device context),
   §6 (error mapping), §8 (build wiring).
2. `docs/planning/v0.1.0/arc1/slice1/slice-doc.md` — scope and the three named
   risks.
3. `workbench/minimidio/minimidio.h` — `mm_context` struct (`:512–524`),
   `mm_context_init` / `mm_context_uninit` (per-backend, e.g. CoreMIDI
   `:803–816`), `mm_result` enum (`:251–260`), `mm_result_string` (`:591`,
   `:602–606`).

## What to build

**`c_src/midiio_nif.c`** (single translation unit):

- `#define MINIMIDIO_IMPLEMENTATION` then `#include "minimidio.h"`; `#include
  <erl_nif.h>`.
- A resource struct embedding the context by value:
  `typedef struct { mm_context ctx; int live; } midiio_ctx_res;`
- `load(env, priv, info)`: open the resource type
  `enif_open_resource_type(env, NULL, "midiio_context", dtor_context,
  ERL_NIF_RT_CREATE, NULL)`, store the `ErlNifResourceType*` in a static (or in
  `priv_data`). Return 0 on success.
- `dtor_context(env, obj)`: if `res->live`, call `mm_context_uninit(&res->ctx)`
  and clear `live`. Must be safe to run after an explicit close (no double
  uninit).
- NIF `context_open/0`: `enif_alloc_resource` → `mm_context_init(&res->ctx,
  NULL)` → on `MM_SUCCESS` set `live=1`, `term = enif_make_resource`,
  `enif_release_resource`, return `{ok, term}`; on failure release and return
  `{error, Atom}` from the result mapping.
- NIF `context_close/1`: `enif_get_resource`; if `live`, `mm_context_uninit`,
  clear `live`, return `ok`; else return `{error, not_open}`.
- A C helper mapping `mm_result` → atom (`success`→handled as `ok` by callers;
  the 7 errors → their lowercase atoms). Use `enif_make_atom`; pre-make the atoms
  in `load` per the `erl-nif` card's best practice.
- `ERL_NIF_INIT(midiio, nif_funcs, load, NULL, NULL, NULL)` (module name
  unquoted).

**`src/midiio.erl`:**

- `-module(midiio).`, `-on_load(init/0).`, `-nifs([context_open/0,
  context_close/1]).`
- `init/0`: `erlang:load_nif(filename:join(code:priv_dir(midiio),
  "midiio_nif"), 0).`
- Exported stubs `context_open/0` and `context_close/1` whose bodies are
  `erlang:nif_error(nif_not_loaded)`.
- `-spec` on both exported functions.

**`c_src/minimidio.h`:** copy the vendored header from `workbench/minimidio/`
into `c_src/` (the in-tree compile location; keep the workbench copy as the
upstream-tracking reference).

**`rebar.config`:** add the `pc` plugin and provider hooks
(`pre`/`post` compile + clean), `port_specs` for the TU with per-OS flags
(`-framework CoreMIDI` Darwin; `-lasound -lpthread` Linux), and `artifacts` so
rebar knows `priv/midiio_nif.so` is the product. Keep the existing xref/dialyzer/
proper/check config.

## Constraints (erlang-guidelines)

- snake_case; `-spec` every exported function; `{ok,_}`/`{error,atom()}` returns.
- Let-it-crash: don't defensively wrap; bad args may `enif_make_badarg`.
- Never build atoms from untrusted input (N/A here, but keep it in mind).
- Resource type opened **only** in `load`; destructor is the single cleanup path
  besides explicit close; the two must not both uninit (the `live` flag).
- NIF stays well under 1 ms — `mm_context_init` is a fast OS call, **not** dirty.

## Out of scope (do not build)

Enumeration, caps, device resources, open/send/recv, the raw seam, dirty NIFs,
`enif_send`, threads, virtual ports. Those are later slices; adding them here
mis-sizes the slice.

## Done = every ledger row closed with evidence + `rebar3 check` green on macOS
and Linux. If a row can't be met, stop and surface it (disclosed deferral), don't
silently drop it. Five-iteration cap.
