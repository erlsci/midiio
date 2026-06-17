# NIF learnings — running log (midiio build)

> Purpose: capture **every** gotcha, difficulty, and learning about building an
> Erlang NIF over a C library, *as it is earned* building midiio — so it can be
> harvested into a dedicated `erlang-guidelines` NIF chapter (#18) by the
> documentation twin. This is the practitioner-evidence half; the upstream
> substrate (`knowledge/erlang/concept-cards/*`, `sources/md/*`) is the other.
>
> **Location:** tracked at `docs/NIF-LEARNINGS.md` (moved out of the gitignored
> `workbench/` in arc1/slice5 so this guide-handoff artifact is version-controlled
> and shareable).
>
> **How to use this file:** append an entry the moment a NIF/`erl_nif` lesson
> surfaces — from design, from CC's implementation, from a bug, from CDC's audit.
> Pre-shape each toward the guide's pattern contract so the harvest is cheap:
> a title, a provisional **Strength** (MUST/SHOULD/CONSIDER/AVOID), the concrete
> situation, a **Good**/**Bad** pair (C or Erlang as fits), and a **substrate
> tag**: `[substrate: <card-slug>]` if it corroborates/refines an existing card,
> or `[GAP]` if it's a practitioner lesson not crisply in the substrate (these
> are the highest-value additions).
>
> Status of entries: **design-stage** = reasoned from source/cards, not yet
> exercised in compiled code; **build-stage** = hit while CC implemented;
> **audit-stage** = surfaced by CDC. Upgrade the tag when code confirms it.

---

## L01 — A resource holding a raw pointer to another resource must keep it alive
**Strength: MUST. Stage: design. `[substrate: nif-resources]` (refines).**

minimidio's `mm_device.ctx` is a raw back-pointer to its `mm_context`, and the
device dereferences it on every send (ALSA: `dev->ctx->al.seq`). When each lives
in its own resource object, GC of the context resource would dangle the device's
pointer. The cards cover `enif_keep_resource`/`enif_release_resource` but not this
*cross-resource ownership* pattern specifically — that's the refinement.

```c
/* Bad - device resource stores ctx pointer, but nothing keeps ctx alive;
   if Erlang GCs the context handle, dev->ctx dangles -> use-after-free */
dev_res->dev.ctx = &ctx_res->ctx;
return enif_make_resource(env, dev_res);

/* Good - pin the parent for the child's whole life; release in the child dtor */
dev_res->dev.ctx = &ctx_res->ctx;
dev_res->ctx_res = ctx_res;
enif_keep_resource(ctx_res);          /* parent can't be collected while child lives */
return enif_make_resource(env, dev_res);
/* in dev dtor: enif_release_resource(dev_res->ctx_res); */
```

## L02 — Guard explicit-close vs destructor against double cleanup
**Strength: MUST. Stage: design. `[GAP]` (practitioner gotcha).**

If you expose an explicit `close/1` *and* run cleanup in the resource destructor,
a close followed by GC double-frees the underlying OS handle. The fix is a `live`
flag in the resource, checked by both paths. Not crisply stated in the cards.

```c
/* Bad - destructor always uninits; explicit close already did -> double free */
static void dtor(ErlNifEnv* e, void* obj) {
    midiio_ctx_res* r = obj;
    mm_context_uninit(&r->ctx);        /* runs even after context_close/1 */
}

/* Good - single-shot guarded by a liveness flag */
static void dtor(ErlNifEnv* e, void* obj) {
    midiio_ctx_res* r = obj;
    if (r->live) { mm_context_uninit(&r->ctx); r->live = 0; }
}
```

## L03 — `enif_send` from a non-ERTS thread: NULL caller_env + owned msg_env
**Strength: MUST. Stage: design. `[substrate: nif-thread-safety]` (corroborates).**

minimidio's receive callback runs on a backend thread (CoreMIDI read-proc / ALSA
`pthread`), not a scheduler thread. Crossing into the BEAM requires `caller_env =
NULL` and a process-independent environment allocated per delivery; the env is
invalidated on a successful send and must be freed (or `enif_clear_env`'d for
reuse).

```c
/* Bad - reusing a process-bound env / passing the callback's stack env,
   or reusing msg_env after a successful send */
enif_send(some_env, &pid, some_env, term);   /* wrong env from a custom thread */

/* Good - own a process-independent env, send with NULL caller_env, then free */
ErlNifEnv* msg_env = enif_alloc_env();
ERL_NIF_TERM t = enif_make_tuple4(msg_env, midi_in_atom,
                                  enif_make_resource(msg_env, dev_res),
                                  bytes_term, ts_term);
enif_send(NULL, &owner_pid, msg_env, t);     /* NULL: not an ERTS thread */
enif_free_env(msg_env);                       /* invalidated by the send */
```

## L04 — Copy transient C buffers into the binary *during* the callback
**Strength: MUST. Stage: design. `[GAP]` (lifetime gotcha).**

minimidio's inbound SysEx pointer (`mm_message.sysex`) points into an OS/transient
buffer valid only for the callback's duration (CoreMIDI `&pkt->data[...]`, ALSA
`da->sysex_buf`). It must be copied into an `ErlNifBinary` before the callback
returns; capturing the pointer to use later reads freed memory.

```c
/* Bad - stash the engine's pointer and build the term later */
saved_ptr = msg->sysex; saved_len = msg->sysex_size;   /* dangles after return */

/* Good - copy into a binary inside the callback, then send */
ERL_NIF_TERM bin_term;
unsigned char* p = enif_make_new_binary(msg_env, msg->sysex_size, &bin_term);
memcpy(p, msg->sysex, msg->sysex_size);
```

## L05 — Mutable resource state shared with a callback thread needs a lock
**Strength: MUST. Stage: design. `[substrate: nif-thread-safety]` (corroborates).**

A re-settable owner pid lives in the device resource, *read* by the recv thread
and *written* by a `set_owner/2` NIF on a scheduler thread. That read/write race
needs an `ErlNifMutex` (or an atomic). "Resource objects also require
synchronization if you treat them as mutable" — exactly this.

```c
/* Bad - recv thread reads r->owner while set_owner writes it: torn read / race */
enif_send(NULL, &r->owner, env, t);

/* Good - guard the shared field */
enif_mutex_lock(r->lock); ErlNifPid to = r->owner; enif_mutex_unlock(r->lock);
enif_send(NULL, &to, env, t);
```

## L06 — Blocking C calls: dirty-I/O, not a plain NIF; mind the fast-path tax
**Strength: SHOULD (dirty for blocking) / CONSIDER (static vs conditional). Stage: design. `[substrate: dirty-nif-schedulers]` (refines).**

ALSA's `snd_seq_drain_output` can block; a blocking syscall can't be chunked, so
yielding doesn't apply — dirty **I/O** is the tool (`ERL_NIF_DIRTY_JOB_IO_BOUND`).
Refinement the cards don't make: a *static* dirty flag also routes the
*non-blocking* backends (CoreMIDI/WinMM) through the dirty scheduler, paying
dispatch latency on the fast path. For latency-sensitive work, a regular NIF that
`enif_schedule_nif`s to dirty only when it would block is the alternative — at the
cost of more moving parts. Decide by measuring.

```erlang
%% Bad - blocking native send on a normal scheduler stalls the scheduler thread
{"send", 2, send_nif}                       %% drain_output may block here

%% Good - declare the blocking send dirty-I/O
{"send", 2, send_nif, 'ERL_NIF_DIRTY_JOB_IO_BOUND'}
```

## L07 — Open resource types in `load` only
**Strength: MUST. Stage: design. `[substrate: nif-resources]` (corroborates).**

`enif_open_resource_type` is only valid during the `load`/`upgrade` callback.
Calling it lazily from a regular NIF fails.

```c
/* Bad - open the type on first use inside a NIF */
static ERL_NIF_TERM context_open(ErlNifEnv* e, int c, const ERL_NIF_TERM a[]) {
    if (!ctx_type) ctx_type = enif_open_resource_type(e, ...);   /* invalid here */

/* Good - open it once, in load */
static int load(ErlNifEnv* e, void** priv, ERL_NIF_TERM info) {
    ctx_type = enif_open_resource_type(e, NULL, "midiio_context",
                                       dtor, ERL_NIF_RT_CREATE, NULL);
    return ctx_type ? 0 : -1;
}
```

## L08 — The loading ritual: `-on_load` + `-nifs` + `nif_error` stubs + priv_dir
**Strength: MUST. Stage: design. `[substrate: nif-loading, nifs-attribute]` (corroborates).**

```erlang
%% Bad - no stub: pre-load calls crash opaquely; Dialyzer can't see the real fn;
%% load path hard-codes a build dir
-export([context_open/0]).
context_open() -> ok.                       %% silently wrong before NIF loads

%% Good - stub raises cleanly, -nifs declares the override, on_load finds priv
-on_load(init/0).
-nifs([context_open/0]).
init() -> erlang:load_nif(filename:join(code:priv_dir(midiio), "midiio_nif"), 0).
context_open() -> erlang:nif_error(nif_not_loaded).
```

## L09 — macOS NIF artifact extension vs `load_nif` path
**Strength: SHOULD. Stage: design (flagged risk for build slice). `[GAP]` (toolchain gotcha).**

`erlang:load_nif/2` takes the library path **without** extension and appends the
OS-appropriate one. The `pc` plugin's output name and the Darwin `.so`-vs-`.dylib`
question is the most likely first-build snag (undermidi's sp_midi build even
symlinks `.dylib`→`.so` on Darwin). Verify the artifact `load_nif` resolves to on
each OS. *(Promote to build-stage with the concrete resolution once CC builds it.)*

```erlang
%% Bad - hard-code an extension; fails on the OS that uses the other one
erlang:load_nif("priv/midiio_nif.so", 0).

%% Good - no extension; let load_nif resolve it, ensure the artifact name matches
erlang:load_nif(filename:join(code:priv_dir(midiio), "midiio_nif"), 0).
```

## L10 — A NIF uses `erl_nif` only — do not link `erl_interface`/use the term format
**Strength: SHOULD. Stage: design. `[substrate: erl-nif-api]` (corroborates).**

`erl_nif` has its own term API (`enif_make_*`/`enif_get_*`); it does not use the
external term format, so a NIF needs neither `ei`/`erl_interface` linking nor that
code. (Carrying over port-driver instincts here is a common confusion.)

## L11 — Inside NIF code, allocate with `enif_alloc`, not `malloc`
**Strength: SHOULD. Stage: design. `[substrate: driver-memory-management]` (analogous).**

The driver rule (`driver_alloc` over `malloc`) has a NIF analogue: `enif_alloc`/
`enif_free` use the VM's allocators. (Caveat observed: minimidio *itself* mallocs
a `pollfd` set on its own recv thread — that's the vendored library's concern on
its own thread, not our NIF's scheduler-context allocation. Worth a note on where
the boundary of "our NIF code" ends and "the vendored engine" begins.)

## L12 — "Ports first" is the default; a NIF needs a justification, recorded
**Strength: CONSIDER. Stage: design. `[substrate: native-code-safety, nif-efficiency]` (corroborates).**

TL-13/PF-16 and the safety card all say: prefer a port (crash-isolated) and reach
for a NIF only when justified — and a NIF crash takes the whole VM. midiio's
recorded justification: realtime device latency *and* the inbound
callback→`enif_send` bridge has no clean port-program equivalent; the crash risk
is mitigated by a thin surface + resource destructors reclaiming OS handles. The
*pattern* worth teaching: **write the port-vs-NIF justification down in the design
doc as an alternative-considered** — don't reach for the NIF by default.

## L13 — A NIF module breaks `cover` unless `ERL_NIF_INIT` has an `upgrade` callback
**Strength: SHOULD. Stage: build (slice1). `[GAP]` — high-value, not in the cards.**

`cover` instruments a module by recompiling and **reloading** it; the reload
re-runs `-on_load` → `erlang:load_nif/2` against an already-loaded NIF library.
With no `upgrade` callback in `ERL_NIF_INIT`, that reload fails, so `cover` can't
instrument the module — and the coverage gate silently becomes a no-op
(`--min_coverage=0` to keep the alias green). Every later slice inherits the dead
gate. Surfaced in midiio slice1 (CDC finding F1).

```c
/* Bad - no upgrade callback: cover's reload re-triggers load_nif and fails,
   so coverage cannot instrument the module (gate silently disabled) */
ERL_NIF_INIT(midiio, nif_funcs, load, NULL, NULL, NULL)

/* Bad - upgrade that just calls load(): re-opens the resource type with
   RT_CREATE (fails/dupes — it already exists) and re-creates the mutex (leaks
   the old one; the new instance shares the static, so it now dangles a count). */
static int upgrade(ErlNifEnv* e, void** p, void** op, ERL_NIF_TERM i)
{ return load(e, p, i); }

/* Good - one shared init path; the resource-type flag is the only thing that
   differs (CREATE on load, TAKEOVER on upgrade). The .so persists across a BEAM
   reload, so the mutex + atoms are shared statics — create the mutex once,
   re-derive the (immutable) atoms idempotently, and never free shared statics in
   unload (NULL). */
static int init_statics(ErlNifEnv* e, ErlNifResourceFlags flags) {
    ErlNifResourceType* rt =
        enif_open_resource_type(e, NULL, "midiio_context", dtor, flags, NULL);
    if (!rt) return -1;
    g_res_type = rt;
    if (!g_lock) { g_lock = enif_mutex_create("lock"); if (!g_lock) return -1; }
    /* am_* = enif_make_atom(e, ...);  (idempotent) */
    return 0;
}
static int load(ErlNifEnv* e, void** p, ERL_NIF_TERM i)
{ (void)p; (void)i; return init_statics(e, ERL_NIF_RT_CREATE); }
static int upgrade(ErlNifEnv* e, void** p, void** op, ERL_NIF_TERM i)
{ (void)p; (void)op; (void)i; return init_statics(e, ERL_NIF_RT_TAKEOVER); }
ERL_NIF_INIT(midiio, nif_funcs, load, NULL, upgrade, NULL)
```

**Resolved (slice-1 F1 remediation, 2026-06-17).** Implemented exactly as the
Good example. `RT_TAKEOVER` lets the new module instance inherit the existing
resource type (its dtor applies to inherited objects); the mutex/atoms are shared
because the same `.so` is reused across the reload, so they must not be
re-created; `unload` stays NULL (freeing the shared mutex would dangle the live
instance). Result: `cover` instruments `midiio.beam` (33% real line data, was
"cannot cover"), and `--min_coverage` was raised 0 → 30 (the 4 uncovered lines
are the `nif_error` stub bodies, unreachable once the `.so` loads). Verified
against `nif-lifecycle` (load/upgrade/unload + RT_TAKEOVER) and `nif-resources`
(type takeover/inheritance).

## L14 — A resource handle is a *magic reference*; test opacity by type-check, not term shape
**Strength: SHOULD. Stage: build (slice1). `[GAP]`.**

Since ~OTP 20, `enif_make_resource` returns a **magic reference**, so
`is_reference(Handle)` is `true`. A test that asserts opacity via
"`is_reference orelse is_binary` is false" cannot pass with an idiomatic resource.
Assert the property that actually matters — *type-checked* opacity: the handle is
accepted by its own NIFs, and a forged/foreign `make_ref()` is rejected.

```erlang
%% Bad - "not a reference/binary" as the opacity test; fails on a real resource
?assert(not (is_reference(R) orelse is_binary(R))).

%% Good - type-checked opacity: opaque to inspection, validated on use
?assert(is_reference(R)),                              %% it IS a magic ref - fine
?assertError(badarg, midiio:context_close(make_ref())). %% a foreign ref is rejected
```

## L15 — Keep test-only introspection NIFs out of the shipped surface
**Strength: CONSIDER. Stage: build (slice1). `[GAP]`.**

Verifying destructor/refcount behaviour often needs introspection NIFs (e.g. a
`uninit_count/0`, a `result_atom/1`). They're legitimate test infrastructure, but
exporting them ships them as public API. Gate them behind a test build so the
release surface stays minimal.

```erlang
%% Bad - test-only NIFs permanently in the public module surface
-nifs([context_open/0, context_close/1, result_atom/1, uninit_count/0]).

%% Good - compile the introspection NIFs (and their stubs) only under -DMIDIIO_TEST
%% (C side guards the ErlNifFunc entries; Erlang side conditionally exports them)
```

## L16 — Under a test-scoped `check`, teach the PLT the test apps
**Strength: CONSIDER. Stage: build (slice1). `[substrate: tooling]` (refines).**

When `dialyzer` runs inside the `test` profile (because the proper plugin is
test-scoped), it also analyses the eunit/proper-generated entry points; without
the apps in the PLT they're flagged "unknown".

```erlang
%% Bad - dialyzer under `as test` flags eunit's generated test/0 as unknown
{dialyzer, [{warnings, [unknown]}]}.

%% Good - add the test apps so their generated entry points resolve
{dialyzer, [{warnings, [unknown]}, {plt_extra_apps, [eunit, proper]}]}.
```

## L17 — BEAM line-coverage is structurally weak for a NIF module; cover the C separately
**Strength: CONSIDER. Stage: audit (slice-1 F1 CDC). `[GAP]` — high-value.**

A NIF module's Erlang side is mostly `nif_error` stub bodies that the `.so`
replaces once loaded, so they are **unreachable by construction** and drag the
`cover` percentage down (midiio: 33% — only `init/0` is reachable Erlang; the four
stub bodies can never execute). And the real logic lives in **C**, which BEAM
`cover` cannot see at all. Two consequences for how you set and read coverage:

1. Don't chase a high BEAM `min_coverage` on a NIF module — the achievable ceiling
   is bounded well below 100% by the stub count. Set the floor against the
   *reachable* lines and **document the unreachable stubs** (don't add contrived
   tests to inflate it).
2. The BEAM % is **not** the coverage story for the NIF. Cover the C with its own
   discipline — a sanitizer harness (ASan + LeakSanitizer) plus behavioural eunit
   that drives the NIFs across their states — and treat that, not the line %, as
   the evidence the native code is exercised.

```text
Bad  - read "midiio.beam 33%" as "the NIF is poorly tested", or raise the BEAM
       min_coverage toward 100 and backfill contrived tests for unreachable stubs.
Good - floor against reachable Erlang lines (note the stub bodies are unreachable);
       prove the C with ASan/LSan + behavioural eunit. Two different coverage
       stories for the two languages; don't let one masquerade as the other.
```

## L18 — Conditional/test-only NIFs are hard under rebar3 + `pc`: one shared `.so` across profiles
**Strength: CONSIDER. Stage: build (slice-5 F2, deferred). `[GAP]`.**

Gating test-only NIFs behind `-DMIDIIO_TEST` (so they don't ship) sounds simple —
`#ifdef` the C `ErlNifFunc` entries, `-ifdef(TEST)` the Erlang `-nifs`, add the
macro to the test profile. It isn't, because the **`pc` port-compiler builds one
shared `.so` in the source tree, not per-profile under `_build/`**. So a default
`rebar3 compile` (no macro, N NIFs) followed by `rebar3 as test check` (Erlang now
declares N+k `-nifs`) **reuses the stale default `.so`** → `load_nif` arity
mismatch → `nif_not_loaded`. The build is *order-dependent*. Making it robust
needs a per-profile `.so` artifact path (or a test pre-hook that force-rebuilds
the `.so` under the macro) — disproportionate for harmless test NIFs.

```text
Bad  - #ifdef MIDIIO_TEST the NIF set + add the macro only to the test profile,
       assuming each profile gets its own .so. Default-then-test reuses the stale
       default .so → load_nif mismatch (order-dependent, flaky).
Good - either keep the introspection NIFs unconditionally (they're harmless), or
       give the test build its own .so artifact path so the binary's NIF set
       always matches the module's -nifs. Don't split the NIF set across profiles
       while a single shared .so is built in-tree.
```

---

## Open threads to resolve into learnings as the build proceeds

- ~~The exact `pc` `port_specs` / artifacts incantation that builds + loads cleanly
  on macOS and Linux under this rebar3 (build-stage; L09).~~ **Resolved (slice 1
  build + slice 4 Makefile):** `port_specs`/`port_env` per-OS in `rebar.config`
  (`-framework CoreMIDI` / `-lasound -lpthread`), `pc` emits `priv/midiio_nif.so`
  on Darwin (not `.dylib`), and `load_nif` resolves the extensionless name. Linux
  build still unexercised (slice-1 row 3, deferred).
- Whether `enif_make_new_binary` vs `enif_alloc_binary`/`enif_make_binary` is the
  right inbound-bytes path under the per-delivery-env model (build-stage; L04).
- Destructor ordering / refcount behavior under a crashing owner process — does
  the GC-of-handle path reclaim ALSA's recv `pthread` + wake pipe cleanly?
  (audit-stage; ties L01/L02.)
- Sanitizer/valgrind findings on the open/close/GC cycle (audit-stage).
- Whether static dirty-I/O dispatch latency is actually a problem for realtime
  MIDI, measured (build/audit-stage; L06, design D3).
