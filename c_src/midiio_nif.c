/*
 * midiio_nif.c — NIF over the minimidio C library.
 *
 * arc1/slice1: load callback + per-call context resource lifecycle.
 * arc1/slice3: read-only discovery — list_inputs/1, list_outputs/1, caps/1.
 * arc2/slice1: output device resource + lifecycle (open_output/close).
 * arc2/slice2: send/2 over the raw seam (midiio_send.h), the first dirty NIF.
 * No inbound / recv / enif_send / owner pid yet (arc 3).
 * See docs/planning/v0.1.0/ for the slice docs and ledgers.
 */

#define MINIMIDIO_IMPLEMENTATION
#include "minimidio.h"

#include <erl_nif.h>
#include <string.h>
#include <stdatomic.h>

/* The raw send + receive seams + interim adapters (arc2/slice2, arc3/slice1).
 * Included after minimidio.h because they use mm_device / mm_message. */
#include "midiio_send.h"
#include "midiio_recv.h"

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

/* A device owns its own per-device mm_context (DESIGN §2 / arc-2 model): no
 * shared registry context — the context is embedded, so one guarded cleanup
 * closes the port then uninits the context.
 *
 * arc3/slice1 adds, for inputs and the F1 close:
 *  - is_input: outputs leave owner/keep inert;
 *  - owner: the recv target, read by the recv thread, written by set_owner/2;
 *  - kept: whether the recv-thread reference (enif_keep_resource) is still held
 *    (released exactly once, after mm_in_stop, by stop_input/close/cleanup);
 *  - lock: a PER-DEVICE mutex guarding owner R/W, send's live-check-and-use, and
 *    cleanup's teardown — so a concurrent send and close cannot UAF (finding F1).
 *    Uncontended under the single-owner contract (DESIGN §4 D3 realtime intent).
 *    Created in every open_*; destroyed LAST in the destructor (never while held). */
typedef struct {
    mm_context    ctx;
    mm_device     dev;
    int           live;
    int           is_input;
    int           kept;
    int           monitored;   /* an owner-death monitor is armed (inputs only) */
    ErlNifPid     owner;
    ErlNifMonitor monitor;     /* fires down_device when the owner process dies */
    ErlNifMutex  *lock;
} midiio_dev_res;

static ErlNifResourceType *g_dev_res_type = NULL;

/* uninit accounting: the destructor runs on a scheduler thread while an
 * explicit close runs on the caller thread, so the live-flag transition and
 * the count are guarded by one mutex (nif-thread-safety: shared mutable state
 * needs explicit synchronization). The count exists for test verification of
 * "exactly one uninit per context" (ledger row 7). */
static ErlNifMutex *g_uninit_lock  = NULL;
/* Atomic: context cleanup flips it under g_uninit_lock, but device cleanup now
 * runs under the *per-device* lock (F1), so the shared counter needs its own
 * lock-free synchronization rather than the global mutex. */
static atomic_int   g_uninit_count = 0;

/* Atoms pre-made in load() so they are valid in any environment
 * (erl-nif best practice). */
static ERL_NIF_TERM am_ok;
static ERL_NIF_TERM am_error;
static ERL_NIF_TERM am_invalid_arg;
static ERL_NIF_TERM am_no_backend;
static ERL_NIF_TERM am_out_of_range;
static ERL_NIF_TERM am_already_open;
static ERL_NIF_TERM am_not_open;
static ERL_NIF_TERM am_owner_not_alive; /* set_owner/2 handoff to a dead pid */
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

/* send/2 (slice 2): the tag atom for {error, {unsupported_status, B}}. B is an
 * integer in the tuple, never an atom — we never build atoms from runtime input. */
static ERL_NIF_TERM am_unsupported_status;

/* recv (arc3/slice1): the leading tag of {midi_in, Dev, Bytes, TsNanos}. */
static ERL_NIF_TERM am_midi_in;

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
        atomic_fetch_add(&g_uninit_count, 1);
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

/* The single guarded cleanup path for a device, shared by close/1 and the
 * destructor (so an explicit close followed by GC does not double-free). Order
 * matters: close the OS port first (it references the context), then uninit the
 * per-device context. Shares g_uninit_lock + g_uninit_count with do_uninit, so
 * the GC test counts a device's context uninit the same way. Returns 1 if it ran,
 * 0 if the device was already not live. */
