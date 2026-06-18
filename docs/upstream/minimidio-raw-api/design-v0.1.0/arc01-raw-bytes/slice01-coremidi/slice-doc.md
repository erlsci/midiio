# Slice 01 — CoreMIDI raw I/O (+ shared scaffolding)

*Plan-of-record for the slice. Companion files: `ledger.md` (acceptance criteria),
`cc-prompt.md` (the assignment CC executes).*

*Design of record:* `../../../minimidio-raw-api-and-findings.md` (§4 API, §5 semantics).
*Line numbers below are against minimidio `bb705e8`; re-confirm before editing.*

## Goal

Land a complete, runnable raw-bytes vertical on CoreMIDI, plus the shared
surface every backend will use, with the other three backends stubbed so the
header still compiles everywhere. Strictly additive — no existing behavior changes.

## In scope

1. **Shared scaffolding** (platform-independent parts of `minimidio.h`)
2. **CoreMIDI implementation** of the three raw functions + raw inbound framing
3. **Cross-platform stubs** for WinMM / ALSA / WebMIDI (return `MM_NO_BACKEND`)
4. **A self-checking loopback test harness** (`tests/raw_loopback.c`)

## Out of scope (deferred, with re-entry)

- ALSA / WinMM / WebMIDI real implementations → slices 02–03.
- Fixing U1/U3/U2 in the existing struct functions → separate PRs (their tickets).
- Shipping a user-facing `examples/raw_monitor.c` → optional, post-arc polish.
- Running the harness on non-macOS → those backends' slices.

---

## Design decisions (settled here — CC implements, does not re-decide)

### D1 — Shared surface, mirroring the `_ump` precedent exactly

The UMP door (`mm_ump_callback`, `mm_in_open_ump`, `mm_out_send_ump`,
`MM_CAP_UMP`, the `is_ump` device flag) is the template. Raw mirrors it:

- **Typedef** after `mm_ump_callback` (currently ends line 356):
  ```c
  typedef void (*mm_raw_callback)(mm_device* dev,
                                  const uint8_t* data, size_t len,
                                  double timestamp, void* userdata);
  ```
- **Capability bit** in the cap enum (after `MM_CAP_VIRTUAL_OUT = 1u << 4`, line 339):
  ```c
  MM_CAP_RAW          = 1u << 5,  /* Raw byte-transparent I/O */
  ```
- **Device fields** in `struct mm_device` (after `ump_callback` / `is_ump`):
  ```c
  mm_raw_callback raw_callback;   /* next to mm_ump_callback ump_callback; */
  int             is_raw;         /* next to int is_ump; — 1 = opened *_raw */
  ```
- **Public declarations** in the API block (near lines 564–589), grouped with the
  inbound and outbound families:
  ```c
  mm_result mm_in_open_raw(mm_context* ctx, mm_device* dev, uint32_t idx,
                           mm_raw_callback cb, void* userdata);
  mm_result mm_in_open_virtual_raw(mm_context* ctx, mm_device* dev,
                                   mm_raw_callback cb, void* userdata);
  mm_result mm_out_send_raw(mm_device* dev, const uint8_t* data, size_t len);
  ```

### D2 — CoreMIDI open functions

Mirror the existing struct opens, setting the raw fields instead of `callback`:

- `mm_in_open_raw` ≈ `mm_in_open` (line 848) but
  `dev->raw_callback = cb; dev->is_raw = 1;` (leave `dev->callback = NULL`).
  Same `MIDIInputPortCreate(..., mm__cm_read_proc, dev, ...)` registration.
- `mm_in_open_virtual_raw` ≈ `mm_in_open_virtual` (line 975) but with the raw
  fields. Same `MIDIDestinationCreate(..., mm__cm_read_proc, dev, ...)`.

The read proc is shared between struct and raw inputs; it dispatches on
`dev->is_raw` (see D4).

### D3 — `mm_out_send_raw` (CoreMIDI): byte-exact, no cap

