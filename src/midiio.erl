%%% @doc Cross-platform realtime MIDI I/O for the BEAM via a NIF over the
%%% minimidio C library (raw transport; no message codec).
%%%
%%% Surface so far: open/close an opaque per-call MIDI context and read-only
%%% discovery — `list_inputs/1', `list_outputs/1', `caps/1' (arc 1); open/close an
%%% output device (arc 2 slice 1); and `send/2', the outbound data path (arc 2
%%% slice 2). Inbound (recv) arrives in arc 3.
%%% @end
-module(midiio).

-on_load(init/0).

%% NOTE: result_atom/1, uninit_count/0, and seam_roundtrip/1 are test-only NIFs.
%% Gating them out of the shipped surface behind -DMIDIIO_TEST is not robust under
%% the single shared .so (L18; see rebar.config). They are kept in the surface but
%% are memory-safe — in particular seam_roundtrip's seam self-defends on length
%% (S2 remediation Fix 1), so it cannot read OOB for any input.
-nifs([context_open/0, context_close/1, result_atom/1, uninit_count/0,
       seam_roundtrip/1, list_inputs/1, list_outputs/1, caps/1,
       open_output/1, open_output_virtual/0, close/1, send/2,
       open_input/2, start_input/1, stop_input/1, set_owner/2]).

-export([context_open/0, context_close/1, result_atom/1, uninit_count/0,
         seam_roundtrip/1, list_inputs/1, list_outputs/1, caps/1,
         open_output/1, open_output_virtual/0, close/1, send/2,
         open_input/2, start_input/1, stop_input/1, set_owner/2]).

%% NOTE (F2, disclosed-deferred in arc1/slice5): result_atom/1, uninit_count/0,
%% and open_output_virtual/0 are test-only introspection/scaffolding NIFs. Gating
%% them out of the default surface via -ifdef(TEST)/-DMIDIIO_TEST was attempted
%% and reverted — pc builds one shared .so across profiles, so a test-only NIF set
%% makes load_nif order-dependent. See arc1/slice5/closing-report.md for the
%% re-entry path. They are harmless (S3).

-export_type([context/0, device/0, backend/0, caps/0]).

%% Opaque handle to a native mm_context. Only meaningful when passed back to a
%% midiio NIF; callers must not inspect it.
-type context() :: term().

%% Opaque handle to a native mm_device (distinct from context()); the identity of
%% an open device, passed back to close/1 (and send/recv in later arcs).
-type device() :: term().

%% The MIDI backend, chosen at compile time by minimidio's platform macro.
-type backend() :: coremidi | winmm | alsa | webmidi.

%% Decoded capability map for a context (mm_context_caps flags + backend).
-type caps() :: #{backend     := backend(),
                  midi1       := boolean(),
                  ump         := boolean(),
                  midi2       := boolean(),
                  virtual_in  := boolean(),
                  virtual_out := boolean()}.

-define(NOT_LOADED, erlang:nif_error(nif_not_loaded)).

%% @doc Loaded automatically via -on_load when the module is loaded.
-spec init() -> ok | {error, term()}.
init() ->
    Lib = filename:join(code:priv_dir(midiio), "midiio_nif"),
    erlang:load_nif(Lib, 0).

%% @doc Open a MIDI context, returning an opaque resource handle.
-spec context_open() -> {ok, context()} | {error, atom()}.
context_open() ->
    ?NOT_LOADED.

%% @doc Close a context opened with {@link context_open/0}. Returns
%% `{error, not_open}' if the context was already closed.
-spec context_close(context()) -> ok | {error, not_open}.
context_close(_Ctx) ->
    ?NOT_LOADED.

%% @doc Test/introspection NIF: map an mm_result integer code to its atom.
%% Used by the eunit suite to verify the full result-code mapping.
-spec result_atom(integer()) -> atom().
result_atom(_Code) ->
    ?NOT_LOADED.

%% @doc Test/introspection NIF: the process-global count of native context
%% uninit calls. Used by the eunit suite to verify destructor behaviour on GC.
-spec uninit_count() -> non_neg_integer().
uninit_count() ->
    ?NOT_LOADED.

%% @doc Test NIF: round-trip `Bytes' through both raw seams (outbound parse +
%% inbound build) with no I/O. Used by the PropEr bytes⇄message bridge property.
%% Memory-safe for any input (the seam self-defends on length); a truncated
%% fixed-length status returns `{error, unsupported_status}'.
-spec seam_roundtrip(binary()) -> {ok, binary()} | {error, unsupported_status}.
seam_roundtrip(_Bytes) ->
    ?NOT_LOADED.