static int do_dev_cleanup(midiio_dev_res *res)
{
    if (res->lock == NULL)
        return 0; /* never fully constructed (mutex create failed at open) */

    /* The lock guards ONLY the live flip (exactly-once) and the kept snapshot.
     * The teardown — including mm_in_stop, which on ALSA pthread_joins the recv
     * thread — runs OUTSIDE the lock, because recv_cb needs this same lock to read
     * `owner`. Joining while holding it deadlocks close-vs-active-delivery (S1).
     * The keep is still held across the teardown (released LAST), so an in-flight
     * recv_cb keeps `res` valid until the join completes. */
    enif_mutex_lock(res->lock);
    int was_live = res->live;
    if (was_live)
        res->live = 0;
    int release_keep = 0;
    if (res->kept) {
        res->kept = 0;
        release_keep = 1;
    }
    enif_mutex_unlock(res->lock);

    if (was_live) {
        if (res->is_input) {
            mm_in_stop(&res->dev);    /* joins the recv thread — outside the lock */
            mm_in_close(&res->dev);
        } else {
            mm_out_close(&res->dev);
        }
        mm_context_uninit(&res->ctx); /* port first, then the per-device context */
        atomic_fetch_add(&g_uninit_count, 1);
    }

    /* Release the recv-thread keep LAST — after the join, so `res` stayed valid
     * for any in-flight callback. Exactly once (kept-guarded above). */
    if (release_keep)
        enif_release_resource(res);
    return was_live;
}

/* The owner-death monitor's down callback (S2 close). Fires when a monitored
 * owner process dies. The resource is guaranteed alive for the duration of this
 * callback (the runtime holds it), so reclaiming via the guarded do_dev_cleanup
 * is safe: it stops the recv thread (join outside the lock, Fix 1), closes, and
 * releases the keep LAST — `res` is not touched after that release. The monitor
 * has already fired, so no demonitor is needed. Idempotent with an explicit
 * close: both funnel through the live-guarded do_dev_cleanup, so exactly one
 * tears down (nif-resources: resource alive during down → let the dtor reclaim). */
static void down_device(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon)
{
    (void)env;
    (void)pid;
    (void)mon;
    midiio_dev_res *res = (midiio_dev_res *)obj;
    res->monitored = 0;
    do_dev_cleanup(res);
}

static void dtor_device(ErlNifEnv *env, void *obj)
{
    (void)env;
    midiio_dev_res *res = (midiio_dev_res *)obj;
    do_dev_cleanup(res);
    /* The mutex is a field of the resource the VM is about to free, so destroy it
     * LAST — after the final cleanup, never while held (nif-resources). */
    if (res->lock != NULL) {
        enif_mutex_destroy(res->lock);
        res->lock = NULL;
    }
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

    /* The device type carries a `down` callback (S2: reclaim a started input
     * whose owner died), so it is registered via the init-struct form
     * (enif_init_resource_type). members=3 → {dtor, stop, down}; stop is NULL.
     * Same flags as the context type (CREATE on load, TAKEOVER on upgrade) so it
     * survives the F1 reload path. */
    ErlNifResourceTypeInit dev_init = {
        dtor_device,  /* dtor */
        NULL,         /* stop */
        down_device,  /* down */
        3,            /* members: dtor + stop + down are provided */
        NULL          /* dyncall */
    };
    ErlNifResourceType *dt = enif_init_resource_type(
        env, "midiio_device", &dev_init, flags, NULL);
    if (dt == NULL)
        return -1;
    g_dev_res_type = dt;

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

    am_unsupported_status = enif_make_atom(env, "unsupported_status");
    am_midi_in            = enif_make_atom(env, "midi_in");
    am_owner_not_alive    = enif_make_atom(env, "owner_not_alive");

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

    return enif_make_int(env, atomic_load(&g_uninit_count));
}

/* seam_roundtrip(Bytes) -> {ok, Bytes2} | {error, unsupported_status}
 * Test NIF (arc3/slice2, PropEr): drive a message through BOTH raw seams purely —
 * midiio_bytes_to_msg (outbound parse) then midiio_msg_to_bytes (inbound build),
 * no I/O. It is in the shipped surface (compile-time gating out of the single
 * shared .so isn't robust — L18; see rebar.config), but it is MEMORY-SAFE:
 * midiio_bytes_to_msg self-defends on length (S2 remediation Fix 1), so this
 * caller-skips-the-pre-check entry point cannot read OOB for any input. */
