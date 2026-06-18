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

/* The raw send seam (arc2/slice2). The harness drives the same seam the NIF does
 * — this is exactly what makes a single mm_device*-typed seam worthwhile. */
#include "../midiio_send.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

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

    printf("ASAN-OK\n");
    return 0;
}
