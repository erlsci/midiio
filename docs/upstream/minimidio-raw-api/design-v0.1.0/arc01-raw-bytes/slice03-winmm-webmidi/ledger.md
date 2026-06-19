# Slice 03 — WinMM + WebMIDI raw I/O — Ledger

*Protocol:* `collaboration-framework/templates/LEDGER_DISCIPLINE.md`.
CC implements against these rows; CDC re-runs every `Verify`.

*Source greps run anywhere (CWD = minimidio clone root). Compile-checks need the
respective toolchain. Runtime rows are **deferred-with-rationale** by agreement —
neither backend has an in-loop runtime path (WinMM has no virtual ports; WebMIDI
needs a browser). Iteration budget: 5.*

## Ledger

| ID | Criterion | Verify | Significance | Origin | Status | Evidence | Notes |
|----|-----------|--------|--------------|--------|--------|----------|-------|
| WEB-1 | WebMIDI `mm_in_open_raw` + `mm_out_send_raw` are real (not `MM_NO_BACKEND`) | `awk '/#elif defined\(MM_BACKEND_WEBMIDI\)/,0' minimidio.h \| grep -A3 -E 'mm_(in_open_raw\|out_send_raw)\(' \| grep -c MM_NO_BACKEND` → only the virtual-raw stub remains | serious | D1 | done | 66bb4e1; grep -c = **0** (both fns real; only `mm_in_open_virtual_raw` remains a stub) | |
| WEB-2 | WebMIDI raw inbound branch in `mm__web_dispatch_raw` | `sed -n '/mm__web_dispatch_raw/,/^}/p' minimidio.h \| grep 'is_raw'` | serious | D1 | done | 66bb4e1; `if (dev && dev->is_raw) {` at top of `mm__web_dispatch_raw`, before the `!dev->callback` guard and parse loop | one message per Web MIDI event → no framing |
| WEB-3 | WebMIDI `mm_context_caps` advertises `MM_CAP_RAW` | `awk '/#elif defined\(MM_BACKEND_WEBMIDI\)/,0' minimidio.h \| sed -n '/mm_context_caps/,/}/p' \| grep 'MM_CAP_RAW'` | polish | D1 | done | 66bb4e1; WebMIDI caps = `return MM_CAP_MIDI1 \| MM_CAP_RAW;` | |
| WEB-4 | WebMIDI `mm_in_open_virtual_raw` stays `MM_NO_BACKEND` (no virtual ports) | grep the WebMIDI `mm_in_open_virtual_raw` body = `return MM_NO_BACKEND;` | polish | D1 | done | 66bb4e1; body `{ (void)…; return MM_NO_BACKEND; }` unchanged | intentional no-op, mirrors `mm_in_open_virtual` |
| WIN-1 | WinMM `mm_in_open_raw` + `mm_out_send_raw` are real | `awk '/#elif defined\(MM_BACKEND_WINMM\)/,/#elif defined\(MM_BACKEND_ALSA\)/' minimidio.h \| grep -A3 -E 'mm_(in_open_raw\|out_send_raw)\(' \| grep -c MM_NO_BACKEND` → only virtual-raw stub remains | serious | D2 | done | 66bb4e1; grep -c = **0** (awk range re-triggers to cover the WinMM impl; both fns real) | |
| WIN-2 | WinMM raw inbound branch in `mm__wm_in_proc` | `sed -n '/CALLBACK mm__wm_in_proc/,/^}/p' minimidio.h \| grep 'is_raw'` | serious | D2 | done | 66bb4e1; `if (dev && dev->is_raw) {` at top of `mm__wm_in_proc`, before the `!dev->callback` guard | unpacks MIM_DATA, forwards MIM_LONGDATA |
| WIN-3 | WinMM `mm_context_caps` advertises `MM_CAP_RAW` | `awk '/#elif defined\(MM_BACKEND_WINMM\)/,/#elif defined\(MM_BACKEND_ALSA\)/' minimidio.h \| sed -n '/mm_context_caps/,/}/p' \| grep 'MM_CAP_RAW'` | polish | D2 | done | 66bb4e1; WinMM caps = `return MM_CAP_MIDI1 \| MM_CAP_RAW;` | |
| WIN-4 | WinMM `mm_in_open_virtual_raw` stays `MM_NO_BACKEND` | grep the WinMM `mm_in_open_virtual_raw` body = `return MM_NO_BACKEND;` | polish | D2 | done | 66bb4e1; body `{ (void)…; return MM_NO_BACKEND; }` unchanged | intentional no-op |
| CC-1 | WinMM path cross-compiles clean (no new warnings) | `zig cc tests/raw_compile_check.c -target x86_64-windows-gnu -lwinmm -Wall -Wextra -o /tmp/wm.exe; echo exit=$?` (=0) | serious | slice-doc verification | done | 66bb4e1; **exit=0**. Fresh build: 3 warnings = 1 `unknown-pragmas` (the MSVC `#pragma comment(lib,"winmm.lib")`) + 2 unused UMP helpers; base bb705e8 emits the identical 3 → **0 new** from raw code. (zig content-cache silences warm rebuilds.) | references all 3 raw fns + MM_CAP_RAW |
| CC-2 | WebMIDI path builds to wasm clean | `emcc tests/raw_compile_check.c -sASYNCIFY -o /tmp/web.js; echo exit=$?` (=0) | serious | slice-doc verification | done | 66bb4e1; **exit=0**; emits `/tmp/web.js` + `/tmp/web.wasm` | emcc 5.0.7 (host) |
| CC-3 | The two implemented backends still compile (regression) | macOS: `cc tests/raw_compile_check.c -framework CoreMIDI -framework CoreFoundation -o /tmp/cm` (=0); VM: `cc … -lasound -lpthread` (=0) | serious | additive | done | 66bb4e1; CoreMIDI (host) exit=0; ALSA (`midiio-test` VM) exit=0 | both implemented backends still build |
| ADD-1 | Additive: struct paths byte-unchanged | `git diff` shows the `mm__wm_in_proc` struct branches, `mm__web_dispatch_raw` parse loop, and all `mm_out_send*` bodies unchanged; raw branches are pure insertions | serious | additive constraint | done | 66bb4e1; `git diff 107107f` deletions = the 2 caps lines (WIN-3/WEB-3) + the 4 replaced stub bodies (WIN-1/WEB-1) + 1 stale comment only; struct branches, parse loop, and `mm_out_send*` bodies byte-unchanged; raw branches pure insertions | CDC reads the diff |
| DEF-1 | **WinMM raw round-trip** (note-on, vel-0, SysEx, real-time) | On Windows + loopMIDI: two ports, `mm_in_open_raw` ↔ `mm_out_send_raw`, assert byte-exact | serious | §5 | deferred | No runtime done. **Reason:** WinMM has no virtual ports; an in-loop round-trip needs a Windows host + loopMIDI, absent from this dev loop (macOS + Linux VM). **Re-entry:** a Windows host with loopMIDI, two ports wired, asserting byte-exact T1–T4. Code path compile-checked (CC-1) and audited. | **deferred** by ledger design |
| DEF-2 | **WebMIDI raw round-trip** | In a browser (extend `examples/web_*` + `serve-wasm.sh`): raw send/receive, assert byte-exact | serious | §5 | deferred | No runtime done. **Reason:** Web MIDI needs a browser with a Web MIDI implementation; no headless assert harness in this loop. **Re-entry:** a browser Web MIDI test (extend `examples/web_*` + `serve-wasm.sh`), asserting byte-exact raw send/receive. Code path wasm-build-checked (CC-2) and audited. | **deferred** by ledger design |

