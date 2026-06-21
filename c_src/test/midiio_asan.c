/*
 * midiio_asan.c — standalone AddressSanitizer harness for the C layer the NIF
 * drives (ledger row 16). The NIF .so itself cannot run under ASan without an
 * ASan-instrumented BEAM, so this exercises the minimidio context lifecycle and
 * the result-code mapping directly: init -> uninit -> double-uninit guard, in a
 * loop, plus mm_result_string for all 8 codes.
 *
 * The NIF's own destructor wrapper (do_uninit + the live flag) is verified
 * under the BEAM by the eunit GC tests (ledger rows 7, 8).
 *
 * Build & run (Darwin):
 *   clang -fsanitize=address -g -std=c11 -Wall -Wextra -Wno-unused-function \
 *       -framework CoreMIDI -framework CoreFoundation \
 *       c_src/test/midiio_asan.c -o /tmp/midiio_asan && /tmp/midiio_asan
 *
 * ASan reports use-after-free / double-free / overflow here. LeakSanitizer is
 * unsupported on macOS, so leak detection is the Linux/valgrind half of row 16
 * (disclosed-deferred along with the other Linux rows).
 */

#define MINIMIDIO_IMPLEMENTATION
#include "../minimidio.h"

/* The raw send + receive seams (arc2/slice2, arc3/slice1). The harness drives the
 * same seams the NIF does — what makes the single mm_device*-typed seams worth it. */
#include "../midiio_send.h"
#include "../midiio_recv.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>

/* A no-op recv callback for the virtual-input lifecycle loop (nothing sends to
 * it, so it never fires — this exercises the pure resource path). */
static void tw_noop_cb(mm_device *dev, const mm_message *msg, void *ud)
{
    (void)dev; (void)msg; (void)ud;
}

/* F1 tripwire (arc3/slice1, ledger row 5): mirror the NIF's per-device-lock
 * discipline with a pthread_mutex (the standalone harness has no erl_nif, so no
 * enif_mutex). A sender thread loops the live-check + send under the lock while
 * the main thread closes under the same lock — the exact send_nif vs
 * do_dev_cleanup race. ASan/TSan-clean ⇒ the locking discipline has no UAF/race;
 * removing the lock here makes both sanitizers flag immediately. */
static struct {
    pthread_mutex_t lock;
    mm_device       dev;
    int             live;
} g_tw;

static void *tw_sender(void *arg)
{
    atomic_int *stop = (atomic_int *)arg;
    static const uint8_t noteon[3] = {0x90, 60, 100};
    while (!atomic_load(stop)) {
        pthread_mutex_lock(&g_tw.lock);
        if (g_tw.live)
            (void)midiio_dev_send_raw(&g_tw.dev, noteon, 3);
        pthread_mutex_unlock(&g_tw.lock);
    }
    return NULL;
}

