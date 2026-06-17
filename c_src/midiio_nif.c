/*
 * midiio_nif.c — NIF over the minimidio C library.
 *
 * arc1/slice1 scope: load callback + per-call context resource lifecycle only.
 * No enumeration, no device I/O, no dirty NIFs, no enif_send, no threads.
 * See docs/planning/v0.1.0/arc1/slice1/ for the slice doc and ledger.
 */

#define MINIMIDIO_IMPLEMENTATION
#include "minimidio.h"

#include <erl_nif.h>

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

/* ── load ───────────────────────────────────────────────────────────────── */

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data;
    (void)load_info;

    g_ctx_res_type = enif_open_resource_type(
        env, NULL, "midiio_context", dtor_context, ERL_NIF_RT_CREATE, NULL);
    if (g_ctx_res_type == NULL)
        return -1;

    g_uninit_lock = enif_mutex_create("midiio_uninit_lock");
    if (g_uninit_lock == NULL)
        return -1;

    am_ok           = enif_make_atom(env, "ok");
    am_error        = enif_make_atom(env, "error");
    am_invalid_arg  = enif_make_atom(env, "invalid_arg");
    am_no_backend   = enif_make_atom(env, "no_backend");
    am_out_of_range = enif_make_atom(env, "out_of_range");
    am_already_open = enif_make_atom(env, "already_open");
    am_not_open     = enif_make_atom(env, "not_open");
    am_alloc_failed = enif_make_atom(env, "alloc_failed");

    return 0;
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
 * mm_result -> atom mapping (ledger row 9). Not part of the device API. */
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

static ErlNifFunc nif_funcs[] = {
    {"context_open",  0, context_open},
    {"context_close", 1, context_close},
    {"result_atom",   1, result_atom},
    {"uninit_count",  0, uninit_count},
};

ERL_NIF_INIT(midiio, nif_funcs, load, NULL, NULL, NULL)
