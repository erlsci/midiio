/*
 * midiio_nif.c — NIF over the minimidio C library.
 *
 * arc1/slice1: load callback + per-call context resource lifecycle.
 * arc1/slice3: read-only discovery — list_inputs/1, list_outputs/1, caps/1.
 * No device open, no I/O, no dirty NIFs, no enif_send, no threads.
 * See docs/planning/v0.1.0/arc1/ for the slice docs and ledgers.
 */

#define MINIMIDIO_IMPLEMENTATION
#include "minimidio.h"

#include <erl_nif.h>
#include <string.h>

/* Compile-time backend atom name, picked by minimidio's platform macro
 * (defined in minimidio.h before the public structs). */
#if defined(MM_BACKEND_COREMIDI)
#  define MIDIIO_BACKEND "coremidi"
#elif defined(MM_BACKEND_WINMM)
#  define MIDIIO_BACKEND "winmm"
#elif defined(MM_BACKEND_ALSA)
#  define MIDIIO_BACKEND "alsa"
#elif defined(MM_BACKEND_WEBMIDI)
#  define MIDIIO_BACKEND "webmidi"
#else
#  define MIDIIO_BACKEND "unknown"
#endif

/* ── Resource type ──────────────────────────────────────────────────────────
 * The context is embedded by value. `live` is the slice's own lifecycle flag:
 * mm_context_uninit guards on its internal `initialized`, but the resource must
 * track liveness independently so an explicit context_close/1 followed by the
 * GC-triggered destructor does not uninit twice. The `live` flag is the single
 * source of truth; do_uninit is the one path that flips it.
 */
typedef struct {
    mm_context ctx;
    int        live;
} midiio_ctx_res;

static ErlNifResourceType *g_ctx_res_type = NULL;

/* uninit accounting: the destructor runs on a scheduler thread while an
 * explicit close runs on the caller thread, so the live-flag transition and
 * the count are guarded by one mutex (nif-thread-safety: shared mutable state
 * needs explicit synchronization). The count exists for test verification of
 * "exactly one uninit per context" (ledger row 7). */
static ErlNifMutex *g_uninit_lock  = NULL;
static int          g_uninit_count = 0;

/* Atoms pre-made in load() so they are valid in any environment
 * (erl-nif best practice). */
static ERL_NIF_TERM am_ok;
static ERL_NIF_TERM am_error;
static ERL_NIF_TERM am_invalid_arg;
static ERL_NIF_TERM am_no_backend;
static ERL_NIF_TERM am_out_of_range;
static ERL_NIF_TERM am_already_open;
static ERL_NIF_TERM am_not_open;
static ERL_NIF_TERM am_alloc_failed;

/* caps/1 map keys + boolean values + the compile-time backend atom (slice 3). */
static ERL_NIF_TERM am_true;
static ERL_NIF_TERM am_false;
static ERL_NIF_TERM am_backend;
static ERL_NIF_TERM am_midi1;
static ERL_NIF_TERM am_ump;
static ERL_NIF_TERM am_midi2;
static ERL_NIF_TERM am_virtual_in;
static ERL_NIF_TERM am_virtual_out;
static ERL_NIF_TERM g_backend_atom;

/* ── Helpers ────────────────────────────────────────────────────────────── */

/* Map an mm_result to its atom. success is the caller's `ok`; the 7 errors map
 * to their lowercase atoms (DESIGN.md §6). Covers all 8 result codes. */
static ERL_NIF_TERM result_to_atom(mm_result r)
{
    switch (r) {
        case MM_SUCCESS:      return am_ok;
        case MM_ERROR:        return am_error;
        case MM_INVALID_ARG:  return am_invalid_arg;
        case MM_NO_BACKEND:   return am_no_backend;
        case MM_OUT_OF_RANGE: return am_out_of_range;
        case MM_ALREADY_OPEN: return am_already_open;
        case MM_NOT_OPEN:     return am_not_open;
        case MM_ALLOC_FAILED: return am_alloc_failed;
        default:              return am_error;
    }
}

/* The single cleanup path shared by context_close/1 and the destructor.
 * Returns 1 if it performed the uninit, 0 if the context was already not live.
 * Idempotent: safe to call after an explicit close (no double uninit). */
static int do_uninit(midiio_ctx_res *res)
{
    int did = 0;
    enif_mutex_lock(g_uninit_lock);
    if (res->live) {
        mm_context_uninit(&res->ctx);
        res->live = 0;
        g_uninit_count++;
        did = 1;
    }
    enif_mutex_unlock(g_uninit_lock);
    return did;
}

static void dtor_context(ErlNifEnv *env, void *obj)
{
    (void)env;
    do_uninit((midiio_ctx_res *)obj);
}

