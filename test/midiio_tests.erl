%%% @doc eunit suite for arc1/slice1: NIF load + context resource lifecycle.
%%% Closes ledger rows 4 (opaque resource), 5 (close ok), 6 (double close),
%%% 7 (destructor runs once on GC, no double-uninit), and 9 (result mapping).
-module(midiio_tests).

-include_lib("eunit/include/eunit.hrl").

%% Row 4 (amended): context_open/0 returns {ok, R} with no exception, and R is
%% an opaque, type-checked resource handle. In OTP 28 a NIF resource term is a
%% magic reference, so is_reference(R) is true; opacity is proven by the handle
%% being type-checked — a foreign ordinary reference (make_ref/0) is rejected by
%% context_close/1 with badarg, so the handle cannot be forged.
open_returns_opaque_resource_test() ->
    {ok, R} = midiio:context_open(),
    ?assert(is_reference(R)),
    ?assertNot(is_binary(R)),
    ?assertError(badarg, midiio:context_close(make_ref())),
    ok = midiio:context_close(R).

%% Row 5: context_close/1 returns ok on a live context (open -> close).
open_close_roundtrip_test() ->
    {ok, R} = midiio:context_open(),
    ?assertEqual(ok, midiio:context_close(R)).

%% Row 6: a second close returns {error, not_open} without crashing.
double_close_is_tagged_error_test() ->
    {ok, R} = midiio:context_open(),
    ?assertEqual(ok, midiio:context_close(R)),
    ?assertEqual({error, not_open}, midiio:context_close(R)).

%% Row 9: the mm_result -> atom mapping covers all 8 codes (0 .. -7).
result_atom_mapping_test() ->
    ?assertEqual(ok,            midiio:result_atom(0)),
    ?assertEqual(error,         midiio:result_atom(-1)),
    ?assertEqual(invalid_arg,   midiio:result_atom(-2)),
    ?assertEqual(no_backend,    midiio:result_atom(-3)),
    ?assertEqual(out_of_range,  midiio:result_atom(-4)),
    ?assertEqual(already_open,  midiio:result_atom(-5)),
    ?assertEqual(not_open,      midiio:result_atom(-6)),
    ?assertEqual(alloc_failed,  midiio:result_atom(-7)).

%% Row 7: dropping the last handle and forcing GC runs the destructor exactly
%% once. The context is opened inside a short-lived process; when that process
%% dies, the resource term becomes garbage and the destructor must uninit once.
gc_runs_destructor_once_test() ->
    Before = midiio:uninit_count(),
    open_and_die(fun(_R) -> ok end),
    reclaim(),
    ?assertEqual(Before + 1, midiio:uninit_count()).

%% Rows 7 + 8: an explicit close uninits once; the subsequent GC-triggered
%% destructor must NOT uninit again (the live flag guards the double path).
explicit_close_then_gc_no_double_uninit_test() ->
    Before = midiio:uninit_count(),
    open_and_die(fun(R) -> ok = midiio:context_close(R) end),
    reclaim(),
    ?assertEqual(Before + 1, midiio:uninit_count()).

%% ── slice 3: enumeration + caps ─────────────────────────────────────────────
%% Headless CI may have no MIDI ports, so the enumeration tests assert *shape*
%% (a possibly-empty list of well-typed entries); caps is deterministic per OS.

%% Row 1: list_inputs/1 returns a list of {non_neg_integer, binary}.
list_inputs_shape_test() ->
    {ok, C} = midiio:context_open(),
    assert_port_list(midiio:list_inputs(C)),
    ok = midiio:context_close(C).

%% Row 2: list_outputs/1 same shape.
list_outputs_shape_test() ->
    {ok, C} = midiio:context_open(),
    assert_port_list(midiio:list_outputs(C)),
    ok = midiio:context_close(C).

%% Row 3: indices are ascending and contiguous 0..N-1 for the snapshot.
enumeration_indices_contiguous_test() ->
    {ok, C} = midiio:context_open(),
    InIdx  = [I || {I, _} <- midiio:list_inputs(C)],
    OutIdx = [I || {I, _} <- midiio:list_outputs(C)],
    ?assertEqual(lists:seq(0, length(InIdx) - 1), InIdx),
    ?assertEqual(lists:seq(0, length(OutIdx) - 1), OutIdx),
    ok = midiio:context_close(C).

%% Row 5: caps/1 returns a map with the 6 keys; backend atom, flags boolean.
caps_shape_test() ->
    {ok, C} = midiio:context_open(),
    Caps = midiio:caps(C),
    ?assert(is_map(Caps)),
    ?assertEqual(lists:sort([backend, midi1, ump, midi2, virtual_in, virtual_out]),
                 lists:sort(maps:keys(Caps))),
    ?assert(is_atom(maps:get(backend, Caps))),
    [?assert(is_boolean(maps:get(K, Caps)))
     || K <- [midi1, ump, midi2, virtual_in, virtual_out]],
    ok = midiio:context_close(C).

%% Rows 6 + 7: backend atom + flag decode for the host OS. On macOS/CoreMIDI the
%% full map is asserted (matches minimidio.h:817); other backends verify on their
%% own host (the branch is exercised by code read where CC lacks that OS).
caps_backend_and_flags_test() ->
    {ok, C} = midiio:context_open(),
    Caps = midiio:caps(C),
    case maps:get(backend, Caps) of
        coremidi ->
            ?assertEqual(#{backend => coremidi, midi1 => true, ump => false,
                           midi2 => false, virtual_in => true,
                           virtual_out => true}, Caps);
        Other ->
            ?assert(lists:member(Other, [winmm, alsa, webmidi]))
    end,
    ok = midiio:context_close(C).

%% Row 8: a foreign handle is rejected with badarg by all three.
enumeration_bad_handle_test() ->
    R = make_ref(),
    ?assertError(badarg, midiio:list_inputs(R)),
    ?assertError(badarg, midiio:list_outputs(R)),
    ?assertError(badarg, midiio:caps(R)).

%% ── helpers ────────────────────────────────────────────────────────────────

%% A port list is a list of {non_neg_integer(), binary()} (possibly empty).
assert_port_list(L) ->
    ?assert(is_list(L)),
    lists:foreach(
        fun({I, N}) ->
            ?assert(is_integer(I)),
            ?assert(I >= 0),
            ?assert(is_binary(N))
        end, L).

%% Open a context in a monitored child process, hand it to Body, then let the
%% process exit so its heap (and the resource term) is reclaimed. Blocks until
%% the child is gone.
open_and_die(Body) ->
    {_Pid, MRef} = spawn_monitor(fun() ->
        {ok, R} = midiio:context_open(),
        Body(R)
    end),
    receive {'DOWN', MRef, process, _, _} -> ok end.

%% Force collection of any now-unreferenced resource terms and give the
%% scheduler a moment to run the destructor.
reclaim() ->
    [erlang:garbage_collect(P) || P <- erlang:processes()],
    timer:sleep(50).
