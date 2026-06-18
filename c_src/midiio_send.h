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
 * len >= 1 and, for the fixed-length statuses, the correct length (the wrapper
 * validates via midiio_expected_len first); the adapter trusts that contract and
 * indexes bytes[1]/bytes[2] directly for the statuses that carry them.
 *
 * TODO(upstream): when native mm_out_send_raw(dev, bytes, len) ships, replace this
 * entire body with `return mm_out_send_raw(dev, bytes, len);` and delete the
 * adapter — nothing above the seam changes (ledger row 19). */
static inline mm_result midiio_dev_send_raw(mm_device *dev,
                                            const uint8_t *bytes, size_t len)
{
    uint8_t b = bytes[0];

    /* SysEx: hand the whole binary (0xF0 … 0xF7) through unchanged; minimidio
     * memcpys it into the per-device buffer and bounds-checks the size. */
    if (b == 0xF0)
        return mm_out_send_sysex(dev, bytes, len);

    mm_message m;
    memset(&m, 0, sizeof m);

    /* Channel voice (0x80–0xEF): type = (status>>4)&0xF, channel = status&0xF.
     * mm_make_message fills exactly this; the unused data byte stays 0 for the
     * 2-byte statuses (program change / channel pressure), which mm_out_send
     * ignores. */
    if (b >= 0x80 && b <= 0xEF) {
        m = mm_make_message(b, len >= 2 ? bytes[1] : 0, len >= 3 ? bytes[2] : 0);
        return mm_out_send(dev, &m);
    }

    /* System common + real-time: unique enum types (NOT a nibble shift), filled
     * by hand. mm_make_message would set the wrong type here (minimidio.h:264). */
    switch (b) {
        case 0xF1: m.type = MM_MTC_QUARTER_FRAME; m.data[0] = bytes[1]; break;
        case 0xF2: m.type = MM_SONG_POSITION;
                   m.song_position = (uint16_t)(bytes[1] | (bytes[2] << 7)); break;
        case 0xF3: m.type = MM_SONG_SELECT;       m.data[0] = bytes[1]; break;
        case 0xF6: m.type = MM_TUNE_REQUEST; break;
        case 0xF8: m.type = MM_CLOCK;        break;
        case 0xFA: m.type = MM_START;        break;
        case 0xFB: m.type = MM_CONTINUE;     break;
        case 0xFC: m.type = MM_STOP;         break;
        case 0xFE: m.type = MM_ACTIVE_SENSE; break;
        case 0xFF: m.type = MM_RESET;        break;
        default:   /* 0xF4 0xF5 0xF7 0xF9 0xFD — unframable */
            return (mm_result)MIDIIO_UNSUPPORTED_STATUS;
    }
    return mm_out_send(dev, &m);
}

#endif /* MIDIIO_SEND_H */