static ERL_NIF_TERM seam_roundtrip(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;

    ErlNifBinary in;
    if (!enif_inspect_binary(env, argv[0], &in) || in.size == 0)
        return enif_make_badarg(env);

    mm_message m;
    if (!midiio_bytes_to_msg(in.data, in.size, &m))
        return enif_make_tuple2(env, am_error, am_unsupported_status);

    ERL_NIF_TERM out;
    if (m.type == MM_SYSEX) {
        unsigned char *p = enif_make_new_binary(env, m.sysex_size, &out);
        if (m.sysex_size > 0)
            memcpy(p, m.sysex, m.sysex_size);
    } else {
        uint8_t  buf[3];
        size_t   n = midiio_msg_to_bytes(&m, buf);
        unsigned char *p = enif_make_new_binary(env, n, &out);
        memcpy(p, buf, n);
    }
    return enif_make_tuple2(env, am_ok, out);
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

/* ── Device lifecycle (arc 2 slice 1 output; arc 3 slice 1 input) ────────────
 * mm_context_init / mm_out_open / mm_in_open are fast OS calls, well under 1 ms —
 * regular NIFs, not dirty (only send/2 is dirty). */

/* Allocate a device resource with its per-device lock created (F1). Zeroes the
 * struct (live=0, kept=0, owner inert), sets is_input. Returns NULL on alloc
 * failure (caller returns {error, alloc_failed}). live flips to 1 only on a
 * fully successful open (device_ok). */
static midiio_dev_res *new_device(int is_input)
{
    midiio_dev_res *res =
        enif_alloc_resource(g_dev_res_type, sizeof(midiio_dev_res));
    if (res == NULL)
        return NULL;
    memset(res, 0, sizeof *res);
    res->is_input = is_input;
    res->lock = enif_mutex_create("midiio_dev_lock");
    if (res->lock == NULL) {
        enif_release_resource(res); /* dtor: do_dev_cleanup no-ops (lock NULL) */
        return NULL;
    }
    return res;
}

/* Finalize a successfully-opened device resource into {ok, Dev}. */
static ERL_NIF_TERM device_ok(ErlNifEnv *env, midiio_dev_res *res)
{
    res->live = 1;
    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res); /* Erlang term is now the sole owner */
    return enif_make_tuple2(env, am_ok, term);
}

/* The recv callback (arc3/slice1 crux). Runs on minimidio's backend thread (NOT
 * an ERTS scheduler), userdata = the kept midiio_dev_res*. Builds one
 * {midi_in, Dev, <<Bytes>>, TsNanos} in a process-independent env and delivers it
 * to the owner via enif_send. Touches no scheduler state — only the per-device
 * lock (for owner), a fresh env, and enif_send (nif-thread-safety / L03/L04). */
static void recv_cb(mm_device *dev, const mm_message *msg, void *userdata)
{
    (void)dev;
    midiio_dev_res *res = (midiio_dev_res *)userdata;

    ErlNifEnv *menv = enif_alloc_env();

    /* Bytes via the inbound seam. SysEx (msg->sysex) is callback-lifetime only,
     * so memcpy it into the binary HERE, never alias it (L04). */
    ERL_NIF_TERM bytes;
    if (msg->type == MM_SYSEX) {
        unsigned char *p = enif_make_new_binary(menv, msg->sysex_size, &bytes);
        if (msg->sysex_size > 0)
            memcpy(p, msg->sysex, msg->sysex_size);
    } else {
        uint8_t  buf[3];
        size_t   n = midiio_msg_to_bytes(msg, buf);
        unsigned char *p = enif_make_new_binary(menv, n, &bytes);
        memcpy(p, buf, n);
    }

    /* Timestamp: minimidio reports seconds (mach / CLOCK_MONOTONIC since boot —
     * the struct's "since open" comment is wrong, R5). Emit host-monotonic int64
     * nanoseconds; 0/absent → 0 ("now"). */
    ErlNifSInt64 ts_ns = (ErlNifSInt64)(msg->timestamp * 1.0e9);

    ERL_NIF_TERM term = enif_make_tuple4(
        menv, am_midi_in, enif_make_resource(menv, res), bytes,
        enif_make_int64(menv, ts_ns));

    enif_mutex_lock(res->lock);          /* owner is written by set_owner/2 */
    ErlNifPid owner = res->owner;
    enif_mutex_unlock(res->lock);

    enif_send(NULL, &owner, menv, term); /* NULL caller_env: not an ERTS thread */
    enif_free_env(menv);                 /* env invalidated by the send */
}