/* ── load / upgrade ─────────────────────────────────────────────────────────
 * The NIF .so is loaded once and persists; a BEAM-module reload (e.g. cover
 * instrumentation, or a hot upgrade) re-runs -on_load against the same library,
 * which fires `upgrade` rather than `load`. Because the same .so is reused, the
 * module-level statics (g_ctx_res_type, g_uninit_lock, the am_* atoms,
 * g_uninit_count) are SHARED across module instances (ERTS: "sharing the dynamic
 * library means static data is shared as well"). So:
 *   - the resource type must be *taken over* on upgrade, not re-created
 *     (ERL_NIF_RT_TAKEOVER) — the new instance inherits existing resources and
 *     its dtor applies to them (nif-lifecycle / nif-resources cards);
 *   - the mutex is created once and reused (re-creating it would leak the old
 *     one and dangle the count); and
 *   - `unload` stays NULL — freeing the shared mutex when the old instance is
 *     purged would dangle the live instance that still holds it.
 * init_statics() is the single shared path so load and upgrade cannot diverge.
 */
static int init_statics(ErlNifEnv *env, ErlNifResourceFlags flags)
{
    ErlNifResourceType *rt = enif_open_resource_type(
        env, NULL, "midiio_context", dtor_context, flags, NULL);
    if (rt == NULL)
        return -1;
    g_ctx_res_type = rt;

    /* Created on first load; reused (not re-created) on takeover. */
    if (g_uninit_lock == NULL) {
        g_uninit_lock = enif_mutex_create("midiio_uninit_lock");
        if (g_uninit_lock == NULL)
            return -1;
    }

    /* Atoms are global and immutable; (re-)deriving them is idempotent. */
    am_ok           = enif_make_atom(env, "ok");
    am_error        = enif_make_atom(env, "error");
    am_invalid_arg  = enif_make_atom(env, "invalid_arg");
    am_no_backend   = enif_make_atom(env, "no_backend");
    am_out_of_range = enif_make_atom(env, "out_of_range");
    am_already_open = enif_make_atom(env, "already_open");
    am_not_open     = enif_make_atom(env, "not_open");
    am_alloc_failed = enif_make_atom(env, "alloc_failed");

    am_true         = enif_make_atom(env, "true");
    am_false        = enif_make_atom(env, "false");
    am_backend      = enif_make_atom(env, "backend");
    am_midi1        = enif_make_atom(env, "midi1");
    am_ump          = enif_make_atom(env, "ump");
    am_midi2        = enif_make_atom(env, "midi2");
    am_virtual_in   = enif_make_atom(env, "virtual_in");
    am_virtual_out  = enif_make_atom(env, "virtual_out");
    g_backend_atom  = enif_make_atom(env, MIDIIO_BACKEND);

    return 0;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data;
    (void)load_info;
    return init_statics(env, ERL_NIF_RT_CREATE);
}

static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data,
                   ERL_NIF_TERM load_info)
{
    (void)priv_data;
    (void)old_priv_data;
    (void)load_info;
    return init_statics(env, ERL_NIF_RT_TAKEOVER);
}

/* ── NIFs ───────────────────────────────────────────────────────────────── */

/* context_open() -> {ok, Ctx} | {error, Atom}
 * mm_context_init is a fast OS call (MIDIClientCreate / snd_seq_open), well
 * under 1 ms — a regular, non-dirty NIF. */
static ERL_NIF_TERM context_open(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;

    midiio_ctx_res *res =
        enif_alloc_resource(g_ctx_res_type, sizeof(midiio_ctx_res));
    if (res == NULL)
        return enif_make_tuple2(env, am_error, am_alloc_failed);
    res->live = 0;

    mm_result r = mm_context_init(&res->ctx, NULL);
    if (r != MM_SUCCESS) {
        /* Drops the only reference; the destructor runs and, seeing live == 0,
         * does not uninit a context that never initialized. */
        enif_release_resource(res);
        return enif_make_tuple2(env, am_error, result_to_atom(r));
    }
    res->live = 1;

    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res); /* Erlang term is now the sole owner */
    return enif_make_tuple2(env, am_ok, term);
}

/* context_close(Ctx) -> ok | {error, not_open}
 * Bad arg (not a midiio_context resource) crashes with badarg — let it crash. */
static ERL_NIF_TERM context_close(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[])
{
    (void)argc;

    midiio_ctx_res *res = NULL;
    if (!enif_get_resource(env, argv[0], g_ctx_res_type, (void **)&res))
        return enif_make_badarg(env);

    if (do_uninit(res))
        return am_ok;
    return enif_make_tuple2(env, am_error, am_not_open);
}

/* result_atom(Code) -> atom()
 * Test/introspection NIF: exposes result_to_atom so eunit can assert the full
 * mm_result -> atom mapping (ledger row 9). Not part of the device API.
 * NOTE (F2, disclosed-deferred in arc1/slice5): gating this and uninit_count/0
 * out of the default build via -DMIDIIO_TEST was attempted and reverted — pc
 * builds one shared .so in the source tree across profiles, so a test-only NIF
 * set makes load_nif order-dependent. See slice5 closing report for re-entry. */
static ERL_NIF_TERM result_atom(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[])
{
    (void)argc;

    int code;
    if (!enif_get_int(env, argv[0], &code))
        return enif_make_badarg(env);
    return result_to_atom((mm_result)code);
}

