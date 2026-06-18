%%% @doc PropEr properties for midiio — the bytes⇄message bridge (arc3/slice2,
%%% ledger row 11; closes arc2/slice2's deferred round-trip property).
%%%
%%% The transport's one corruption-prone seam is the bytes⇄message bridge: a
%%% wrong data-byte count, a 14-bit LSB/MSB swap, or a dropped status would break
%%% *every* message of that type silently. `seam_roundtrip/1` drives a message
%%% through BOTH raw seams purely (outbound `midiio_bytes_to_msg` →
%%% inbound `midiio_msg_to_bytes`, no I/O), so a byte-exact round-trip over a
%%% generated taxonomy proves the bridge is lossless.
-module(midiio_prop).

-include_lib("proper/include/proper.hrl").

-export([prop_seam_roundtrip/0]).

%% Every valid, status-complete MIDI message round-trips through both seams
%% byte-for-byte (no normalization — vel-0 note-on stays a note-on; 14-bit values
%% and SysEx survive exactly).
prop_seam_roundtrip() ->
    ?FORALL(Bytes, midi_message(),
            {ok, Bytes} =:= midiio:seam_roundtrip(Bytes)).

%% ── generators ──────────────────────────────────────────────────────────────

midi_message() ->
    oneof([channel3(), channel2(), system_common(), real_time(), sysex()]).

%% Channel voice, 3 bytes: note off/on, poly aftertouch, control change, pitch
%% bend (the 14-bit case — distinct LSB/MSB are generated, so a swap would fail).
channel3() ->
    ?LET({St, Ch, D1, D2},
         {oneof([16#80, 16#90, 16#A0, 16#B0, 16#E0]), channel(), data7(), data7()},
         <<(St bor Ch), D1, D2>>).

%% Channel voice, 2 bytes: program change, channel aftertouch.
channel2() ->
    ?LET({St, Ch, D1},
         {oneof([16#C0, 16#D0]), channel(), data7()},
         <<(St bor Ch), D1>>).

system_common() ->
    oneof([
        ?LET({L, M}, {data7(), data7()}, <<16#F2, L, M>>),  %% song position (14-bit)
        ?LET(D, data7(), <<16#F3, D>>),                     %% song select
        <<16#F6>>                                           %% tune request
    ]).

real_time() ->
    oneof([<<16#F8>>, <<16#FA>>, <<16#FB>>, <<16#FC>>, <<16#FE>>, <<16#FF>>]).

%% SysEx of varied length (body is data bytes only — no 0xF7 mid-stream).
sysex() ->
    ?LET(Body, list(data7()), iolist_to_binary([16#F0, Body, 16#F7])).

channel() -> integer(0, 15).
data7()   -> integer(0, 127).