%% @doc List the currently-visible MIDI input ports as `{Index, Name}' pairs,
%% in ascending index order. `Index' is a display-only snapshot ordinal (it
%% shifts on hotplug and is not a stable identity); `Name' is the UTF-8 name
%% minimidio reports, unmodified. Fresh query each call; may be empty.
-spec list_inputs(context()) -> [{non_neg_integer(), binary()}].
list_inputs(_Ctx) ->
    ?NOT_LOADED.

%% @doc List the currently-visible MIDI output ports. See {@link list_inputs/1}.
-spec list_outputs(context()) -> [{non_neg_integer(), binary()}].
list_outputs(_Ctx) ->
    ?NOT_LOADED.

%% @doc The backend atom and decoded capability flags for the context.
-spec caps(context()) -> caps().
caps(_Ctx) ->
    ?NOT_LOADED.

%% @doc Open the MIDI output port at `Index' (from {@link list_outputs/1}),
%% returning an opaque device handle. The device owns its own MIDI context;
%% {@link close/1} (or dropping the handle) reclaims both. Out-of-range index →
%% `{error, out_of_range}'.
-spec open_output(non_neg_integer()) -> {ok, device()} | {error, atom()}.
open_output(_Index) ->
    ?NOT_LOADED.

%% @doc Test/scaffolding NIF: open a virtual output device (no destination
%% needed) to exercise the device lifecycle headlessly. Not a public
%% virtual-port API.
-spec open_output_virtual() -> {ok, device()} | {error, atom()}.
open_output_virtual() ->
    ?NOT_LOADED.

%% @doc Close a device opened with {@link open_output/1}. Returns
%% `{error, not_open}' if it was already closed.
-spec close(device()) -> ok | {error, not_open}.
close(_Dev) ->
    ?NOT_LOADED.

%% @doc Send one complete MIDI message to an open output device, byte-exact and
%% with no normalization (R6). `Bytes' is a single status-complete message, status
%% byte first; `send/2' routes normal-vs-SysEx internally (the split is not in the
%% API, R4):
%% ```
%%   midiio:send(Dev, <<16#90, 60, 100>>).            %% note-on,  channel 0
%%   midiio:send(Dev, <<16#F0, 16#7E, 16#F7>>).       %% a complete SysEx
%% '''
%% Runs on a dirty I/O scheduler so a blocking backend drain never ties up a
%% normal scheduler. Returns `{error, not_open}' if the device is closed or is an
%% input; `{error, {unsupported_status, B}}' for a reserved/unframable leading
%% status byte (`16#F4', `16#F5', `16#F7', `16#F9', `16#FD'); and
%% `{error, invalid_arg}' for a SysEx larger than the 4096-byte backend buffer.
%% Malformed input — an empty binary, a leading data byte, or a known status with
%% the wrong length — raises (let-it-crash; the encoder upstream must not produce
%% it).
-spec send(device(), binary()) -> ok | {error, not_open}
                                     | {error, {unsupported_status, byte()}}
                                     | {error, invalid_arg}.
send(_Dev, _Bytes) ->
    ?NOT_LOADED.

%% @doc Open the MIDI input port at `Index' (from {@link list_inputs/1}), with
%% `Owner' as the process that will receive inbound messages. Returns an opaque
%% device handle owning its own MIDI context. After {@link start_input/1}, each
%% complete inbound message is delivered to the owner as
%% `{midi_in, Dev :: device(), Bytes :: binary(), TsNanos :: integer()}' —
%% one message per delivery, byte-exact (no normalization), with a host-monotonic
%% nanosecond timestamp (`0' when the backend gives none). The handle `Dev' is the
%% device's identity, echoed in every message. Out-of-range index →
%% `{error, out_of_range}'.
-spec open_input(non_neg_integer(), pid()) -> {ok, device()} | {error, atom()}.
open_input(_Index, _Owner) ->
    ?NOT_LOADED.

%% @doc Start delivering inbound messages from an input device to its owner.
-spec start_input(device()) -> ok | {error, atom()}.
start_input(_Dev) ->
    ?NOT_LOADED.

%% @doc Stop delivering inbound messages. After this no further `{midi_in, ...}'
%% arrives; the device stays open until {@link close/1}.
-spec stop_input(device()) -> ok | {error, atom()}.
stop_input(_Dev) ->
    ?NOT_LOADED.

%% @doc Redirect a device's inbound delivery to a new owner process. The handoff
%% is atomic: for an input device the new owner is monitored before the old is
%% released, so if `Pid' is already dead the call returns `{error, owner_not_alive}'
%% and the device keeps serving its current owner (the previous monitor is left
%% intact). For an output device it simply records the owner.
-spec set_owner(device(), pid()) -> ok | {error, owner_not_alive}.
set_owner(_Dev, _Pid) ->
    ?NOT_LOADED.
