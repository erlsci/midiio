/* CDC isolation test: transcribes WinMM mm_out_send_raw framing + data_bytes
   verbatim from minimidio.h @ 66bb4e1, with midiOut* replaced by recorders.
   Verifies the byte-stream framing the deferred DEF-1 row cannot execute. */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* ---- verbatim from the diff ---- */
static int mm__wm_raw_data_bytes(uint8_t status) {
    if (status >= 0x80 && status <= 0xBF) return 2;
    if (status >= 0xC0 && status <= 0xDF) return 1;
    if (status >= 0xE0 && status <= 0xEF) return 2;
    switch (status) {
        case 0xF1: return 1;
        case 0xF2: return 2;
        case 0xF3: return 1;
        default:   return 0;
    }
}

/* ---- recorders standing in for midiOutShortMsg / midiOutLongMsg ---- */
typedef struct { int is_long; uint8_t bytes[4096]; size_t n; } Sent;
static Sent g_sent[64]; static int g_count;

static void rec_short(uint32_t pk, int nbytes) {
    Sent* s = &g_sent[g_count++]; s->is_long = 0; s->n = (size_t)nbytes;
    for (int i=0;i<nbytes;i++) s->bytes[i] = (uint8_t)((pk >> (8*i)) & 0xFF);
}
static void rec_long(const uint8_t* d, size_t len) {
    Sent* s = &g_sent[g_count++]; s->is_long = 1; s->n = len; memcpy(s->bytes,d,len);
}

/* ---- framing loop, transcribed verbatim (midiOut* -> recorders) ---- */
static void frame(const uint8_t* data, size_t len) {
    g_count = 0;
    size_t off = 0;
    while (off < len) {
        uint8_t s = data[off];
        if (s == 0xF0) {
            size_t end = off + 1;
            while (end < len && data[end] != 0xF7) end++;
            if (end < len) end++;
            size_t sxlen = end - off;
            rec_long(data + off, sxlen);
            off = end;
        } else if (s >= 0x80) {
            int nd = mm__wm_raw_data_bytes(s);
            uint32_t pk = s;
            if (nd >= 1 && off + 1 < len) pk |= (uint32_t)data[off+1] << 8;
            if (nd >= 2 && off + 2 < len) pk |= (uint32_t)data[off+2] << 16;
            rec_short(pk, 1 + nd);
            off += (size_t)(1 + nd);
        } else {
            off++;
        }
    }
}

static int eq(const Sent* s, int is_long, const uint8_t* b, size_t n) {
    return s->is_long==is_long && s->n==n && memcmp(s->bytes,b,n)==0;
}

int main(void) {
    int fails = 0;
    /* T1 note-on */
    { uint8_t in[]={0x90,0x3C,0x40}; frame(in,3);
      uint8_t e[]={0x90,0x3C,0x40};
      if(!(g_count==1 && eq(&g_sent[0],0,e,3))){printf("FAIL T1\n");fails++;} else printf("PASS T1 note-on\n"); }
    /* T2 vel-0 unfolded */
    { uint8_t in[]={0x90,0x3C,0x00}; frame(in,3);
      uint8_t e[]={0x90,0x3C,0x00};
      if(!(g_count==1 && eq(&g_sent[0],0,e,3) && g_sent[0].bytes[0]==0x90)){printf("FAIL T2\n");fails++;} else printf("PASS T2 vel-0 unfolded\n"); }
    /* T3 sysex whole */
    { uint8_t in[]={0xF0,0x7E,0x00,0x01,0xF7}; frame(in,5);
      if(!(g_count==1 && eq(&g_sent[0],1,in,5))){printf("FAIL T3\n");fails++;} else printf("PASS T3 sysex whole\n"); }
    /* T4 real-time 1 byte */
    { uint8_t in[]={0xF8}; frame(in,1);
      uint8_t e[]={0xF8};
      if(!(g_count==1 && eq(&g_sent[0],0,e,1))){printf("FAIL T4\n");fails++;} else printf("PASS T4 realtime\n"); }
    /* T5 mixed stream: note-on, clock, CC, sysex */
    { uint8_t in[]={0x90,0x3C,0x40, 0xF8, 0xB0,0x07,0x7F, 0xF0,0x7E,0xF7}; frame(in,10);
      uint8_t a[]={0x90,0x3C,0x40}, b[]={0xF8}, c[]={0xB0,0x07,0x7F}, d[]={0xF0,0x7E,0xF7};
      if(!(g_count==4 && eq(&g_sent[0],0,a,3) && eq(&g_sent[1],0,b,1)
           && eq(&g_sent[2],0,c,3) && eq(&g_sent[3],1,d,3))){printf("FAIL T5\n");fails++;}
      else printf("PASS T5 mixed (4 msgs split correctly)\n"); }
    /* T6 two channel msgs back-to-back (program change = 1 data byte) */
    { uint8_t in[]={0xC0,0x05, 0x90,0x3C,0x40}; frame(in,5);
      uint8_t a[]={0xC0,0x05}, b[]={0x90,0x3C,0x40};
      if(!(g_count==2 && eq(&g_sent[0],0,a,2) && eq(&g_sent[1],0,b,3))){printf("FAIL T6\n");fails++;} else printf("PASS T6 pgm+note split\n"); }
    /* T7 sysex with embedded real-time -> sent verbatim in the long msg */
    { uint8_t in[]={0xF0,0x7E,0xF8,0xF7}; frame(in,4);
      if(!(g_count==1 && eq(&g_sent[0],1,in,4))){printf("FAIL T7\n");fails++;} else printf("PASS T7 embedded-RT verbatim\n"); }
    /* T8 large sysex (>256, the no-cap claim at the framing level) */
    { uint8_t in[300]; in[0]=0xF0; for(int i=1;i<299;i++) in[i]=(uint8_t)(i&0x7F); in[299]=0xF7;
      frame(in,300);
      if(!(g_count==1 && g_sent[0].is_long && g_sent[0].n==300 && g_sent[0].bytes[0]==0xF0 && g_sent[0].bytes[299]==0xF7)){printf("FAIL T8\n");fails++;} else printf("PASS T8 large-sysex 300B whole\n"); }

    printf(fails? "\n%d FAIL\n":"\nALL PASS\n", fails);
    return fails?1:0;
}
