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

%% ── helpers ────────────────────────────────────────────────────────────────

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
