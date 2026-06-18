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

%% ── arc2/slice2: send/2 over the raw seam ───────────────────────────────────
%% Verified by shape + error here; byte-exact *receipt* is arc-3 (no inbound path
%% yet — see the closing report). All need a live virtual output, so they ride the
%% runtime/1 gate; on macOS the virtual source emits with no destination.

%% Row 3: channel-voice messages route through mm_out_send and return ok.
send_channel_messages_test_() ->
    with_out(fun(D) ->
        ?assertEqual(ok, midiio:send(D, <<16#90, 60, 100>>)),   %% note on
        ?assertEqual(ok, midiio:send(D, <<16#80, 60,   0>>)),   %% note off
        ?assertEqual(ok, midiio:send(D, <<16#A0, 60,  64>>)),   %% poly pressure
        ?assertEqual(ok, midiio:send(D, <<16#B0,  7, 127>>)),   %% control change
        ?assertEqual(ok, midiio:send(D, <<16#C0,  5>>)),        %% program change (2-byte)
        ?assertEqual(ok, midiio:send(D, <<16#D0, 64>>)),        %% channel pressure (2-byte)
        ?assertEqual(ok, midiio:send(D, <<16#E0,  0,  64>>))    %% pitch bend
    end).

%% Row 4: a complete SysEx routes through mm_out_send_sysex and returns ok.
send_sysex_test_() ->
    with_out(fun(D) ->
        ?assertEqual(ok, midiio:send(D, <<16#F0, 16#7E, 16#7F, 16#09, 16#01, 16#F7>>))
    end).

%% Row 5: system common + real-time bytes map to the right type and return ok.
send_system_bytes_test_() ->
    with_out(fun(D) ->
        ?assertEqual(ok, midiio:send(D, <<16#F1, 16#10>>)),        %% MTC quarter frame
        ?assertEqual(ok, midiio:send(D, <<16#F2, 16#10, 16#20>>)), %% song position (14-bit)
        ?assertEqual(ok, midiio:send(D, <<16#F3, 5>>)),            %% song select
        ?assertEqual(ok, midiio:send(D, <<16#F6>>)),               %% tune request
        [?assertEqual(ok, midiio:send(D, <<B>>))                   %% real-time bytes
         || B <- [16#F8, 16#FA, 16#FB, 16#FC, 16#FE, 16#FF]]
    end).

%% Row 6: a closed device → {error, not_open}, no crash.
send_closed_device_test_() ->
    runtime(fun() ->
        {ok, D} = midiio:open_output_virtual(),
        ok = midiio:close(D),
        ?assertEqual({error, not_open}, midiio:send(D, <<16#90, 60, 100>>))
    end).

%% Row 7: unrecognized/unframable leading status → {error, {unsupported_status, B}}
%% (B is the integer status byte, never an atom).
send_unsupported_status_test_() ->
    with_out(fun(D) ->
        ?assertEqual({error, {unsupported_status, 16#F4}},
                     midiio:send(D, <<16#F4, 1, 2>>)),
        [?assertEqual({error, {unsupported_status, B}}, midiio:send(D, <<B>>))
         || B <- [16#F5, 16#F9, 16#FD]]
    end).

%% Row 8: SysEx larger than MM_SYSEX_BUF_SIZE (4096) → {error, invalid_arg}.
send_oversized_sysex_test_() ->
    with_out(fun(D) ->
        Payload = binary:copy(<<0>>, 5000),
        ?assertEqual({error, invalid_arg},
                     midiio:send(D, <<16#F0, Payload/binary, 16#F7>>))
    end).

%% Row 9: malformed input crashes (let-it-crash, §6) — never swallowed.
send_malformed_crashes_test_() ->
    with_out(fun(D) ->
        ?assertError(badarg, midiio:send(D, <<16#90, 60>>)),  %% short channel message
        ?assertError(badarg, midiio:send(D, <<60, 100>>)),    %% leading data byte
        ?assertError(badarg, midiio:send(D, <<>>))            %% empty binary
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

%% ── arc3/slice1: input lifecycle + recv + F1 close ──────────────────────────
%% The loopback uses a virtual output SOURCE + a real open_input connected to it
%% (headless-safe on CoreMIDI / snd-virmidi). Where the virtual source isn't
%% enumerable (some headless backends), the delivery tests skip.

%% Row 7: out-of-range index → {error, out_of_range} (headless-safe).
open_input_out_of_range_test() ->
    ?assertEqual({error, out_of_range}, midiio:open_input(100000, self())).

%% Row 11: one complete message arrives intact to the owner, with the device
%% handle as identity and an integer timestamp.
one_message_loopback_test() ->
    with_loopback(self(), fun(In, Out) ->
        ok = midiio:send(Out, <<16#90, 60, 100>>),
        receive
            {midi_in, Dev, Bytes, Ts} ->
                ?assertEqual(In, Dev),
                ?assertEqual(<<16#90, 60, 100>>, Bytes),
                ?assert(is_integer(Ts))
        after 3000 -> ?assert(false)
        end
    end).

%% Row 10: set_owner/2 redirects delivery to a new process.
set_owner_redirect_test() ->
    with_loopback(self(), fun(In, Out) ->
        Parent = self(),
        B = spawn(fun() ->
            receive {midi_in, _, Bytes, _} -> Parent ! {b_got, Bytes} end
        end),
        ok = midiio:set_owner(In, B),
        ok = midiio:send(Out, <<16#90, 61, 100>>),
        receive
            {b_got, Bytes} -> ?assertEqual(<<16#90, 61, 100>>, Bytes)
        after 3000 -> ?assert(false)
        end,
        %% the original owner (self) must NOT have received it
        receive {midi_in, _, _, _} -> ?assert(false) after 100 -> ok end
    end).

%% Row 9: close an input; double close → {error, not_open}.
input_close_double_close_test() ->
    with_loopback(self(), fun(In, _Out) ->
        ok = midiio:stop_input(In),
        ?assertEqual(ok, midiio:close(In)),
        ?assertEqual({error, not_open}, midiio:close(In))
    end).

%% Row 5: F1 tripwire — two processes share one output handle; one loops send,
%% the other closes mid-flight. Without the per-device lock send_nif's unlocked
%% live-check + handle deref would race close's teardown (use-after-free).
%% Completing N rounds with the VM alive is the behavioural close; the ASan/TSan
%% harness (make asan / make tsan) is the sanitizer evidence.
f1_send_vs_close_tripwire_test_() ->
    {timeout, 60, fun() ->
        lists:foreach(fun(_) ->
            {ok, Out} = midiio:open_output_virtual(),
            Parent = self(),
            S = spawn(fun() -> send_loop(Out, 4000), Parent ! done end),
            timer:sleep(2),
            ok = midiio:close(Out),     %% race the sender's loop
            receive done -> ok after 20000 -> exit({tripwire, S, stuck}) end
        end, lists:seq(1, 25)),
        ?assert(true)   %% reached here ⇒ no UAF crashed the VM
    end}.

%% Remediation row 2 (S1): close an input WHILE delivery is active must not hang.
%% On ALSA `mm_in_stop` pthread_joins the recv thread, so pre-fix (join under
%% res->lock, which recv_cb also takes) this deadlocks; the fix joins outside the
%% lock. On CoreMIDI `mm_in_stop` doesn't join, so on macOS this exercises the
%% close-vs-active-delivery path cleanly and the real deadlock tripwire is the
%% Linux leg (make vm-test / CI). The {timeout,_} would trip a pre-fix ALSA hang.
close_during_active_delivery_test_() ->
    {timeout, 60, fun() ->
        lists:foreach(fun(_) ->
            with_loopback(self(), fun(In, Out) ->
                Flood = spawn(fun() -> flood(Out) end),
                timer:sleep(3),
                ok = midiio:close(In),   %% must return, not hang
                exit(Flood, kill),
                flush_midi_in()
            end)
        end, lists:seq(1, 20)),
        ?assert(true)
    end}.

%% Remediation row 9 (S2): a started input whose owner dies WITHOUT stop/close is
%% reclaimed by the enif_monitor down callback — uninit_count increments (the same
%% counter the slice-1 GC tests use), no leak.
owner_death_reclaims_input_test_() ->
    {timeout, 30, fun() ->
        case virtual_source_index() of
            no_loopback ->
                ok; %% headless: virtual source not enumerable — skip
            {Idx, Out} ->
                Before = midiio:uninit_count(),
                {_Pid, MRef} = spawn_monitor(fun() ->
                    {ok, In} = midiio:open_input(Idx, self()),
                    ok = midiio:start_input(In),
                    ok  %% die WITHOUT stop/close
                end),
                receive {'DOWN', MRef, process, _, _} -> ok end,
                ok = wait_until(fun() -> midiio:uninit_count() > Before end, 5000),
                ?assert(midiio:uninit_count() > Before),
                midiio:close(Out)
        end
    end}.

%% ── arc3/slice2 Group A: set_owner atomic handoff (R1/R2) ────────────────────

%% Row 2 (R2 closed): handoff to an already-dead pid → {error, owner_not_alive},
%% and the OLD owner's monitor is preserved (the device still reclaims on the old
%% owner's death — no leak, no silently-disarmed monitor).
set_owner_dead_handoff_preserves_old_owner_test_() ->
    {timeout, 30, fun() ->
        case virtual_source_index() of
            no_loopback -> ok;
            {Idx, Out} ->
                Before = midiio:uninit_count(),
                {_C, MRef} = spawn_monitor(fun() ->
                    {ok, In} = midiio:open_input(Idx, self()),
                    Dead = spawn(fun() -> ok end),
                    timer:sleep(20),  %% let Dead exit
                    {error, owner_not_alive} = midiio:set_owner(In, Dead),
                    ok  %% this (old) owner dies; its still-armed monitor reclaims
                end),
                receive {'DOWN', MRef, process, _, _} -> ok end,
                ok = wait_until(fun() -> midiio:uninit_count() > Before end, 5000),
                ?assert(midiio:uninit_count() > Before),
                midiio:close(Out)
        end
    end}.

%% Row 3: handoff to a LIVE pid re-points ownership — the NEW owner's death
%% reclaims the device.
set_owner_live_handoff_redirects_reclaim_test_() ->
    {timeout, 30, fun() ->
        case virtual_source_index() of
            no_loopback -> ok;
            {Idx, Out} ->
                {ok, In} = midiio:open_input(Idx, self()),  %% test proc stays alive
                Before = midiio:uninit_count(),
                {P2, MRef} = spawn_monitor(fun() -> receive go -> ok end end),
                ?assertEqual(ok, midiio:set_owner(In, P2)),
                P2 ! go,  %% P2 dies without stop/close
                receive {'DOWN', MRef, process, _, _} -> ok end,
                ok = wait_until(fun() -> midiio:uninit_count() > Before end, 5000),
                ?assert(midiio:uninit_count() > Before),
                midiio:close(Out)
        end
    end}.

%% ── arc3/slice2 Group B: virtual-loopback taxonomy conformance ───────────────

%% Rows 7–10: every taxonomy member round-trips byte-exact through the transport
%% (14-bit pitch bend / song position with LSB≠MSB; SysEx of varied lengths).
taxonomy_byte_exact_loopback_test_() ->
    {timeout, 60, fun() ->
        with_loopback(self(), fun(_In, Out) ->
            lists:foreach(fun(Bytes) ->
                flush_midi_in(),
                ?assertEqual(ok, midiio:send(Out, Bytes)),
                receive
                    {midi_in, _Dev, Got, Ts} ->
                        ?assertEqual(Bytes, Got),
                        ?assert(is_integer(Ts))
                after 3000 -> erlang:error({loopback_timeout, Bytes})
                end
            end, taxonomy())
        end)
    end}.

%% Row 11: the bytes⇄message bridge round-trips byte-exact across a generated
%% taxonomy (both seams, no I/O). Run the PropEr property under eunit so it gates
%% in `rebar3 as test check`; also runnable standalone via
%% `rebar3 as test proper -m midiio_prop`.
seam_roundtrip_property_test_() ->
    {timeout, 120, fun() ->
        ?assert(proper:quickcheck(midiio_prop:prop_seam_roundtrip(),
                                  [{numtests, 300}, quiet]))
    end}.

%% ── arc3/slice2 Group C: upstream quirk cases (disclosed-tracked = pass) ──────

%% Row 12: U1 — large SysEx (>~256 B) over a CoreMIDI virtual source fails
%% (upstream stack-`MIDIPacketList` cap, MM_ERROR — no crash, no truncation).
%% Tracked, not silent. On ALSA there is no such cap → assert byte-exact if it sends.
u1_large_sysex_virtual_cap_test_() ->
    {timeout, 30, fun() ->
        with_loopback(self(), fun(_In, Out) ->
            Big = iolist_to_binary([16#F0, binary:copy(<<16#11>>, 400), 16#F7]),
            case backend() of
                coremidi ->
                    ?assertMatch({error, _}, midiio:send(Out, Big)); %% U1 cap
                _ ->
                    flush_midi_in(),
                    case midiio:send(Out, Big) of
                        ok          -> ?assertEqual([Big], collect_midi_in(500));
                        {error, _}  -> ok %% acceptable; tracked
                    end
            end
        end)
    end}.

%% Row 14: U2/R6 — vel-0 note-on (`9n nn 00`). midiio never folds it to note-off;
%% on CoreMIDI it passes through as sent. ALSA's *backend* folds it below us (the
%% U2 inconsistency, upstream) — disclosed, asserted per-backend.
u2_vel0_passthrough_test_() ->
    {timeout, 30, fun() ->
        with_loopback(self(), fun(_In, Out) ->
            Sent = <<16#90, 60, 0>>,
            flush_midi_in(),
            ok = midiio:send(Out, Sent),
            Got = collect_midi_in(300),
            case backend() of
                coremidi -> ?assertEqual([Sent], Got);                %% pass-through
                _        -> ?assert(Got =:= [Sent]                    %% no backend fold
                                    orelse Got =:= [<<16#80, 60, 0>>]) %% ALSA folds (U2)
            end
        end)
    end}.

%% Row 15: U3 — a real-time `F8` interleaved mid-SysEx. The upstream read-proc
%% defect (`minimidio.h:748–751`) absorbs an F8 into the SysEx body — BUT only when
%% it receives a single combined `[F0 … F8 … F7]` packet. Observed over the CoreMIDI
%% *virtual* loopback, CoreMIDI's send path splits the real-time byte out first, so
%% the absorption does NOT reproduce here: the clock arrives as its own `<<F8>>`
%% and no delivered SysEx body contains the F8. So U3 is **not reproducible over
%% virtual ports** (tracked: the defect remains real for real-hardware combined
%% packets — resolved by raw inbound framing). We assert the invariant that does
%% hold: no delivered SysEx absorbed the F8.
u3_realtime_in_sysex_test_() ->
    {timeout, 30, fun() ->
        with_loopback(self(), fun(_In, Out) ->
            case backend() of
                coremidi ->
                    flush_midi_in(),
                    ok = midiio:send(Out, <<16#F0, 16#7E, 16#F8, 16#F7>>),
                    Got = collect_midi_in(300),
                    AbsorbedF8 = lists:any(
                        fun(B) -> byte_size(B) >= 1
                                  andalso binary:first(B) =:= 16#F0
                                  andalso binary:match(B, <<16#F8>>) =/= nomatch
                        end, Got),
                    ?assertNot(AbsorbedF8); %% F8 not absorbed over the virtual loopback
                _ ->
                    ok %% ALSA real-time-in-SysEx handling: not asserted here
            end
        end)
    end}.

%% Row 13: S1 — inbound SysEx spanning more than one packet. On CoreMIDI this is
%% blocked by U1 (can't SEND >256 B over a virtual source) → not-reproducible
%% here. On ALSA (vm-test) a large SysEx is drivable: assert one intact `F0…F7`
%% arrives; a split/truncation would confirm S1.
s1_multipacket_inbound_sysex_test_() ->
    {timeout, 30, fun() ->
        with_loopback(self(), fun(_In, Out) ->
            case backend() of
                coremidi ->
                    ok; %% blocked by U1 on the virtual source — not reproducible
                _ ->
                    Big = iolist_to_binary([16#F0, binary:copy(<<16#22>>, 1000), 16#F7]),
                    flush_midi_in(),
                    case midiio:send(Out, Big) of
                        ok         -> ?assertEqual([Big], collect_midi_in(800));
                        {error, _} -> ok
                    end
            end
        end)
    end}.

%% ── helpers ────────────────────────────────────────────────────────────────

%% The backend atom for the host (coremidi/alsa/...).
backend() ->
    {ok, C} = midiio:context_open(),
    B = maps:get(backend, midiio:caps(C)),
    ok = midiio:context_close(C),
    B.

%% Collect all {midi_in,...} payloads arriving within Ms, in arrival order.
collect_midi_in(Ms) ->
    receive {midi_in, _Dev, Bytes, _Ts} -> [Bytes | collect_midi_in(Ms)]
    after Ms -> []
    end.

%% The byte-exact round-trip taxonomy (below the U1 SysEx cap; large/quirk cases
%% are Group C). 14-bit cases use LSB≠MSB so a swap or truncation would show.
taxonomy() ->
    [<<16#80, 60, 0>>,             %% note off
     <<16#90, 60, 100>>,           %% note on
     <<16#A0, 60, 64>>,            %% poly aftertouch
     <<16#B0, 7, 127>>,            %% control change
     <<16#C0, 5>>,                 %% program change
     <<16#D0, 64>>,                %% channel aftertouch
     <<16#E0, 16#7F, 16#3F>>,      %% pitch bend (14-bit, LSB 7F ≠ MSB 3F)
     <<16#F2, 16#10, 16#20>>,      %% song position (14-bit, LSB 10 ≠ MSB 20)
     <<16#F3, 5>>,                 %% song select
     <<16#F6>>,                    %% tune request
     <<16#F8>>, <<16#FA>>, <<16#FB>>, <<16#FC>>, <<16#FE>>, <<16#FF>>, %% real-time
     <<16#F0, 16#7E, 16#7F, 16#09, 16#01, 16#F7>>,                     %% SysEx (short, 6B)
     iolist_to_binary([16#F0, 16#7D, binary:copy(<<16#11>>, 32), 16#F7]) %% SysEx (mid, 35B)
    ].

%% Set up a virtual output source + a real input connected to it (one VM), run
%% Body(In, Out), then tear down. Skips (no assertion) if the virtual source is
%% not enumerable on this backend.
with_loopback(Owner, Body) ->
    {ok, Out} = midiio:open_output_virtual(),
    {ok, Ctx} = midiio:context_open(),
    Ins = midiio:list_inputs(Ctx),
    ok = midiio:context_close(Ctx),
    Match = [I || {I, N} <- Ins,
                  binary:match(N, <<"midiio-out:virtual">>) =/= nomatch],
    case Match of
        [Idx | _] ->
            {ok, In} = midiio:open_input(Idx, Owner),
            ok = midiio:start_input(In),
            timer:sleep(50),
            try Body(In, Out)
            after
                catch midiio:stop_input(In),
                catch midiio:close(In),
                catch midiio:close(Out)
            end;
        [] ->
            catch midiio:close(Out),
            ok %% virtual source not enumerable here; delivery test skipped
    end.

send_loop(_Dev, 0) -> ok;
send_loop(Dev, N) ->
    catch midiio:send(Dev, <<16#90, 60, 100>>),
    send_loop(Dev, N - 1).

%% Tight unbounded send loop (until the process is killed) for the deadlock test.
flood(Dev) ->
    catch midiio:send(Dev, <<16#90, 60, 100>>),
    flood(Dev).

%% Drain any delivered {midi_in, ...} from the mailbox.
flush_midi_in() ->
    receive {midi_in, _, _, _} -> flush_midi_in() after 0 -> ok end.

%% The input index of a freshly-created virtual output source (so a separate
%% process can open_input it), plus the source handle to close. no_loopback if the
%% virtual source isn't enumerable on this backend.
virtual_source_index() ->
    {ok, Out} = midiio:open_output_virtual(),
    {ok, Ctx} = midiio:context_open(),
    Ins = midiio:list_inputs(Ctx),
    ok = midiio:context_close(Ctx),
    case [I || {I, N} <- Ins,
               binary:match(N, <<"midiio-out:virtual">>) =/= nomatch] of
        [Idx | _] -> {Idx, Out};
        []        -> catch midiio:close(Out), no_loopback
    end.

%% Poll Pred until true or the budget (ms) runs out.
wait_until(Pred, Ms) when Ms =< 0 ->
    case Pred() of true -> ok; false -> timeout end;
wait_until(Pred, Ms) ->
    case Pred() of
        true  -> ok;
        false -> timer:sleep(25), wait_until(Pred, Ms - 25)
    end.

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

%% Open a virtual output, run Body(Dev), then close it — for the send tests.
%% Headless-safe via the slice-1 virtual scaffolding; rides the runtime/1 gate.
with_out(Body) ->
    runtime(fun() ->
        {ok, D} = midiio:open_output_virtual(),
        try Body(D) after midiio:close(D) end
    end).

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
