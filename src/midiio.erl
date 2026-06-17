%%% @doc Cross-platform realtime MIDI I/O for the BEAM via a NIF over the
%%% minimidio C library (raw transport; no message codec).
%%%
%%% arc1/slice1 surface: open and close an opaque per-call MIDI context. The
%%% device API (enumeration, open/send/recv) arrives in later slices.
%%% @end
-module(midiio).

-on_load(init/0).

-nifs([context_open/0, context_close/1, result_atom/1, uninit_count/0]).

-export([context_open/0, context_close/1, result_atom/1, uninit_count/0]).

-export_type([context/0]).

%% Opaque handle to a native mm_context. Only meaningful when passed back to a
%% midiio NIF; callers must not inspect it.
-type context() :: term().

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
