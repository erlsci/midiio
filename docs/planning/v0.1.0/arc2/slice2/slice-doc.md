# arc2/slice2 — `send(Dev, <<bytes>>)` over the raw seam + dirty-I/O

> Plan-of-record. Parent: `arc2/arc-plan.md` (slice 2). Lands the **outbound
> data path** and closes arc 2's capability: a `midi`-shaped caller can
> `open_output` → `send` a complete MIDI message byte-exact → `close`, with no
> handle leak on owner crash. Design refs: `DESIGN.md` §1 (surface, `send/2`),
> §4 (D3 — dirty-I/O), §6 (error mapping), §0/§3 of the contract in
> `PROJECT-DEFINITION.md` (raw bytes, one complete message per call).

## Goal

`midiio:send(Dev, Bytes)` takes an opaque output device handle and **one
complete, status-complete MIDI message** as a binary, and emits its bytes on the
device's OS port — byte-exact, no normalization. The call runs on a **dirty I/O
scheduler** so a blocking backend drain never ties up a normal scheduler. Slice 1
gave us the device + lifecycle; this slice gives it a mouth.

## Surface

```erlang
-spec send(device(), binary()) -> ok | {error, not_open}
                                      | {error, {unsupported_status, byte()}}
                                      | {error, invalid_arg}.
%% Bytes is ONE complete message, status byte first (R1, R4):
%%   <<16#90, 60, 100>>            note-on  ch 0
%%   <<16#F0, ...payload..., 16#F7>>  a complete SysEx
%% send/2 routes normal-vs-SysEx internally; the split is NOT in the API (R4).
```

`send/2` is the only new export. No `send_sysex`, no `send_batch` (deferred,
NEW-1 still open with `midi`).

## The raw seam (the load-bearing abstraction)

Per D1, midiio commits to a **stable internal raw seam** — one C entry point that
all of `send/2` funnels through:

```c
/* The seam. Bytes in, mm_result out. The ONLY thing slice 2 ships above the
   adapter; the one symbol that gets re-pointed at native mm_out_send_raw later. */
static mm_result midiio_dev_send_raw(midiio_dev_res *res,
                                     const uint8_t *bytes, size_t len);
```

**Upstream gate (resolved for this slice): native `mm_out_send_raw` has NOT
shipped.** The vendored `c_src/minimidio.h` exports `mm_out_send` (struct-based,
`:903`) and `mm_out_send_sysex` (`:937`) but **no** `mm_*_raw` "no-opinion" path
(confirmed by grep against the pinned header). So this slice implements the seam
with the **interim adapter** below. When upstream ships `mm_out_send_raw`, the
seam body becomes a one-line call and the adapter is deleted — **nothing above
the seam changes** (that is the whole point of having the seam).

## The interim adapter (the throwaway code, isolated)

The adapter's job: parse the leading **status byte** to learn the message's
shape, then drive minimidio's struct API. minimidio is message-structured
internally, so the adapter does `bytes → mm_message → mm_out_send` — and
`mm_out_send` immediately re-serializes `mm_message → bytes` on the wire
(`:903`/`:1151`). That double conversion is exactly the waste the native raw path
will remove; it is acceptable and **isolated behind the seam** until then.

Routing on the leading byte `B = bytes[0]`:

| Leading byte | Route | Adapter action |
|---|---|---|
| `0x80–0xEF` (channel status) | `mm_out_send` | build `mm_message`: `type=(B>>4)&0xF`, `channel=B&0xF`, fill `data[]`; **expected length is fixed per status** (3 bytes for `0x8n/0x9n/0xAn/0xBn/0xEn`; 2 bytes for `0xCn/0xDn`) |
| `0xF0` (SysEx start) | `mm_out_send_sysex(dev, bytes, len)` | pass the **whole binary** (leading `0xF0` … trailing `0xF7`) straight through; minimidio memcpys it to its per-device buffer and emits it raw (`:937`) |
| `0xF1` MTC quarter-frame | `mm_out_send` | `type=MM_MTC_QUARTER_FRAME`, `data[0]=bytes[1]` (len 2) |
| `0xF2` song position | `mm_out_send` | `type=MM_SONG_POSITION`, `song_position = bytes[1] | (bytes[2]<<7)` (len 3) |
| `0xF3` song select | `mm_out_send` | `type=MM_SONG_SELECT`, `data[0]=bytes[1]` (len 2) |
| `0xF6` tune request | `mm_out_send` | `type=MM_TUNE_REQUEST` (len 1) |
| `0xF8/0xFA/0xFB/0xFC/0xFE/0xFF` system real-time | `mm_out_send` | map to `MM_CLOCK/START/CONTINUE/STOP/ACTIVE_SENSE/RESET` (len 1) |
| `0xF4 0xF5 0xF7 0xF9 0xFD` (undefined/reserved) | — | `{error, {unsupported_status, B}}` — length is undefined, we can't frame it |
| high bit clear (`B < 0x80`, a data byte first) | — | **malformed** (running status / not status-complete; violates R1) → **let it crash** |

**Why not `mm_make_message` for everything?** `mm_make_message` (`:408`) only
sets `type=(status>>4)&0xF` — correct for **channel** messages, *wrong* for
system messages (whose `mm_message_type` values are unique enum constants, not a
nibble shift; see `:264`). The adapter uses the helper for the channel cases and
fills the struct by hand for the `0xF_` cases. The table above is derived
directly from `mm_out_send`'s own `switch (msg->type)` (`:907`) read backwards.

**Length discipline (R1 contract).** Each known status implies an exact length.
The adapter validates `len` against that expectation:

