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
open_returns_opaque_resource_test_() ->
    runtime(fun() ->
        {ok, R} = midiio:context_open(),
        ?assert(is_reference(R)),
        ?assertNot(is_binary(R)),
        ?assertError(badarg, midiio:context_close(make_ref())),
        ok = midiio:context_close(R)
    end).

%% Row 5: context_close/1 returns ok on a live context (open -> close).
open_close_roundtrip_test_() ->
    runtime(fun() ->
        {ok, R} = midiio:context_open(),
        ?assertEqual(ok, midiio:context_close(R))
    end).

%% Row 6: a second close returns {error, not_open} without crashing.
double_close_is_tagged_error_test_() ->
    runtime(fun() ->
        {ok, R} = midiio:context_open(),
        ?assertEqual(ok, midiio:context_close(R)),
        ?assertEqual({error, not_open}, midiio:context_close(R))
    end).

%% Row 9: the mm_result -> atom mapping covers all 8 codes (0 .. -7). This is a
%% pure mapping NIF — no context, no backend — so it runs everywhere.
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
gc_runs_destructor_once_test_() ->
    runtime(fun() ->
        Before = midiio:uninit_count(),
        open_and_die(fun(_R) -> ok end),
        reclaim(),
        ?assertEqual(Before + 1, midiio:uninit_count())
    end).

%% Rows 7 + 8: an explicit close uninits once; the subsequent GC-triggered
%% destructor must NOT uninit again (the live flag guards the double path).
explicit_close_then_gc_no_double_uninit_test_() ->
    runtime(fun() ->
        Before = midiio:uninit_count(),
        open_and_die(fun(R) -> ok = midiio:context_close(R) end),
        reclaim(),
        ?assertEqual(Before + 1, midiio:uninit_count())
    end).

%% ── slice 3: enumeration + caps ─────────────────────────────────────────────
%% Headless CI may have no MIDI ports, so the enumeration tests assert *shape*
%% (a possibly-empty list of well-typed entries); caps is deterministic per OS.

%% Row 1: list_inputs/1 returns a list of {non_neg_integer, binary}.
list_inputs_shape_test_() ->
    runtime(fun() ->
        {ok, C} = midiio:context_open(),
        assert_port_list(midiio:list_inputs(C)),
        ok = midiio:context_close(C)
    end).

%% Row 2: list_outputs/1 same shape.
list_outputs_shape_test_() ->
    runtime(fun() ->
        {ok, C} = midiio:context_open(),
        assert_port_list(midiio:list_outputs(C)),
        ok = midiio:context_close(C)
    end).

%% Row 3: indices are ascending and contiguous 0..N-1 for the snapshot.
enumeration_indices_contiguous_test_() ->
    runtime(fun() ->
        {ok, C} = midiio:context_open(),
        InIdx  = [I || {I, _} <- midiio:list_inputs(C)],
        OutIdx = [I || {I, _} <- midiio:list_outputs(C)],
        ?assertEqual(lists:seq(0, length(InIdx) - 1), InIdx),
        ?assertEqual(lists:seq(0, length(OutIdx) - 1), OutIdx),
        ok = midiio:context_close(C)
    end).

%% Row 5: caps/1 returns a map with the 6 keys; backend atom, flags boolean.
caps_shape_test_() ->
    runtime(fun() ->
        {ok, C} = midiio:context_open(),
        Caps = midiio:caps(C),
        ?assert(is_map(Caps)),
        ?assertEqual(lists:sort([backend, midi1, ump, midi2, virtual_in, virtual_out]),
                     lists:sort(maps:keys(Caps))),
        ?assert(is_atom(maps:get(backend, Caps))),
        [?assert(is_boolean(maps:get(K, Caps)))
         || K <- [midi1, ump, midi2, virtual_in, virtual_out]],
        ok = midiio:context_close(C)
    end).

%% Rows 6 + 7: backend atom + flag decode for the host OS. On macOS/CoreMIDI the
%% full map is asserted (matches minimidio.h:817); other backends verify on their
%% own host (the branch is exercised by code read where CC lacks that OS).
caps_backend_and_flags_test_() ->
    runtime(fun() ->
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
        ok = midiio:context_close(C)
    end).

%% Row 8: a foreign handle is rejected with badarg by all three. No context is
%% opened (the badarg fires on the foreign ref), so this runs everywhere.
enumeration_bad_handle_test() ->
    R = make_ref(),
    ?assertError(badarg, midiio:list_inputs(R)),
    ?assertError(badarg, midiio:list_outputs(R)),
    ?assertError(badarg, midiio:caps(R)).

