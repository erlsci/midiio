/*
 * midiio_send.h — the raw send seam + interim adapter (arc2/slice2).
 *
 * THE SEAM (D1, slice-doc §"The raw seam"). midiio_dev_send_raw is the single C
 * entry point that all of send/2 funnels through: bytes in, mm_result out. It is
 * the one symbol that gets re-pointed at native mm_out_send_raw when upstream
 * ships it — at which point the interim adapter below is deleted and NOTHING
 * above the seam changes (the NIF wrapper and the ASan harness both call only
 * this function).
 *
 * Refinement vs. the slice-doc signature (disclosed): the slice-doc typed the
 * seam `midiio_dev_send_raw(midiio_dev_res *res, ...)`, but (a) it only ever
 * touches res->dev, (b) ledger row 18 requires the standalone ASan harness — which
 * has no midiio_dev_res type — to drive the seam directly, and (c) mm_device* is
 * exactly the shape native mm_out_send_raw will have (mm_out_send itself takes
 * mm_device*). So the seam takes `mm_device *dev`; the NIF wrapper passes
 * &res->dev. This makes the seam strictly more re-pointable, not less.
 *
 * Include AFTER minimidio.h (it uses mm_device / mm_message / mm_out_send et al.
 * and the mm_message_type enum); this header does not include minimidio.h itself,
 * so the includer controls MINIMIDIO_IMPLEMENTATION.
 */
#ifndef MIDIIO_SEND_H
#define MIDIIO_SEND_H

/* Adapter-only out-of-band sentinel for an unframable leading status byte
 * (0xF4/0xF5/0xF7/0xF9/0xFD — reserved/undefined; we can't know the length, so we
 * can't frame it). The NIF wrapper turns this into {error, {unsupported_status, B}}.
 * It is NOT an mm_result: the 8 real codes are 0..-7, so a positive value can
 * never collide. This disappears with the adapter — a native raw path has no
 * notion of "unframable" and would emit any bytes verbatim. */
#define MIDIIO_UNSUPPORTED_STATUS 1

/* Exact byte length implied by a known status byte, or 0 when there is no fixed
 * length to validate against — i.e. SysEx (0xF0, variable) and the reserved /
 * unframable bytes. Derived from mm_out_send's switch (minimidio.h:907) read
 * backwards. The NIF wrapper uses this to enforce the R1 length contract (a known
 * status with the wrong length is malformed → let it crash) BEFORE calling the
 * seam, so the crash lands cleanly in Erlang-land. */
static inline int midiio_expected_len(uint8_t b)
{
    if (b >= 0x80 && b <= 0xBF) return 3;   /* note off/on, poly pressure, CC   */
    if (b >= 0xC0 && b <= 0xDF) return 2;   /* program change, channel pressure */
    if (b >= 0xE0 && b <= 0xEF) return 3;   /* pitch bend                       */
    switch (b) {
        case 0xF1: return 2;                /* MTC quarter frame                */
        case 0xF2: return 3;                /* song position (14-bit)           */
        case 0xF3: return 2;                /* song select                      */
        case 0xF6: return 1;                /* tune request                     */
        case 0xF8: case 0xFA: case 0xFB:    /* clock / start / continue         */
        case 0xFC: case 0xFE: case 0xFF:    /* stop / active-sense / reset      */
            return 1;
        default:   return 0;                /* 0xF0 SysEx (variable) + reserved */
    }
}

/* The seam + interim adapter. Parses the leading status byte to learn the
 * message shape, then drives minimidio's struct API. The ONLY place that knows
 * minimidio is message-structured. Caller (NIF wrapper / ASan harness) guarantees
 * len >= 1; the wrapper also pre-validates fixed-length statuses via
 * midiio_expected_len. midiio_bytes_to_msg additionally **self-defends**: every
 * data-byte read is guarded on `len`, so it never reads past `bytes` even when a
 * caller skips the length pre-check (a too-short status is unframable → 0).
 *
 * TODO(upstream): when native mm_out_send_raw(dev, bytes, len) ships, replace this
 * entire body with `return mm_out_send_raw(dev, bytes, len);` and delete the
 * adapter — nothing above the seam changes (ledger row 19). */
/* The parse half of the seam: wire bytes → mm_message. Returns 1 if framed, 0 if
 * the leading status byte is unframable (0xF4/F5/F7/F9/FD). For SysEx it points
 * m->sysex at `bytes` (no copy — the caller owns the buffer's lifetime). This is
 * the exact inverse of midiio_recv.h's midiio_msg_to_bytes, and factoring it out
 * lets the bytes⇄message round-trip be tested purely (seam_roundtrip test NIF +
 * PropEr) without driving real I/O. */
static inline int midiio_bytes_to_msg(const uint8_t *bytes, size_t len, mm_message *m)
{
    uint8_t b = bytes[0];
    memset(m, 0, sizeof *m);

    /* SysEx: the whole binary (0xF0 … 0xF7), pointed-to not copied. */
    if (b == 0xF0) {
        m->type = MM_SYSEX;
        m->sysex = bytes;
        m->sysex_size = len;
        return 1;
    }

    /* Channel voice (0x80–0xEF): type = (status>>4)&0xF, channel = status&0xF.
     * mm_make_message fills exactly this; the unused data byte stays 0 for the
     * 2-byte statuses (program change / channel pressure). */
    if (b >= 0x80 && b <= 0xEF) {
        *m = mm_make_message(b, len >= 2 ? bytes[1] : 0, len >= 3 ? bytes[2] : 0);
        return 1;
    }

    /* System common + real-time: unique enum types (NOT a nibble shift). The
     * F1/F2/F3 data-byte reads are guarded on `len` (mirroring the channel-voice
     * guard above), so the seam never reads past `bytes` regardless of caller —
     * a too-short fixed-length status is unframable (return 0). send_nif already
     * length-validates, so these guards are inert on the validated send path. */
    switch (b) {
        case 0xF1: if (len < 2) return 0;
                   m->type = MM_MTC_QUARTER_FRAME; m->data[0] = bytes[1]; return 1;
        case 0xF2: if (len < 3) return 0;
                   m->type = MM_SONG_POSITION;
                   m->song_position = (uint16_t)(bytes[1] | (bytes[2] << 7)); return 1;
        case 0xF3: if (len < 2) return 0;
                   m->type = MM_SONG_SELECT;       m->data[0] = bytes[1]; return 1;
        case 0xF6: m->type = MM_TUNE_REQUEST; return 1;
        case 0xF8: m->type = MM_CLOCK;        return 1;
        case 0xFA: m->type = MM_START;        return 1;
        case 0xFB: m->type = MM_CONTINUE;     return 1;
        case 0xFC: m->type = MM_STOP;         return 1;
        case 0xFE: m->type = MM_ACTIVE_SENSE; return 1;
        case 0xFF: m->type = MM_RESET;        return 1;
        default:   return 0;                  /* 0xF4/F5/F7/F9/FD — unframable */
    }
}

static inline mm_result midiio_dev_send_raw(mm_device *dev,
                                            const uint8_t *bytes, size_t len)
{
    mm_message m;
    if (!midiio_bytes_to_msg(bytes, len, &m))
        return (mm_result)MIDIIO_UNSUPPORTED_STATUS;
    if (m.type == MM_SYSEX)
        return mm_out_send_sysex(dev, m.sysex, m.sysex_size);
    return mm_out_send(dev, &m);
}

#endif /* MIDIIO_SEND_H */