/* open_output(Index) -> {ok, Dev} | {error, Atom}. Per-device legibly-named
 * context. Partial-failure: uninit the context if the port open fails. */
static ERL_NIF_TERM open_output(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;

    unsigned int idx;
    if (!enif_get_uint(env, argv[0], &idx))
        return enif_make_badarg(env);

    midiio_dev_res *res = new_device(0);
    if (res == NULL)
        return enif_make_tuple2(env, am_error, am_alloc_failed);

    char name[64];
    snprintf(name, sizeof name, "midiio-out:%u", idx);

    mm_result r = mm_context_init(&res->ctx, name);
    if (r != MM_SUCCESS) {
        enif_release_resource(res);
        return enif_make_tuple2(env, am_error, result_to_atom(r));
    }

    r = mm_out_open(&res->ctx, &res->dev, idx);
    if (r != MM_SUCCESS) {
        mm_context_uninit(&res->ctx); /* don't leak the context on partial failure */
        enif_release_resource(res);
        return enif_make_tuple2(env, am_error, result_to_atom(r));
    }

    return device_ok(env, res);
}

/* open_output_virtual() -> {ok, Dev} | {error, Atom}. Test scaffolding: a virtual
 * output source (no destination needed) — also the inbound loopback's stimulus. */
static ERL_NIF_TERM open_output_virtual(ErlNifEnv *env, int argc,
                                        const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;

    midiio_dev_res *res = new_device(0);
    if (res == NULL)
        return enif_make_tuple2(env, am_error, am_alloc_failed);

    mm_result r = mm_context_init(&res->ctx, "midiio-out:virtual");
    if (r != MM_SUCCESS) {
        enif_release_resource(res);
        return enif_make_tuple2(env, am_error, result_to_atom(r));
    }

    r = mm_out_open_virtual(&res->ctx, &res->dev);
    if (r != MM_SUCCESS) {
        mm_context_uninit(&res->ctx);
        enif_release_resource(res);
        return enif_make_tuple2(env, am_error, result_to_atom(r));
    }

    return device_ok(env, res);
}

/* open_input(Index, Owner) -> {ok, Dev} | {error, Atom}. Per-device context;
 * registers recv_cb (userdata = res) and enif_keep_resource so the backend thread
 * holds res across the callback (released after mm_in_stop). Partial-failure as
 * for open_output. */
static ERL_NIF_TERM open_input(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;

    unsigned int idx;
    if (!enif_get_uint(env, argv[0], &idx))
        return enif_make_badarg(env);
    ErlNifPid owner;
    if (!enif_get_local_pid(env, argv[1], &owner))
        return enif_make_badarg(env);

    midiio_dev_res *res = new_device(1);
    if (res == NULL)
        return enif_make_tuple2(env, am_error, am_alloc_failed);
    res->owner = owner;

    char name[64];
    snprintf(name, sizeof name, "midiio-in:%u", idx);

    mm_result r = mm_context_init(&res->ctx, name);
    if (r != MM_SUCCESS) {
        enif_release_resource(res);
        return enif_make_tuple2(env, am_error, result_to_atom(r));
    }

    r = mm_in_open(&res->ctx, &res->dev, idx, recv_cb, res);
    if (r != MM_SUCCESS) {
        mm_context_uninit(&res->ctx);
        enif_release_resource(res);
        return enif_make_tuple2(env, am_error, result_to_atom(r));
    }

    /* The backend thread now holds res as userdata: keep it across the callback's
     * lifetime. Released exactly once after mm_in_stop (stop_input/close/dtor/down). */
    enif_keep_resource(res);
    res->kept = 1;

    /* S2: monitor the owner so a started-and-abandoned input (owner drops the
     * handle without stop/close) is reclaimed via down_device, not leaked. A
     * non-zero return means no monitor was armed — >0 is "owner already dead", so
     * reclaim now and report not_open (the device cannot serve a dead owner). */
    if (enif_monitor_process(env, res, &res->owner, &res->monitor) != 0) {
        do_dev_cleanup(res); /* stops/closes + releases the keep */
        return enif_make_tuple2(env, am_error, am_not_open);
    }
    res->monitored = 1;

    return device_ok(env, res);
}

/* start_input(Dev) -> ok | {error, atom()}. Connects the source so callbacks
 * flow (mm_in_start). */
