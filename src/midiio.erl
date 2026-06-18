%%% @doc Cross-platform realtime MIDI I/O for the BEAM via a NIF over the
%%% minimidio C library (raw transport; no message codec).
%%%
%%% Surface so far: open/close an opaque per-call MIDI context (slice 1) and
%%% read-only discovery — `list_inputs/1', `list_outputs/1', `caps/1' (slice 3).
%%% Opening devices and send/recv arrive in later arcs.
%%% @end
-module(midiio).

-on_load(init/0).

-nifs([context_open/0, context_close/1, result_atom/1, uninit_count/0,
       list_inputs/1, list_outputs/1, caps/1,
       open_output/1, open_output_virtual/0, close/1]).

-export([context_open/0, context_close/1, result_atom/1, uninit_count/0,
         list_inputs/1, list_outputs/1, caps/1,
         open_output/1, open_output_virtual/0, close/1]).

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
