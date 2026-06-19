# Slice 02 — ALSA raw I/O

*Plan-of-record. Companions: `ledger.md`, `cc-prompt.md`. Prereq: slice 01 merged
(shared scaffolding — typedef, `MM_CAP_RAW`, device fields, decls — already exists).*

*Design of record:* `../../../minimidio-raw-api-and-findings.md` (§4 API, §5 semantics, §6 ALSA reality).
*Line numbers against `feat/raw-bytes-api` @ `f71c3c0` (post-slice-01); re-confirm before editing.*

## Goal

Swap the ALSA raw stubs (left by slice 01) for a real implementation, and extend
the loopback harness to compile and pass on Linux. Strictly additive — the
existing struct decode/encode paths are untouched.

## The ALSA-specific premise

ALSA's sequencer delivers **parsed `snd_seq_event_t` events**, not wire bytes, and
minimidio hand-decodes each event type into `mm_message` in `mm__alsa_recv_thread`
(line 1500) — that per-type switch is where the U2 vel-0 fold lives (line 1570).

So on ALSA "raw" means: minimidio still owns the event↔byte conversion, but uses
ALSA's canonical bridge instead of the hand-decode, and hands you **bytes**:

- **inbound:** `snd_midi_event_decode()` turns a seq event back into wire bytes;
- **outbound:** `snd_midi_event_encode()` turns a byte buffer into seq event(s).

A happy consequence: the raw path gets **U2 passthrough for free**. The fold is
only in the struct switch; `snd_midi_event_decode` of a note-on-velocity-0 event
yields `90 nn 00`, unfolded. (T2 verifies this — and it's more meaningful here
than on CoreMIDI, since ALSA is *the* backend that folds in struct mode.)

## In scope

1. ALSA implementations of `mm_in_open_raw`, `mm_in_open_virtual_raw`, `mm_out_send_raw`
2. A raw inbound branch in `mm__alsa_recv_thread`
3. A `snd_midi_event_t` parser/encoder on the ALSA device + lifecycle
4. `MM_CAP_RAW` in the ALSA caps
5. Extend `tests/raw_loopback.c` to build + pass on Linux/ALSA

## Out of scope (deferred, with re-entry)

- WinMM / WebMIDI → slice 03.
- Fixing U2 in the existing struct switch → separate PR (its ticket).
- SysEx larger than `MM_SYSEX_BUF_SIZE` (4096) → matches the existing struct limit;
  documented, not a regression.

---

## Design decisions (settled here)

### D1 — A `snd_midi_event_t` on the ALSA device

Add to `mm__dev_alsa` (struct at line ~487): `snd_midi_event_t* midi_ev;`. It is
the byte↔event coder. Lifecycle:

- **Input (raw):** allocate in `mm_in_open_raw` / `mm_in_open_virtual_raw` via
  `snd_midi_event_new(MM_SYSEX_BUF_SIZE, &dev->al.midi_ev)`; on the decoder,
  call `snd_midi_event_no_status(dev->al.midi_ev, 1)` so every event decodes with
  a full status byte (no running-status compression — byte-exact framing).
- **Output (raw):** `mm_out_send_raw` lazily allocates `dev->al.midi_ev` on first
  call if NULL (output devices open via the existing `mm_out_open` /
  `mm_out_open_virtual`, which we are not changing).
- **Free** in `mm_in_close` and `mm_out_close`: `if (dev->al.midi_ev)
  { snd_midi_event_free(dev->al.midi_ev); dev->al.midi_ev = NULL; }`.

(These functions are in `<alsa/seq_midi_event.h>`, pulled in by `asoundlib.h`;
they link with the `-lasound` already used. No new dependency.)

### D2 — Raw inbound branch in `mm__alsa_recv_thread`

Inside the event-drain loop (line ~1529), add an `if (dev->is_raw) { … continue; }`
branch, placed **before** the existing `switch (ev->type)` and parallel to the
existing `if (dev->is_ump)` branch (line ~1531). It must never touch `dev->callback`
(NULL in raw mode). Logic:

```
if (dev->is_raw):
    if ev->type == SND_SEQ_EVENT_SYSEX:
        # reuse the existing accumulator pattern (mirrors struct path ~1656–1674)
        append ev->data.ext bytes to da->sysex_buf / da->sysex_pos (bounds-checked)
        if last byte == 0xF7:
            raw_callback(dev, da->sysex_buf, da->sysex_pos, ts, ud)
            da->sysex_pos = 0
    else:
        uint8_t buf[16]
        long n = snd_midi_event_decode(da->midi_ev, buf, sizeof buf, ev)
        if n > 0:
            raw_callback(dev, buf, (size_t)n, ts, ud)
        # n <= 0  → event with no wire-MIDI representation; skip
    continue
```

`ts` is the existing `CLOCK_MONOTONIC` timestamp the thread already computes.
Real-time events (clock/start/stop/…) arrive on ALSA as their *own* seq events,
so they decode to their own single-byte callbacks naturally — the U3 interleaving
problem does not arise on this backend.

### D3 — `mm_out_send_raw` (ALSA)

