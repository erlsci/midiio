/*
 * midiio_recv.h — the raw receive seam (arc3/slice1).
 *
 * THE INBOUND SEAM, mirror of midiio_send.h. midiio_msg_to_bytes is the single C
 * entry point the recv callback funnels a parsed mm_message through: message in,
 * exact wire bytes out. It is the one symbol re-pointed at native mm_in_open_raw
 * when upstream ships it — at which point this interim adapter is deleted and the
 * recv callback above the seam is unchanged.
 *
 * SysEx is NOT handled here: msg->sysex points into a callback-lifetime buffer
 * (Finding A.3 / NIF-LEARNINGS L04), so the caller memcpys those bytes into the
 * Erlang binary *during* the callback. This function reconstructs every
 * fixed-shape message from the parsed fields and returns its length (1..3);
 * MM_SYSEX (and any unknown type) returns 0, signalling "use msg->sysex".
 *
 * Derived by reading mm_out_send's switch (minimidio.h:903) backwards — the exact
 * inverse of midiio_send.h's adapter. Include AFTER minimidio.h.
 */
#ifndef MIDIIO_RECV_H
#define MIDIIO_RECV_H

static inline size_t midiio_msg_to_bytes(const mm_message *msg, uint8_t buf[3])
{
    switch (msg->type) {
        /* Channel voice with two data bytes: status = (type<<4)|channel. */
        case MM_NOTE_OFF:
        case MM_NOTE_ON:
        case MM_POLY_PRESSURE:
        case MM_CONTROL_CHANGE:
        case MM_PITCH_BEND:
            buf[0] = (uint8_t)(((uint8_t)msg->type << 4) | (msg->channel & 0x0F));
            buf[1] = msg->data[0];
            buf[2] = msg->data[1];
            return 3;

        /* Channel voice with one data byte. */
        case MM_PROGRAM_CHANGE:
        case MM_CHANNEL_PRESSURE:
            buf[0] = (uint8_t)(((uint8_t)msg->type << 4) | (msg->channel & 0x0F));
            buf[1] = msg->data[0];
            return 2;

        /* System common — unique status bytes (not a nibble shift). */
        case MM_MTC_QUARTER_FRAME:
            buf[0] = 0xF1; buf[1] = msg->data[0]; return 2;
        case MM_SONG_POSITION:
            buf[0] = 0xF2;
            buf[1] = (uint8_t)(msg->song_position & 0x7F);
            buf[2] = (uint8_t)((msg->song_position >> 7) & 0x7F);
            return 3;
        case MM_SONG_SELECT:
            buf[0] = 0xF3; buf[1] = msg->data[0]; return 2;
        case MM_TUNE_REQUEST:
            buf[0] = 0xF6; return 1;

        /* System real-time — single status byte. */
        case MM_CLOCK:        buf[0] = 0xF8; return 1;
        case MM_START:        buf[0] = 0xFA; return 1;
        case MM_CONTINUE:     buf[0] = 0xFB; return 1;
        case MM_STOP:         buf[0] = 0xFC; return 1;
        case MM_ACTIVE_SENSE: buf[0] = 0xFE; return 1;
        case MM_RESET:        buf[0] = 0xFF; return 1;

        /* SysEx (and anything unrecognised): the caller uses msg->sysex. */
        case MM_SYSEX:
        default:
            return 0;
    }
}

#endif /* MIDIIO_RECV_H */