static ERL_NIF_TERM start_input(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    midiio_dev_res *res = NULL;
    if (!enif_get_resource(env, argv[0], g_dev_res_type, (void **)&res))
        return enif_make_badarg(env);

    enif_mutex_lock(res->lock);
    mm_result r = (res->live && res->is_input) ? mm_in_start(&res->dev) : MM_NOT_OPEN;
    enif_mutex_unlock(res->lock);

    return (r == MM_SUCCESS) ? am_ok
                             : enif_make_tuple2(env, am_error, result_to_atom(r));
}

/* stop_input(Dev) -> ok | {error, atom()}. mm_in_stop (no more callbacks), THEN
 * release the recv-thread keep — guarded so a double stop is a clean no-op and
 * the keep is released exactly once. */
static ERL_NIF_TERM stop_input(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    midiio_dev_res *res = NULL;
    if (!enif_get_resource(env, argv[0], g_dev_res_type, (void **)&res))
        return enif_make_badarg(env);

    int release_keep = 0;
    enif_mutex_lock(res->lock);
    if (res->live && res->is_input)
        mm_in_stop(&res->dev);
    if (res->kept) {
        res->kept = 0;
        release_keep = 1;
    }
    enif_mutex_unlock(res->lock);

    if (release_keep)
        enif_release_resource(res); /* after stop: no callback can fire now */
    return am_ok;
}

/* set_owner(Dev, Pid) -> ok | {error, owner_not_alive}. Re-points an input's
 * owner-death monitor ATOMICALLY (R1/R2 hardening, arc3/slice2): arm the new
 * monitor into a LOCAL ErlNifMonitor first, and only commit (drop the old, store
 * the new, write owner) if it succeeds. On failure the old owner + monitor are
 * left fully intact and we return {error, owner_not_alive} — so handing off to an
 * already-dead pid can no longer disarm a good monitor or silently leak (R2), and
 * a racing old-owner death after a successful re-point hits the new monitor, not a
 * spurious cleanup (R1 narrows to the irreducible ERTS demonitor window). All
 * under the lock so the recv thread never reads a half-updated owner. Outputs
 * (is_input false) never monitor — they just write owner. */
static ERL_NIF_TERM set_owner(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    midiio_dev_res *res = NULL;
    if (!enif_get_resource(env, argv[0], g_dev_res_type, (void **)&res))
        return enif_make_badarg(env);
    ErlNifPid pid;
    if (!enif_get_local_pid(env, argv[1], &pid))
        return enif_make_badarg(env);

    enif_mutex_lock(res->lock);
    if (res->is_input) {
        ErlNifMonitor new_mon;
        /* >0 = target not alive, <0 = no down callback (can't happen — we set one).
         * Calling this under res->lock is safe: a dead target returns synchronously
         * with no down; a live target's down is async and would just block on the
         * lock until we release (no join on this path → no deadlock). */
        if (enif_monitor_process(env, res, &pid, &new_mon) != 0) {
            enif_mutex_unlock(res->lock); /* old owner + monitor untouched */
            return enif_make_tuple2(env, am_error, am_owner_not_alive);
        }
        if (res->monitored)
            enif_demonitor_process(env, res, &res->monitor);
        res->monitor   = new_mon;
        res->monitored = 1;
    }
    res->owner = pid;
    enif_mutex_unlock(res->lock);
    return am_ok;
}

/* close(Dev) -> ok | {error, not_open}
 * The unified device close (output now; input reuses it in arc 3). Bad handle
 * (not a midiio_device resource) crashes with badarg — let it crash. */
static ERL_NIF_TERM close_device(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;

    midiio_dev_res *res = NULL;
    if (!enif_get_resource(env, argv[0], g_dev_res_type, (void **)&res))
        return enif_make_badarg(env);

    if (do_dev_cleanup(res))
        return am_ok;
    return enif_make_tuple2(env, am_error, am_not_open);
}

