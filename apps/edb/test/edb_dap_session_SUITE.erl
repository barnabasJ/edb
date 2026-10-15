%% Copyright (c) Meta Platforms, Inc. and affiliates.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%% % @format

%% Session management tests for the EDB DAP adapter

-module(edb_dap_session_SUITE).

-oncall("whatsapp_server_devx").

%% CT callbacks
-export([
    suite/0,
    all/0,
    groups/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Test cases
-export([
    %% Initialization
    test_fails_if_not_initialized/1,
    test_fails_if_initialized_twice/1,
    test_fails_if_invalid_launch_config/1,
    test_thread_labels/1,

    %% Shutdown
    test_handles_disconnect_request_via_attach/1,
    test_handles_disconnect_request_via_attach_can_terminate_debuggee/1,
    test_handles_disconnect_request_via_launch/1,
    test_handles_disconnect_request_via_launch_can_spare_debuggee/1,
    test_terminates_when_node_goes_down/1,
    test_owned_node_disconnect/1,
    test_owned_node_exit_status/1,
    test_owned_node_late_exit/1,
    test_terminates_when_node_goes_down_while_configuring/1
]).

-include_lib("assert/include/assert.hrl").
-include_lib("edb/include/edb_dap.hrl").

suite() ->
    [].

all() ->
    [
        test_thread_labels,
        {group, initialization},
        {group, shutdown}
    ].

groups() ->
    [
        {initialization, [
            test_fails_if_not_initialized,
            test_fails_if_initialized_twice,
            test_fails_if_invalid_launch_config
        ]},
        {shutdown, [
            test_handles_disconnect_request_via_attach,
            test_handles_disconnect_request_via_attach_can_terminate_debuggee,
            test_handles_disconnect_request_via_launch,
            test_handles_disconnect_request_via_launch_can_spare_debuggee,
            test_terminates_when_node_goes_down,
            test_owned_node_disconnect,
            test_owned_node_exit_status,
            test_owned_node_late_exit,
            test_terminates_when_node_goes_down_while_configuring
        ]}
    ].

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    edb_test_support:stop_all_peers(),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES -- Initialization
%%--------------------------------------------------------------------
test_thread_labels(Config) ->
    {ok, Client, #{peer := Peer, modules := #{labeled_worker := Source}}} =
        edb_dap_test_support:start_session_via_launch(Config, #{
            modules => [
                {source, [
                    ~"-module(labeled_worker).\n",
                    ~"-export([go/0]).\n",
                    ~"go() ->\n",
                    ~"    register(labeled_worker, self()),\n",
                    ~"    proc_lib:set_label({worker, 42}),\n",
                    ~"    receive done -> ok end.\n"
                ]}
            ]
        }),
    ok = edb_dap_test_support:configure(Client, [{Source, [{line, 6}]}]),
    {ok, ThreadId, _} = edb_dap_test_support:spawn_and_wait_for_bp(Client, Peer, {labeled_worker, go, []}),
    #{success := true, body := #{threads := Threads}} = edb_dap_test_client:threads(Client),
    [Name] = [N || #{id := Id, name := N} <- Threads, Id =:= ThreadId],
    ?assertNotEqual(nomatch, binary:match(Name, ~"(labeled_worker)")),
    ?assertNotEqual(nomatch, binary:match(Name, ~"({worker,42})")),
    ok.

test_fails_if_not_initialized(Config) ->
    {ok, Client} = edb_dap_test_support:start_test_client(Config),

    Response1 = edb_dap_test_client:threads(Client),
    ?assertMatch(
        #{
            request_seq := 1,
            type := response,
            success := false,
            body := #{error := #{id := ?ERROR_PRECONDITION_VIOLATION}}
        },
        Response1
    ).

test_fails_if_initialized_twice(Config) ->
    {ok, Client} = edb_dap_test_support:start_test_client(Config),

    AdapterID = atom_to_binary(?MODULE),
    Response1 = edb_dap_test_client:initialize(Client, #{adapterID => AdapterID}),
    ?assertMatch(#{request_seq := 1, type := response, success := true}, Response1),

    Response2 = edb_dap_test_client:initialize(Client, #{adapterID => AdapterID}),
    ?assertMatch(
        #{
            request_seq := 2,
            type := response,
            success := false,
            body := #{error := #{id := ?ERROR_PRECONDITION_VIOLATION}}
        },
        Response2
    ).

test_fails_if_invalid_launch_config(Config) ->
    % Use a lower-level API to pass an invalid configuration.
    {ok, Client} = edb_dap_test_support:start_test_client(Config),

    AdapterID = atom_to_binary(?MODULE),
    Response1 = edb_dap_test_client:initialize(Client, #{adapterID => AdapterID}),
    ?assertMatch(#{request_seq := 1, type := response, success := true}, Response1),

    % eqwalizer:ignore: Tests behavior with invalid input.
    Response2 = edb_dap_test_client:launch(Client, #{
        invalid => ~"invalid"
    }),
    ?assertMatch(
        #{
            request_seq := 2,
            type := response,
            success := false,
            body := #{error := #{id := ?JSON_RPC_ERROR_INVALID_PARAMS}}
        },
        Response2
    ).

%%--------------------------------------------------------------------
%% TEST CASES -- Shutdown
%%--------------------------------------------------------------------

test_handles_disconnect_request_via_attach(Config) ->
    {ok, #{peer := Peer, node := Node, cookie := Cookie, srcdir := Cwd}} = edb_test_support:start_peer_node(
        Config, #{}
    ),
    {ok, Client} = edb_dap_test_support:start_session_via_attach(Config, Node, Cookie, Cwd),

    DisconnectResponse = edb_dap_test_client:disconnect(Client, #{}),
    ?assertMatch(
        #{command := <<"disconnect">>, success := true},
        DisconnectResponse
    ),

    % Node is still up
    running = peer:get_state(Peer),

    ok.

test_handles_disconnect_request_via_attach_can_terminate_debuggee(Config) ->
    {ok, #{peer := Peer, node := Node, cookie := Cookie, srcdir := Cwd}} = edb_test_support:start_peer_node(
        Config, #{}
    ),
    {ok, Client} = edb_dap_test_support:start_session_via_attach(Config, Node, Cookie, Cwd),

    DisconnectResponse = edb_dap_test_client:disconnect(Client, #{
        terminateDebuggee => true
    }),
    ?assertMatch(
        #{command := <<"disconnect">>, success := true},
        DisconnectResponse
    ),

    % Node was killed
    wait_until_down(Peer, 5_000),

    ok.

test_handles_disconnect_request_via_launch(Config) ->
    {ok, Client, #{peer := Peer}} = edb_dap_test_support:start_session_via_launch(Config, #{}),

    running = peer:get_state(Peer),

    DisconnectResponse = edb_dap_test_client:disconnect(Client, #{}),
    ?assertMatch(
        #{command := <<"disconnect">>, success := true},
        DisconnectResponse
    ),

    % Node was killed
    wait_until_down(Peer, 5_000),
    ok.

test_handles_disconnect_request_via_launch_can_spare_debuggee(Config) ->
    {ok, Client, #{peer := Peer}} = edb_dap_test_support:start_session_via_launch(Config, #{}),

    running = peer:get_state(Peer),

    DisconnectResponse = edb_dap_test_client:disconnect(Client, #{
        terminateDebuggee => false
    }),
    ?assertMatch(
        #{command := <<"disconnect">>, success := true},
        DisconnectResponse
    ),

    % Node is still up
    running = peer:get_state(Peer),

    ok.

test_terminates_when_node_goes_down(Config) ->
    {ok, Client, #{peer := Peer}} = edb_dap_test_support:start_session_via_launch(Config, #{}),
    ok = edb_dap_test_support:configure(Client, []),

    edb_test_support:stop_peer(Peer),

    {ok, ExitedEvent} = edb_dap_test_client:wait_for_event(~"exited", Client),
    ?assertMatch([#{event := ~"exited", body := #{exitCode := 0}}], ExitedEvent),

    {ok, TerminatedEvent} = edb_dap_test_client:wait_for_event(~"terminated", Client),
    ?assertMatch([#{event := ~"terminated"}], TerminatedEvent),

    ok.

test_terminates_when_node_goes_down_while_configuring(Config) ->
    {ok, Client, #{peer := Peer}} = edb_dap_test_support:start_session_via_launch(Config, #{}),

    edb_test_support:stop_peer(Peer),

    ok = edb_dap_test_support:configure(Client, []),

    {ok, ExitedEvent} = edb_dap_test_client:wait_for_event(~"exited", Client),
    ?assertMatch([#{event := ~"exited", body := #{exitCode := 0}}], ExitedEvent),

    {ok, TerminatedEvent} = edb_dap_test_client:wait_for_event(~"terminated", Client),
    ?assertMatch([#{event := ~"terminated"}], TerminatedEvent),

    ok.

test_owned_node_disconnect(Config) ->
    {ok, Client, _Node} = edb_dap_test_support:start_session_via_launch_run(Config, #{}),
    ok = edb_dap_test_support:configure(Client, []),
    #{success := true, body := #{result := PidBinary}} = edb_dap_test_client:evaluate(Client, #{
        expression => ~"list_to_integer(os:getpid())"
    }),
    Pid = binary_to_integer(PidBinary),
    try
        #{success := true} = edb_dap_test_client:evaluate(Client, #{
            expression =>
                ~"spawn(fun() -> timer:sleep(50), lists:foreach(fun erlang:disconnect_node/1, nodes(connected)) end), ok"
        }),
        {ok, [#{event := ~"terminated"}]} = edb_dap_test_client:wait_for_event(~"terminated", Client),
        ?assert(os_process_alive(Pid)),
        ?assertMatch(
            #{success := false, body := #{error := #{id := ?ERROR_PRECONDITION_VIOLATION}}},
            edb_dap_test_client:threads(Client)
        ),
        #{received := Received} = sys:get_state(Client),
        ?assertEqual([], maps:get({event, ~"exited"}, Received, [])),
        #{success := true} = edb_dap_test_client:disconnect(Client, #{}),
        wait_until_os_process_down(Pid, 5_000)
    after
        case os_process_alive(Pid) of
            true -> os:cmd("kill -9 " ++ integer_to_list(Pid));
            false -> ok
        end
    end.

test_owned_node_exit_status(Config) ->
    {ok, Client, _Node} = edb_dap_test_support:start_session_via_launch_run(Config, #{}),
    ok = edb_dap_test_support:configure(Client, []),
    #{success := true} = edb_dap_test_client:evaluate(Client, #{
        expression => ~"spawn(fun() -> timer:sleep(50), halt(2) end), ok"
    }),
    {ok, [#{body := #{exitCode := 2}}]} = edb_dap_test_client:wait_for_event(~"exited", Client),
    {ok, [#{event := ~"terminated"}]} = edb_dap_test_client:wait_for_event(~"terminated", Client),
    % Allow the grace timer to expire: its stale message must not terminate twice.
    receive
    after 1_200 -> ok
    end,
    #{received := Received} = sys:get_state(Client),
    ?assertEqual([], maps:get({event, ~"terminated"}, Received, [])),
    ?assertEqual([], maps:get({event, ~"exited"}, Received, [])),
    #{success := true} = edb_dap_test_client:disconnect(Client, #{}).

test_owned_node_late_exit(Config) ->
    {ok, Client, Node} = edb_dap_test_support:start_session_via_launch_run(Config, #{}),
    ok = edb_dap_test_support:configure(Client, []),
    #{success := true} = edb_dap_test_client:evaluate(Client, #{
        expression =>
            ~"spawn(fun() -> timer:sleep(50), lists:foreach(fun erlang:disconnect_node/1, nodes(connected)), timer:sleep(1500), halt(2) end), ok"
    }),
    {ok, [#{event := ~"terminated"}]} = edb_dap_test_client:wait_for_event(~"terminated", Client),
    receive
    after 1_000 -> ok
    end,
    #{success := false} = edb_dap_test_client:threads(Client),
    #{received := Received, io := Port} = sys:get_state(Client),
    ?assertEqual([], maps:get({event, ~"terminated"}, Received, [])),
    ?assertEqual([], maps:get({event, ~"exited"}, Received, [])),
    % Check ownership clearing directly: the transport integration cannot
    % observe whether the adapter retained a PID after the late exit.
    {noreply, FinalState} = edb_dap_server:handle_info({Port, {exit_status, 2}}, #{
        state => terminating,
        node_down => make_ref(),
        node => Node,
        port => Port,
        type => #{request => launch, process_id => 1}
    }),
    ?assertEqual(#{state => terminating}, FinalState),
    #{success := true} = edb_dap_test_client:disconnect(Client, #{}).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec os_process_alive(pos_integer()) -> boolean().
os_process_alive(Pid) ->
    Port = open_port({spawn_executable, os:find_executable("kill")}, [
        exit_status, stderr_to_stdout, {args, ["-0", integer_to_list(Pid)]}
    ]),
    receive
        {Port, {exit_status, Status}} -> Status =:= 0
    end.

-spec wait_until_os_process_down(pos_integer(), non_neg_integer()) -> ok.
wait_until_os_process_down(Pid, Timeout) ->
    case os_process_alive(Pid) of
        false ->
            ok;
        true when Timeout > 0 ->
            receive
            after 10 -> ok
            end,
            wait_until_os_process_down(Pid, Timeout - 10);
        true ->
            error(debuggee_os_process_survived_disconnect)
    end.

-spec wait_until_down(Peer, Timeout) -> ok when
    Peer :: edb_test_support:peer(),
    Timeout :: timeout().
wait_until_down(Peer, Timeout) ->
    case peer:get_state(Peer) of
        {down, _} ->
            ok;
        running when Timeout > 0 ->
            SleepTime = 10,
            % elp:ignore W0081 -- WAnnn codes are unknown to OSS ELP
            % elp:ignore WA019 (no_sleep) -- need to poll
            timer:sleep(SleepTime),
            Timeout1 =
                case Timeout of
                    infinity -> Timeout;
                    _ -> Timeout - SleepTime
                end,
            wait_until_down(Peer, Timeout1);
        running ->
            error(peer_never_died)
    end.