## What Worked

- **WebMIDI was almost free** — the backend already forwards each
  `onmidimessage` `Uint8Array` to a C dispatch as raw bytes, so the inbound raw
  path was a single top-of-function branch (one message per event → no framing),
  and the outbound reused the same JS sender `mm_out_send` already calls.
- **One `data_bytes` table, three backends.** The WinMM framer reuses the exact
  status→data-byte table from CoreMIDI's `mm__cm_raw_data_bytes`, so inbound
  unpacking and outbound framing stay consistent across the arc.
- **Heap-sized SysEx on WinMM output** lifts the fixed-buffer cap the same way
  CoreMIDI's U1 fix did — byte-exact and uncapped, while keeping the standard
  prepare/long/unprepare dance.
- **Honest deferral beats a faked pass.** Neither backend has an in-loop runtime
  path; compile-checks (`zig cc`, `emcc`) + the additive audit are the real bar,
  and the two round-trips are tracked as `deferred` with concrete re-entry
  conditions rather than dropped.

## Closure

Total rows: 13. Done: 11. Deferred: 2 (DEF-1, DEF-2). No-op: 0.
WEB-4/WIN-4 are `done` (verified intentional `MM_NO_BACKEND` stubs — neither
backend has virtual ports), not no-ops. DEF-1/DEF-2 are `deferred` with reason +
re-entry (Windows+loopMIDI; browser Web MIDI). Closed at commit `66bb4e1`
(minimidio `feat/raw-bytes-api`) on 2026-06-18. CDC verification: **PASS**
(2026-06-18) — see `cdc-verification.md`. Source rows + additive diff re-run by
CDC (7 deletions = 2 caps + 4 stubs + 1 comment, exactly as claimed); compile-check
rows accepted on CC evidence (no zig/emcc/macOS in CDC env); **WinMM output framing
independently executed in isolation** (`cdc-wm-framing-test.c`, 8/8 pass);
heap-buffer deviation accepted as an improvement; DEF-1/DEF-2 deferrals legitimate.
This closes the arc: all four backends are now either
fully raw-capable (CoreMIDI, ALSA, WinMM, WebMIDI inbound/outbound) or honestly
stubbed (`mm_in_open_virtual_raw` on WinMM/WebMIDI).