%% ── arc2/slice1: output device resource + lifecycle ─────────────────────────
%% Deterministic rows use a virtual output (headless-safe given a sequencer);
%% row 12 opens real hardware only when a destination is present.

%% Row 4: out-of-range index → {error, out_of_range}.
open_output_out_of_range_test_() ->
    runtime(fun() ->
        ?assertEqual({error, out_of_range}, midiio:open_output(100000))
    end).

%% Row 3: open returns an opaque device handle; a foreign ref is rejected.
open_output_virtual_opaque_test_() ->
    runtime(fun() ->
        {ok, D} = midiio:open_output_virtual(),
        ?assert(is_reference(D)),
        ?assertNot(is_binary(D)),
        ?assertError(badarg, midiio:close(make_ref())),
        ok = midiio:close(D)
    end).

%% Row 5: close/1 → ok on a live device.
open_output_close_roundtrip_test_() ->
    runtime(fun() ->
        {ok, D} = midiio:open_output_virtual(),
        ?assertEqual(ok, midiio:close(D))
    end).

%% Row 6: double close → {error, not_open}, no crash.
open_output_double_close_test_() ->
    runtime(fun() ->
        {ok, D} = midiio:open_output_virtual(),
        ?assertEqual(ok, midiio:close(D)),
        ?assertEqual({error, not_open}, midiio:close(D))
    end).

%% Row 8: dropping the handle runs the destructor, which uninits the per-device
%% context exactly once (counted via uninit_count, shared with the context dtor).
device_gc_runs_destructor_once_test_() ->
    runtime(fun() ->
        Before = midiio:uninit_count(),
        open_device_and_die(fun(_D) -> ok end),
        reclaim(),
        ?assertEqual(Before + 1, midiio:uninit_count())
    end).

%% Rows 8 + 9: an explicit close uninits once; the GC destructor must not uninit
%% again (the live flag guards the double path).
device_close_then_gc_no_double_uninit_test_() ->
    runtime(fun() ->
        Before = midiio:uninit_count(),
        open_device_and_die(fun(D) -> ok = midiio:close(D) end),
        reclaim(),
        ?assertEqual(Before + 1, midiio:uninit_count())
    end).

%% Row 12: real-hardware open (macOS). Only runs when a destination is present
%% (headless CI has none — then it's a no-op, covered by the virtual path above).
open_output_real_hardware_test_() ->
    runtime(fun() ->
        {ok, C} = midiio:context_open(),
        Outs = midiio:list_outputs(C),
        ok = midiio:context_close(C),
        case Outs of
            [] ->
                ok; %% no destinations on this host; skip the hardware open
            [_ | _] ->
                {ok, D} = midiio:open_output(0),
                ?assert(is_reference(D)),
                ?assertEqual(ok, midiio:close(D))
        end
    end).

%% ── runtime-availability gate ───────────────────────────────────────────────
%% Every test above that opens a real context or device needs a working MIDI
%% backend. On ALSA that means the kernel sequencer node /dev/snd/seq must exist
%% (see minimidio.h mm_context_init -> snd_seq_open, which returns MM_ERROR when
%% it can't open the sequencer). GitHub's hosted Linux runners use an Azure
%% kernel that ships no snd-seq module, so the node is absent and these rows are
%% disclosed-deferred there — build, NIF load, and the foreign-handle/result-map
%% rows still run. macOS/CoreMIDI always provides virtual ports, so the bodies
%% always run on macOS (full runtime coverage), as does any Linux host with a
%% real sequencer.
%%
%% runtime/1 wraps a test body: it yields a real eunit case when the backend is
%% usable, and an empty generator (skipped, not failed) when it is not.
runtime(Body) ->
    case runtime_available() of
        true  -> [Body];
        false -> []
    end.

runtime_available() ->
    case os:type() of
        %% /dev/snd/seq is a character-device node, so filelib:is_file/1 reports
        %% false for it — read_file_info/1 returns {ok,_} for any node type, so
        %% it's the right existence check here.
        {unix, linux} ->
            case file:read_file_info("/dev/snd/seq") of
                {ok, _} -> true;
                _       -> false
            end;
        _ -> true
    end.

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

%% Same, for a (virtual) output device.
open_device_and_die(Body) ->
    {_Pid, MRef} = spawn_monitor(fun() ->
        {ok, D} = midiio:open_output_virtual(),
        Body(D)
    end),
    receive {'DOWN', MRef, process, _, _} -> ok end.

%% Force collection of any now-unreferenced resource terms and give the
%% scheduler a moment to run the destructor.
reclaim() ->
    [erlang:garbage_collect(P) || P <- erlang:processes()],
    timer:sleep(50).