int main(void)
{
    /* Mapping: every mm_result resolves to its expected string (all 8 codes). */
    static const struct {
        mm_result   code;
        const char *name;
    } cases[] = {
        {MM_SUCCESS,      "MM_SUCCESS"},
        {MM_ERROR,        "MM_ERROR"},
        {MM_INVALID_ARG,  "MM_INVALID_ARG"},
        {MM_NO_BACKEND,   "MM_NO_BACKEND"},
        {MM_OUT_OF_RANGE, "MM_OUT_OF_RANGE"},
        {MM_ALREADY_OPEN, "MM_ALREADY_OPEN"},
        {MM_NOT_OPEN,     "MM_NOT_OPEN"},
        {MM_ALLOC_FAILED, "MM_ALLOC_FAILED"},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        assert(strcmp(mm_result_string(cases[i].code), cases[i].name) == 0);

    /* The lifecycle loops below all need a usable MIDI backend. On ALSA that
     * means a kernel sequencer (/dev/snd/seq); GitHub's hosted Linux runners use
     * an Azure kernel with no snd-seq module, so mm_context_init returns
     * MM_ERROR there. Probe once: if the backend is unavailable, the mapping
     * checks above already ran — defer the lifecycle/leak rows (the same
     * disclosed-deferred posture as the eunit runtime tests and row 16's Linux
     * leak half) and exit clean rather than aborting on the assert. macOS and any
     * Linux host with a real sequencer run the full harness. */
    {
        mm_context probe;
        if (mm_context_init(&probe, NULL) != MM_SUCCESS) {
            printf("ASAN-OK (lifecycle deferred: no MIDI sequencer on this host)\n");
            return 0;
        }
        mm_context_uninit(&probe);
    }

    /* Lifecycle: open/close the context many times, mirroring the resource's
     * `live`-flag guard. The second uninit must be rejected (no double free). */
    for (int i = 0; i < 200; i++) {
        mm_context ctx;
        int        live = 0;

        assert(mm_context_init(&ctx, NULL) == MM_SUCCESS);
        live = 1;

        /* The guarded cleanup path: uninit once, flip the flag. */
        if (live) {
            assert(mm_context_uninit(&ctx) == MM_SUCCESS);
            live = 0;
        }

        /* A second uninit (what an unguarded destructor would do) is a no-op:
         * minimidio rejects it because `initialized` is already cleared. */
        assert(mm_context_uninit(&ctx) == MM_INVALID_ARG);
    }

    /* Device lifecycle (arc 2 slice 1): the per-device context + virtual output
     * port, opened and torn down in the destructor's order — port first, then
     * context — many times. A virtual source needs no destination, so this runs
     * headlessly. Catches leaks/use-after-free in the open_output/close cycle. */
    for (int i = 0; i < 200; i++) {
        mm_context ctx;
        mm_device  dev;

        assert(mm_context_init(&ctx, "midiio-out:asan") == MM_SUCCESS);
        assert(mm_out_open_virtual(&ctx, &dev) == MM_SUCCESS);

        assert(mm_out_close(&dev) == MM_SUCCESS);     /* port first */
        assert(mm_context_uninit(&ctx) == MM_SUCCESS); /* then the context */

        /* Double close/uninit are guarded no-ops (the resource `live` flag does
         * this in the NIF; minimidio rejects the repeat). */
        assert(mm_out_close(&dev) == MM_NOT_OPEN);
        assert(mm_context_uninit(&ctx) == MM_INVALID_ARG);
    }

    /* Partial-failure cleanup (open_output row 7): context init succeeds, the
     * port open fails (out-of-range index), and the context must be uninited so
     * nothing leaks — exactly what open_output does before returning {error,_}. */
    for (int i = 0; i < 200; i++) {
        mm_context ctx;
        mm_device  dev;

        assert(mm_context_init(&ctx, "midiio-out:asan-fail") == MM_SUCCESS);
        assert(mm_out_open(&ctx, &dev, 0x7fffffffu) == MM_OUT_OF_RANGE);
        assert(mm_context_uninit(&ctx) == MM_SUCCESS); /* clean up the context */
    }

    /* Send path (arc 2 slice 2): drive the raw seam over a representative byte
     * set — every channel type, every system common/real-time byte, and a small
     * SysEx (the memcpy-into-the-4096-buffer path) — on a virtual output, looped
     * for leak/use-after-free detection over the adapter's struct-build + memcpy
     * work. 0xF4 exercises the unframable branch (returns the sentinel, no send).
     * This is the same midiio_dev_send_raw the NIF calls (midiio_send.h). */
    {
        static const struct { uint8_t b[8]; size_t len; mm_result want; } msgs[] = {
            {{0x90, 60, 100}, 3, MM_SUCCESS},   /* note on          */
            {{0x80, 60,   0}, 3, MM_SUCCESS},   /* note off         */
            {{0xA0, 60,  64}, 3, MM_SUCCESS},   /* poly pressure    */
            {{0xB0,  7, 127}, 3, MM_SUCCESS},   /* control change   */
            {{0xC0,  5},      2, MM_SUCCESS},   /* program change   */
            {{0xD0, 64},      2, MM_SUCCESS},   /* channel pressure */
            {{0xE0,  0,  64}, 3, MM_SUCCESS},   /* pitch bend       */
            {{0xF1, 0x10},    2, MM_SUCCESS},   /* MTC quarter frame*/
            {{0xF2, 0x10, 0x20}, 3, MM_SUCCESS},/* song position    */
            {{0xF3,  5},      2, MM_SUCCESS},   /* song select      */
            {{0xF6},          1, MM_SUCCESS},   /* tune request     */
            {{0xF8},          1, MM_SUCCESS},   /* clock            */
            {{0xFA},          1, MM_SUCCESS},   /* start            */
            {{0xFB},          1, MM_SUCCESS},   /* continue         */
            {{0xFC},          1, MM_SUCCESS},   /* stop             */
            {{0xFE},          1, MM_SUCCESS},   /* active sense     */
            {{0xFF},          1, MM_SUCCESS},   /* reset            */
            {{0xF4,  1,   2}, 3, (mm_result)MIDIIO_UNSUPPORTED_STATUS}, /* unframable */
        };
        static const uint8_t sysex[] = {0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7};

        mm_context ctx;
        mm_device  dev;
        assert(mm_context_init(&ctx, "midiio-out:asan-send") == MM_SUCCESS);
        assert(mm_out_open_virtual(&ctx, &dev) == MM_SUCCESS);

        for (int i = 0; i < 200; i++) {
            for (size_t j = 0; j < sizeof(msgs) / sizeof(msgs[0]); j++)
                assert(midiio_dev_send_raw(&dev, msgs[j].b, msgs[j].len) == msgs[j].want);
            assert(midiio_dev_send_raw(&dev, sysex, sizeof sysex) == MM_SUCCESS);
        }

        assert(mm_out_close(&dev) == MM_SUCCESS);
        assert(mm_context_uninit(&ctx) == MM_SUCCESS);
    }

    /* Inbound seam (arc3 row 13): the inverse of the outbound adapter — a parsed
     * mm_message reconstructs to its exact wire bytes. Spot-check representative
     * types; SysEx is the caller's memcpy, so it returns 0 here. */
    {
        uint8_t buf[3];
        mm_message m;

        memset(&m, 0, sizeof m);
        m.type = MM_NOTE_ON; m.channel = 0; m.data[0] = 60; m.data[1] = 100;
        assert(midiio_msg_to_bytes(&m, buf) == 3 &&
               buf[0] == 0x90 && buf[1] == 60 && buf[2] == 100);

        memset(&m, 0, sizeof m);
        m.type = MM_PROGRAM_CHANGE; m.channel = 3; m.data[0] = 5;
        assert(midiio_msg_to_bytes(&m, buf) == 2 &&
               buf[0] == 0xC3 && buf[1] == 5);

        memset(&m, 0, sizeof m);
        m.type = MM_SONG_POSITION; m.song_position = (uint16_t)(0x10 | (0x20 << 7));
        assert(midiio_msg_to_bytes(&m, buf) == 3 &&
               buf[0] == 0xF2 && buf[1] == 0x10 && buf[2] == 0x20);

        memset(&m, 0, sizeof m);
        m.type = MM_CLOCK;
        assert(midiio_msg_to_bytes(&m, buf) == 1 && buf[0] == 0xF8);

        memset(&m, 0, sizeof m);
        m.type = MM_SYSEX;          /* caller uses msg->sysex */
        assert(midiio_msg_to_bytes(&m, buf) == 0);
    }

    /* Truncated system-common (arc3/slice2 S2 remediation, ledger rows 1–3).
     * The seam must self-defend: F1/F2/F3 carry data bytes, and a caller that
     * skips the length pre-check (e.g. the seam_roundtrip test NIF) must not make
     * midiio_bytes_to_msg read past the input. Each status is placed at the END of
     * a TIGHT heap allocation so ASan's redzone catches any read of bytes[1]/[2].
     * Pre-fix this flags heap-buffer-overflow; post-fix the guards return 0
     * (unframable) and it is clean. */
    {
        const uint8_t trunc[] = {0xF1, 0xF2, 0xF3}; /* each needs >= 2/3 bytes */
        for (size_t i = 0; i < sizeof trunc / sizeof trunc[0]; i++) {
            uint8_t *one = (uint8_t *)malloc(1); /* exactly 1 byte: status only */
            one[0] = trunc[i];
            mm_message m;
            int framed = midiio_bytes_to_msg(one, 1, &m); /* must NOT read one[1]/[2] */
            assert(framed == 0);                          /* too short → unframable */
            free(one);
        }
    }

    /* Input device lifecycle (arc3 row 17): open a virtual input destination,
     * start/stop/close it, uninit the context — looped, port-before-context, the
     * keep/release mirrored by the NIF. No callback fires here (nothing sends to
     * it), so this is the pure resource path. */
    for (int i = 0; i < 200; i++) {
        mm_context ctx;
        mm_device  dev;
        assert(mm_context_init(&ctx, "midiio-in:asan") == MM_SUCCESS);
        assert(mm_in_open_virtual(&ctx, &dev, tw_noop_cb, NULL) == MM_SUCCESS);
        assert(mm_in_start(&dev) == MM_SUCCESS);
        assert(mm_in_stop(&dev) == MM_SUCCESS);
        assert(mm_in_close(&dev) == MM_SUCCESS);
        assert(mm_context_uninit(&ctx) == MM_SUCCESS);
    }

    /* F1 tripwire (arc3 row 5): the lock-guarded send-vs-close race, repeated. */
    pthread_mutex_init(&g_tw.lock, NULL);
    for (int i = 0; i < 50; i++) {
        mm_context ctx;
        assert(mm_context_init(&ctx, "midiio-out:asan-tw") == MM_SUCCESS);

        pthread_mutex_lock(&g_tw.lock);
        assert(mm_out_open_virtual(&ctx, &g_tw.dev) == MM_SUCCESS);
        g_tw.live = 1;
        pthread_mutex_unlock(&g_tw.lock);

        atomic_int stop = 0;
        pthread_t  sender;
        pthread_create(&sender, NULL, tw_sender, &stop);

        for (int k = 0; k < 200; k++) {        /* let the sender hammer it */
            pthread_mutex_lock(&g_tw.lock);
            pthread_mutex_unlock(&g_tw.lock);
        }

        pthread_mutex_lock(&g_tw.lock);         /* close mid-flight, under the lock */
        mm_out_close(&g_tw.dev);
        g_tw.live = 0;
        pthread_mutex_unlock(&g_tw.lock);

        atomic_store(&stop, 1);
        pthread_join(sender, NULL);
        assert(mm_context_uninit(&ctx) == MM_SUCCESS);
    }
    pthread_mutex_destroy(&g_tw.lock);

    printf("ASAN-OK\n");
    return 0;
}