Byte-exact, no cap. Encode the buffer into one-or-more events and send each via
the existing `mm__alsa_send_ev` helper (line 1825):

```
guards: if (!dev||!dev->is_open||dev->is_input) return MM_NOT_OPEN;
        if (!data||!len) return MM_INVALID_ARG;
if (!dev->al.midi_ev) snd_midi_event_new(MM_SYSEX_BUF_SIZE, &dev->al.midi_ev);
snd_midi_event_reset_encode(dev->al.midi_ev);
size_t off = 0;
while (off < len):
    snd_seq_event_t ev; memset(&ev,0,sizeof ev);
    long used = snd_midi_event_encode(dev->al.midi_ev, data+off, len-off, &ev);
    if used <= 0: break            # parser needs more / error
    off += used;
    if ev.type != SND_SEQ_EVENT_NONE:
        mm__alsa_send_ev(dev, &ev)   # sets source/subs/direct, outputs, drains
return MM_SUCCESS;
```

`snd_midi_event_encode` handles channel/system messages and assembles `F0…F7`
into a `SND_SEQ_EVENT_SYSEX` event — so a >256-byte SysEx is sent as one variable
event, no cap (the ALSA backend never had the CoreMIDI U1 stack-packet problem).

### D4 — Open functions

- `mm_in_open_raw` ≈ `mm_in_open` (line 1684): same enumeration/port-create/pipe
  setup, but `dev->raw_callback = cb; dev->is_raw = 1;` (leave `callback` NULL) and
  allocate `da->midi_ev` (D1). `mm_in_start` (unchanged) connects + spawns the thread.
- `mm_in_open_virtual_raw` ≈ `mm_in_open_virtual` (line 1938): same
  `snd_seq_create_simple_port(WRITE|SUBS_WRITE)` + wake-pipe, with raw fields +
  `da->midi_ev`.

### D5 — Caps

ALSA `mm_context_caps` (line 1415): add `MM_CAP_RAW` to the `caps` bitmask.

### D6 — Harness extension

> **CORRECTION (post-implementation, 2026-06-18):** the single-context topology
> described below is **wrong for ALSA** and was replaced during slice 02 by a
> **two-context** harness (separate sender + receiver clients in one process).
> Reason: `mm__alsa_enum` skips the caller's own client (`if (cid ==
> al->client_id) continue;`), so a context cannot discover its *own* virtual
> source — the "find it by name in our own input list" step below can't work.
> The two-context wiring works identically on CoreMIDI and ALSA. The original
> text is kept below for history; see `cdc-verification.md` (deviation D1).

Extend `tests/raw_loopback.c` so it compiles and passes on Linux. The API-level
loopback topology is identical to slice 01's corrected primary path:

- `mm_out_open_virtual` → a virtual **source** (ALSA: `CAP_READ|SUBS_READ` port).
- Enumerate inputs (`mm_in_count`/`mm_in_name`), find it by name, open it with
  `mm_in_open_raw(idx)` → `mm_in_start` issues `snd_seq_connect_from` (intra-client
  connect; both ports live in our one `mm_context` client).
- `mm_out_send_raw` on the source → `snd_seq_event_output` with subs → our raw
  input thread receives. Same test cases T1–T6.

Platform differences are confined to `#ifdef`: the run-loop *pump* (CoreMIDI
`CFRunLoop` vs. ALSA: the recv thread runs on its own, so just `usleep` long
enough to let delivery happen), and the build line
(`-lasound -lpthread` instead of `-framework CoreMIDI`).

Intra-process ALSA loopback is **not** a worry here the way it is on CoreMIDI:
sequencer routing between two ports of one client is ordinary, and your midiio NIF
already exercises this VM. The smoke test (ledger A-0) confirms it in seconds.

---

## Test bed — the existing midiio-NIF Multipass VM

Reuse the Ubuntu VM already set up for the midiio NIF; it has `gcc`,
`libasound2-dev`, and a kernel with `snd-seq` (the NIF runs minimidio's ALSA
backend there, so the path is proven). No new provisioning. The ledger's A-0 row
is a 10-second confirmation, not a discovery.

If a fresh VM is ever needed: `sudo apt-get install -y build-essential
libasound2-dev alsa-utils`, ensure `snd-seq` is present
(`sudo modprobe snd-seq; ls /dev/snd/seq`), done.

## Risks / watch-items for CDC

- **`snd_midi_event` running-status** — without `snd_midi_event_no_status(…,1)` on
  the decoder, multi-event streams could drop repeated status bytes; T1/T2 byte
  comparisons catch this.
- **SysEx chunking** — large SysEx may arrive as multiple `SND_SEQ_EVENT_SYSEX`
  events; the accumulator (D2) must reassemble whole before delivery (T3).
- **vel-0 passthrough (T2)** — the headline correctness check for this backend;
  must be `90 3C 00`, never folded to `80 …`.
- **Additive** — the existing struct switch and `mm_out_send*`/`mm_out_send_sysex`
  must be untouched (ledger A-12 / A-13, `git diff`).