/* uninit_count() -> integer()
 * Test/introspection NIF: the global count of mm_context_uninit calls, so eunit
 * can verify the destructor runs exactly once on GC (ledger row 7). */
static ERL_NIF_TERM uninit_count(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;

    enif_mutex_lock(g_uninit_lock);
    int c = g_uninit_count;
    enif_mutex_unlock(g_uninit_lock);
    return enif_make_int(env, c);
}

/* ── Enumeration + capabilities (slice 3, read-only) ────────────────────────── */

static ERL_NIF_TERM bool_atom(int truthy)
{
    return truthy ? am_true : am_false;
}

/* Build [{Index, NameBin}, …] in ascending index order for a count/name pair.
 * Every in-range index gets an entry even if its name lookup fails — minimidio
 * writes a placeholder (e.g. CoreMIDI's "(unknown)") and dropping the entry
 * would desync the index from reality. The name buffer is pre-NUL'd so a
 * non-writing failure yields an empty binary rather than garbage. Index is a
 * display-only snapshot ordinal (DESIGN §5), not identity. */
typedef uint32_t  (*mm_count_fn)(mm_context *);
typedef mm_result (*mm_name_fn)(mm_context *, uint32_t, char *, size_t);

static ERL_NIF_TERM enumerate(ErlNifEnv *env, mm_context *ctx,
                              mm_count_fn count_fn, mm_name_fn name_fn)
{
    uint32_t     n    = count_fn(ctx);
    ERL_NIF_TERM list = enif_make_list(env, 0); /* [] */

    /* Descend so head-first cons yields ascending 0..n-1. */
    for (uint32_t i = n; i-- > 0;) {
        char buf[256];
        buf[0] = '\0';
        (void)name_fn(ctx, i, buf, sizeof buf); /* entry kept regardless of result */

        size_t         len = strlen(buf);
        ERL_NIF_TERM   name_bin;
        unsigned char *p = enif_make_new_binary(env, len, &name_bin);
        memcpy(p, buf, len);

        ERL_NIF_TERM cell = enif_make_tuple2(env, enif_make_uint(env, i), name_bin);
        list = enif_make_list_cell(env, cell, list);
    }
    return list;
}

/* list_inputs(Ctx) -> [{Index, Name}] — fresh query, no caching. */
static ERL_NIF_TERM list_inputs(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    midiio_ctx_res *res = NULL;
    if (!enif_get_resource(env, argv[0], g_ctx_res_type, (void **)&res))
        return enif_make_badarg(env);
    return enumerate(env, &res->ctx, mm_in_count, mm_in_name);
}

/* list_outputs(Ctx) -> [{Index, Name}] — fresh query, no caching. */
static ERL_NIF_TERM list_outputs(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    midiio_ctx_res *res = NULL;
    if (!enif_get_resource(env, argv[0], g_ctx_res_type, (void **)&res))
        return enif_make_badarg(env);
    return enumerate(env, &res->ctx, mm_out_count, mm_out_name);
}

/* caps(Ctx) -> #{backend := atom(), <flag> := boolean(), …}
 * backend is the compile-time platform atom; flags decode mm_context_caps. */
static ERL_NIF_TERM caps(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    midiio_ctx_res *res = NULL;
    if (!enif_get_resource(env, argv[0], g_ctx_res_type, (void **)&res))
        return enif_make_badarg(env);

    uint32_t     c = mm_context_caps(&res->ctx);
    ERL_NIF_TERM m = enif_make_new_map(env);
    enif_make_map_put(env, m, am_backend,     g_backend_atom,                  &m);
    enif_make_map_put(env, m, am_midi1,       bool_atom(c & MM_CAP_MIDI1),     &m);
    enif_make_map_put(env, m, am_ump,         bool_atom(c & MM_CAP_UMP),       &m);
    enif_make_map_put(env, m, am_midi2,       bool_atom(c & MM_CAP_MIDI2),     &m);
    enif_make_map_put(env, m, am_virtual_in,  bool_atom(c & MM_CAP_VIRTUAL_IN),  &m);
    enif_make_map_put(env, m, am_virtual_out, bool_atom(c & MM_CAP_VIRTUAL_OUT), &m);
    return m;
}

static ErlNifFunc nif_funcs[] = {
    {"context_open",  0, context_open},
    {"context_close", 1, context_close},
    {"result_atom",   1, result_atom},
    {"uninit_count",  0, uninit_count},
    {"list_inputs",   1, list_inputs},
    {"list_outputs",  1, list_outputs},
    {"caps",          1, caps},
};

/* Args: module, funcs, load, reload(deprecated→NULL), upgrade, unload.
 * upgrade is non-NULL so a module reload (cover / hot upgrade) succeeds; unload
 * is NULL because the shared statics must outlive an old purged instance. */
ERL_NIF_INIT(midiio, nif_funcs, load, NULL, upgrade, NULL)
