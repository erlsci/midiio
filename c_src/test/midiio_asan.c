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

    printf("ASAN-OK\n");
    return 0;
}