/* send(Dev, Bytes) -> ok | {error, not_open} | {error, {unsupported_status, B}}
 *                   | {error, invalid_arg}            (slice 2, DESIGN §1/§6)
 *
 * This wrapper does arg/handle checking, the R1 length validation, and the
 * liveness gate; the byte→mm_result translation lives entirely behind the seam
 * (midiio_dev_send_raw, midiio_send.h). It is registered ERL_NIF_DIRTY_JOB_IO_BOUND
 * (D3): ALSA's send ends in snd_seq_drain_output, which can block under
 * backpressure, and a blocking syscall can't be yielded — dirty I/O is the
 * correct scheduler. The per-device process serializes calls into one device, so
 * there is no lock on this path (DESIGN §2/§4).
 *
 * Error vs. crash asymmetry (§6): failures we can name are tagged; malformed
 * input — which means the encoder above us (midilib) is broken — is let-crash via
 * badarg, decided here BEFORE the seam so the crash is clean Erlang-side. We do
 * NOT wrap the adapter in a catch-all that would swallow those bugs. */
static ERL_NIF_TERM send_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;

    midiio_dev_res *res = NULL;
    if (!enif_get_resource(env, argv[0], g_dev_res_type, (void **)&res))
        return enif_make_badarg(env);          /* foreign handle → let it crash */

    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[1], &bin))
        return enif_make_badarg(env);          /* not a binary → let it crash */

    /* Malformed framing → let it crash (§6). Decided before the seam. */
    if (bin.size == 0)
        return enif_make_badarg(env);          /* empty: no status byte */

    uint8_t b = bin.data[0];
    if (b < 0x80)
        return enif_make_badarg(env);          /* leading data byte: not status-complete */

    if (b == 0xF0) {
        /* SysEx is variable-length; require at least 0xF0 0xF7. The upper bound
         * (> MM_SYSEX_BUF_SIZE) is minimidio's to report as invalid_arg. */
        if (bin.size < 2)
            return enif_make_badarg(env);
    } else {
        int exp = midiio_expected_len(b);
        if (exp != 0 && bin.size != (size_t)exp)
            return enif_make_badarg(env);      /* known status, wrong length */
        /* exp == 0 here ⇒ an unframable status (0xF4/F5/F7/F9/FD); we can't know
         * its length, so we don't validate it — the seam returns the
         * unsupported-status sentinel, a tagged/diagnosable error (not a crash). */
    }

    /* F1 close: the live-check AND the handle use run under the per-device lock,
     * so a concurrent close/1 (a second process sharing this device()) cannot
     * tear the port/context down between the check and the mm_out_send* deref —
     * the use-after-free the unlocked slice-2 version had. The lock is per-device
     * and uncontended under the single-owner contract (DESIGN §4 D3); it only ever
     * serializes the pathological cross-process send-vs-close race. */
    enif_mutex_lock(res->lock);
    if (!res->live) {
        enif_mutex_unlock(res->lock);
        return enif_make_tuple2(env, am_error, am_not_open);
    }
    mm_result r = midiio_dev_send_raw(&res->dev, bin.data, bin.size);
    enif_mutex_unlock(res->lock);

    if (r == (mm_result)MIDIIO_UNSUPPORTED_STATUS)
        return enif_make_tuple2(env, am_error,
                   enif_make_tuple2(env, am_unsupported_status,
                                    enif_make_uint(env, b)));

    switch (r) {
        case MM_SUCCESS:     return am_ok;
        case MM_NOT_OPEN:    return enif_make_tuple2(env, am_error, am_not_open);
        case MM_INVALID_ARG: return enif_make_tuple2(env, am_error, am_invalid_arg);
        default:             return enif_make_tuple2(env, am_error, result_to_atom(r));
    }
}

static ErlNifFunc nif_funcs[] = {
    {"context_open",       0, context_open},
    {"context_close",      1, context_close},
    {"result_atom",        1, result_atom},
    {"uninit_count",       0, uninit_count},
    {"seam_roundtrip",     1, seam_roundtrip},
    {"list_inputs",        1, list_inputs},
    {"list_outputs",       1, list_outputs},
    {"caps",               1, caps},
    {"open_output",        1, open_output},
    {"open_output_virtual", 0, open_output_virtual},
    {"open_input",         2, open_input},
    {"start_input",        1, start_input},
    {"stop_input",         1, stop_input},
    {"set_owner",          2, set_owner},
    {"close",              1, close_device},
    /* The only dirty NIF so far: send blocks in the backend drain (D3). */
    {"send",               2, send_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

/* Args: module, funcs, load, reload(deprecated→NULL), upgrade, unload.
 * upgrade is non-NULL so a module reload (cover / hot upgrade) succeeds; unload
 * is NULL because the shared statics must outlive an old purged instance. */
ERL_NIF_INIT(midiio, nif_funcs, load, NULL, upgrade, NULL)