- correct length → build + send;
- a **known status with the wrong length** (e.g. `<<0x90, 60>>`) → **malformed
  input, let it crash** (§6 — the encoder upstream, midilib, must never produce
  this; defensive swallowing would hide its bugs);
- an **unrecognized status** (`0xF4` etc., or no way to know the length) →
  `{error, {unsupported_status, B}}` (a predictable, *diagnosable* return, not a
  crash).

That asymmetry is deliberate and is straight out of §6: tag the failures we can
name; crash the ones that mean the layer above is broken.

## Threading — dirty I/O (D3)

Mark the send NIF `ERL_NIF_DIRTY_JOB_IO_BOUND` in `nif_funcs` (statically dirty
on all backends, per §4). ALSA's send ends in `snd_seq_drain_output`, which can
block under backpressure; a blocking syscall can't be yielded, so dirty-I/O is
the correct scheduler. The per-device process already serializes calls into one
device, so there is **no concurrency concern** and **no lock on the send path**
(the per-device-context model from slice 1 earns this). The known tradeoff —
static-dirty also taxes the fast CoreMIDI/WinMM sends with dispatch latency — is
accepted for v0.1.0 and tracked in §4 (⚑ D3); the conditional fast path is a
measured, post-ship decision, **not** this slice.

## Error mapping (§6)

| Condition | Return |
|---|---|
| device closed, or it's an input | `{error, not_open}` (`mm_out_send`/`mm_out_send_sysex` already guard `!is_open || is_input` → `MM_NOT_OPEN`) |
| unrecognized / unframable leading status byte | `{error, {unsupported_status, B}}` |
| SysEx larger than `MM_SYSEX_BUF_SIZE` (4096, `:217`) | `{error, invalid_arg}` (`mm_out_send_sysex` → `MM_INVALID_ARG`) |
| known status, wrong data-byte count; leading data byte; empty binary | **crash** (`badarg`/`function_clause`) — malformed, not our error to swallow |
| backend `MM_ERROR` (the OS send call failed) | `{error, error}` (mechanical `result_to_atom`) |

No normalization, ever (R6): the bytes go out exactly as given, including any
backend-quirky note-on-vel-0 the caller chose to send.

## Key decisions / risks for the implementer

- **Reuse, don't reinvent:** get the `midiio_dev_res` via the slice-1 resource
  accessor; gate on the same `live` flag; map results with the existing
  `result_to_atom`. The send NIF reads `res->dev`; it does **not** touch the
  cleanup path.
- **Binary access:** use `enif_inspect_binary` (or `iolist`) — the bytes are
  read-only and consumed within the call; no copy needs to outlive it (SysEx is
  memcpy'd into minimidio's own buffer inside `mm_out_send_sysex`).
- **Seam is one function:** keep `midiio_dev_send_raw` the *only* place that
  knows the adapter exists. The NIF wrapper does arg/handle checking + dirty
  dispatch; the seam does bytes→mm_result; the adapter is private to the seam's
  translation unit. When `mm_out_send_raw` lands, only the seam body changes.
- **Don't build atoms at runtime** for `{unsupported_status, B}` — `B` is an
  integer in the tuple, not an atom; the tag atom is pre-made in `init_statics`.

## Testing notes

Arc 2 has **no inbound path**, so byte-exact *receipt* can't be asserted yet —
that's the arc-3 virtual-loopback conformance test (`DESIGN.md` §9). This slice
verifies send by **shape, error, and real hardware**:

- **Deterministic (headless-safe):** `send(ClosedDev, <<0x90,60,100>>)` →
  `{error, not_open}`; `send(Dev, <<0xF4, 1, 2>>)` → `{error,
  {unsupported_status, 16#F4}}`; `send(Dev, <<0xF0, (binary:copy(<<0>>,
  5000))/binary, 0xF7>>)` → `{error, invalid_arg}` (over 4096). Use a **virtual
  output** (`mm_out_open_virtual`, slice-1 test scaffolding) so a live device
  exists without hardware.
- **Crash cases:** `?assertError(_, send(Dev, <<0x90, 60>>))` (short channel
  message); `?assertError(_, send(Dev, <<60, 100>>))` (data byte first);
  `?assertError(_, send(Dev, <<>>))`.
- **Real hardware (macOS):** open destination `0`, `send(<<0x90,60,100>>)` then
  `<<0x80,60,0>>` → `ok`; audibly/observably emits (manual confirm; note the
  device in Audio MIDI Setup).
- **ASan:** extend `c_src/test/midiio_asan.c` — open a virtual output, loop
  `midiio_dev_send_raw` over a representative byte set (each channel type, each
  system-common/real-time byte, a small SysEx), then close/uninit. Zero
  leaks/use-after-free. The SysEx path (memcpy into the 4096 buffer) is the one
  most worth exercising under ASan.
- **PropEr (transport-level, optional this slice):** a generator over
  `{status, data...}` → assert the adapter routes + lengths without crashing for
  *well-formed* messages, and returns `{unsupported_status,_}` for the reserved
  bytes. The full **bytes⇄message round-trip** property (no dropped status, 14-bit
  song-position intact) belongs in arc 3 where receipt can close the loop; a
  forward-only adapter property is the most we can assert here. Disclose this
  boundary rather than faking a round-trip without inbound.

## Acceptance

Every ledger row closed or disclosed-deferred; `rebar3 as test check` green
(coverage gate stays dormant — `midiio` excluded); ASan clean over the send path;
the seam is a single re-pointable function with the adapter isolated behind it.
**Arc 2's capability is then complete** — open → send → close, byte-exact, no
leak — and the arc-2 close-out (specified-vs-delivered diff) can run. CDC
verifies independently.