Send `data[0..len)` verbatim. **Must not** reuse the existing `mm_out_send_sysex`
stack-`MIDIPacketList` idiom (that's the U1 cap). Instead size the packet list to
the payload:

- Build a `MIDIPacketList` in a heap (or sufficiently large stack/`alloca`)
  buffer of `sizeof(MIDIPacketList) + len` bytes, `MIDIPacketListInit`,
  `MIDIPacketListAdd(pl, bufsize, p, 0, len, data)`.
- Virtual source (`dev->is_virtual`): `MIDIReceived(dev->cm.virt_ep, pl)`.
- Real device: `MIDISend(dev->cm.port, dev->cm.endpoint, pl)`.
- Free the heap buffer; return `MM_SUCCESS`/`MM_ERROR` per the OSStatus.
- Guards mirror the existing sends: `if (!dev||!dev->is_open||dev->is_input)
  return MM_NOT_OPEN; if (!data||!len) return MM_INVALID_ARG;`

(Architect note: a single 300-byte SysEx through one `MIDIPacketListAdd` on a
heap-sized list is the explicit U1-avoidance proof. If CoreMIDI itself imposes a
per-`MIDIPacketListAdd` ceiling in practice, the fallback is the
`MIDISendSysex` arbitrary-length path for `F0…`-led buffers — but try the sized
packet list first; that is what the harness checks.)

### D4 — CoreMIDI raw inbound framing (the one piece of real logic)

At the **top** of `mm__cm_read_proc` (before the existing struct loop at ~line 720):

```c
if (dev->is_raw) { mm__cm_raw_dispatch(pl, dev); return; }
```

The existing struct decode loop is left **completely untouched**.

`mm__cm_raw_dispatch` is a new static function implementing this framing. It
honors semantic rules 1, 2, 5. Pseudocode (CC implements faithfully):

```
for each packet pkt in pl:
    ts = mm__cm_ts(pkt->timeStamp)
    for j in 0 .. pkt->length-1:
        b = pkt->data[j]

        if b >= 0xF8:                      # system real-time — rule 2
            raw_callback(dev, &pkt->data[j], 1, ts, ud)   # own callback,
            continue                       # even mid-SysEx; excluded from it

        if dev->cm.sysex_pos > 0:          # currently inside a SysEx
            append b to cm.sysex_buf (bounds-checked; on overflow reset pos=0, drop)
            if b == 0xF7:
                raw_callback(dev, cm.sysex_buf, cm.sysex_pos, ts, ud)
                cm.sysex_pos = 0
            continue

        if b == 0xF0:                      # SysEx start
            cm.sysex_pos = 0
            append b                        # begins accumulation; may span packets
            continue

        if b >= 0x80:                      # status byte: frame status + N data bytes
            n = data_byte_count(b)          # see table below
            emit a buffer [b, next n bytes within this packet] via raw_callback
            advance j past those n bytes
            continue

        # else: a data byte with no preceding status (running status / stray).
        # Mirror the struct path's existing choice (line 797): skip it.
        continue
```

`data_byte_count(status)`:

| Status range | Bytes after status |
|--------------|--------------------|
| `0x80–0xBF`, `0xE0–0xEF` (note off/on, poly, CC, pitch-bend) | 2 |
| `0xC0–0xDF` (program change, channel pressure) | 1 |
| `0xF1` (MTC qf), `0xF3` (song select) | 1 |
| `0xF2` (song position) | 2 |
| `0xF6` (tune request) | 0 |
| `0xF4`, `0xF5` (undefined) | 0 |

**SysEx accumulation state** requires a new field on the CoreMIDI device struct
(`mm__dev_coremidi`, line ~445): `size_t sysex_pos;`. It pairs with the existing
`sysex_buf[MM_SYSEX_BUF_SIZE]` and persists across read-proc calls (so a SysEx
split across CoreMIDI packets/callbacks reassembles whole — rule 2). This mirrors
the ALSA backend's existing `sysex_buf`/`sysex_pos` accumulator (lines 1492–1510).

### D5 — Advertise the capability

CoreMIDI `mm_context_caps` (line 819) gains `| MM_CAP_RAW`.

### D6 — Cross-platform stubs

In the WinMM, ALSA, and WebMIDI sections, define all three raw functions as
stubs returning `MM_NO_BACKEND` (exactly as `mm_in_open_ump` is stubbed on
CoreMIDI at line 873). These keep the header compiling on every platform this
slice does not yet implement. Their `mm_context_caps` do **not** advertise
`MM_CAP_RAW`.

### D7 — Test harness

`tests/raw_loopback.c` — a single self-checking program, modelled on
`examples/virtual.c`, using `assert()` and plain libc (no new deps). It records
what arrives via the inbound raw callback into a synchronized capture buffer,
sends crafted byte buffers, pumps the run loop briefly, and asserts. Exit 0 =
all pass. See `ledger.md` for the exact cases (T1–T6).

**Loopback topology (important — a wrong topology silently receives nothing).**
Two *separate* virtual ports (a source and a destination) are NOT auto-connected
and will not loop back. Use a connected pair:

- **Primary path (T1–T4):** create a virtual **source** with `mm_out_open_virtual`
  (existing API), enumerate inputs (`mm_in_count` / `mm_in_name`) to find it by
  name, and open it as a **raw input** via `mm_in_open_raw(idx)` — `mm_in_start`
  connects the input to that source. Now `mm_out_send_raw` on the virtual source
  goes through the **virtual `MIDIReceived` branch** — the exact branch where the
  U1 cap lives — so T3's >256-byte SysEx proves the no-cap path specifically.
- **Coverage case:** add one case using `mm_in_open_virtual_raw` (creates a
  virtual destination) + `mm_out_open(idx)` on it, so that function is exercised
  too (its send goes through the `MIDISend` branch).

**Runtime assumption to verify (the one empirically-unproven bit):** this relies
on *intra-process* virtual loopback working on CoreMIDI. minimidio ships no
self-loopback example, so if a process does not receive its own virtual source,
the fallback is a two-process or real-port wiring — CC reports that via the
ledger as an amendment rather than forcing it.

(CoreMIDI delivery is asynchronous on a background thread; the harness must run
the CFRunLoop / sleep briefly and synchronize access to the capture buffer.
`examples/virtual.c` shows the run-loop idiom.)

---

## Risks / watch-items for CDC

- **Async timing in the harness** — a too-short wait could make a real failure
  look like "nothing received." The harness must distinguish "wrong bytes" from
  "no bytes yet" and wait adequately.
- **Large-SysEx packetization** — whether the 300-byte SysEx arrives in one
  CoreMIDI packet or several exercises the cross-packet accumulator (D4). Either
  way the received SysEx must be one whole `F0…F7`.
- **Additive proof** — an existing struct-mode example must still compile and run
  unchanged (ledger L12). This is the guard against an accidental edit to the
  shared read proc.
