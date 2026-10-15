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

-module(edb_dap_elixir_SUITE).
-oncall("whatsapp_server_devx").
-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([test_elixir_debug_session/1, test_variable_rebinding/1, test_mix_launch/1, test_mix_exunit_launch/1]).
-export([test_pipeline_steps/1]).
-include_lib("assert/include/assert.hrl").

all() ->
    [test_elixir_debug_session, test_variable_rebinding, test_mix_launch, test_mix_exunit_launch, test_pipeline_steps].

init_per_suite(Config) ->
    case {code:which('Elixir.Code'), code:which('Elixir.Mix.Tasks.Compile.Edb')} of
        {non_existing, _} ->
            {skip, "Elixir is not on the code path"};
        {_, non_existing} ->
            {skip, "Build integrations/elixir and add edb_mix to ERL_LIBS"};
        _ ->
            {ok, _} = application:ensure_all_started(elixir),
            Config
    end.

end_per_suite(_) -> ok.

end_per_testcase(_, _) ->
    edb_test_support:stop_all_peers(),
    ok.

test_variable_rebinding(_) ->
    Vars = #{
        ~"_x@1" => {value, 1},
        ~"_x@12" => {value, 12},
        ~"_x@2" => {value, 2},
        ~"_@1" => {value, hidden}
    },
    ?assertEqual([{~"x", ~"_x@12", {value, 12}}], edb_dap_language_elixir:visible_variables(Vars)),
    ?assertEqual(13, edb_dap_language_elixir:evaluate(~"x + 1", #{vars => Vars})).

test_pipeline_steps(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    Source = filename:join(PrivDir, "pipeline.ex"),
    ok = file:write_file(
        Source,
        ~"defmodule EdbPipelineFixture do\n def go(x) do\n  result = x\n  |> first()\n  |> EdbPipelineFixture.second()\n  |> third()\n  result\n end\n def first(x), do: x + 1\n def second(x), do: x * 2\n def third(x), do: x + 3\nend\n"
    ),
    [{Module, Binary}] = 'Elixir.Code':compile_file(list_to_binary(Source)),
    Beam = filename:join(PrivDir, atom_to_list(Module) ++ ".beam"),
    ok = file:write_file(Beam, Binary),
    ok = 'Elixir.Mix.Tasks.Compile.Edb':instrument(list_to_binary(Beam)),
    true = code:add_patha(PrivDir),
    try
        {ok, Client, #{peer := Peer}} = edb_dap_test_support:start_session_via_launch(
            Config,
            #{},
            #{copy_code_path => true},
            [{"ERL_AFLAGS", "-eval application:set_env(edb,dap_language,edb_dap_language_elixir)"}]
        ),
        % Enter from a function breakpoint: its first stop must be the first
        % pipeline call, rather than the final outer call.
        #{success := true, body := #{breakpoints := [#{verified := true}]}} =
            edb_dap_test_client:set_function_breakpoints(Client, #{
                breakpoints => [#{name => ~"EdbPipelineFixture.go/1"}]
            }),
        #{success := true} = edb_dap_test_client:configuration_done(Client),
        peer:call(Peer, erlang, spawn, [Module, go, [2]]),
        {ok, Thread, [#{line := 4} | _]} = wait_for_step(Client),
        lists:foreach(
            fun({CallLine, Function, FunctionLine, ReturnLine}) ->
                #{success := true} = edb_dap_test_client:step_in(Client, #{threadId => Thread}),
                {ok, Thread, [#{name := Function, line := FunctionLine}, #{line := CallLine} | _]} = wait_for_step(
                    Client
                ),
                #{success := true} = edb_dap_test_client:step_out(Client, #{threadId => Thread}),
                {ok, Thread, [#{line := ReturnLine} | _]} = wait_for_step(Client)
            end,
            [
                {4, ~"EdbPipelineFixture.first/1", 9, 5},
                {5, ~"EdbPipelineFixture.second/1", 10, 6},
                {6, ~"EdbPipelineFixture.third/1", 11, 7}
            ]
        ),
        #{success := true, body := #{stackFrames := [#{id := Frame} | _]}} =
            edb_dap_test_client:stack_trace(Client, #{threadId => Thread}),
        ?assertMatch(
            #{success := true, body := #{result := ~"9"}},
            edb_dap_test_client:evaluate(Client, #{frameId => Frame, expression => ~"result"})
        ),
        ?assertEqual(
            #{~"x" => ~"2", ~"result" => ~"9"},
            maps:get(vars, edb_dap_test_support:get_top_frame(Client, Thread))
        ),
        #{success := true} = edb_dap_test_client:continue(Client, #{threadId => Thread}),
        % Step-over visits each stage without entering its helper.
        peer:call(Peer, erlang, spawn, [Module, go, [2]]),
        {ok, Thread2, [#{line := 4} | _]} = wait_for_step(Client),
        lists:foreach(
            fun(Line) ->
                #{success := true} = edb_dap_test_client:next(Client, #{threadId => Thread2}),
                {ok, Thread2, [#{name := ~"EdbPipelineFixture.go/1", line := Line} | _]} = wait_for_step(Client)
            end,
            [5, 6, 7]
        ),
        #{success := true} = edb_dap_test_client:continue(Client, #{threadId => Thread2})
    after
        code:del_path(PrivDir)
    end.

test_elixir_debug_session(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    Source = filename:join(PrivDir, "multiple_modules.ex"),
    Text =
        ~"defmodule EdbFixture do\n  def go(x) do\n    y = helper(x)\n    z = %{answer: y}\n    :erlang.send(self(), z)\n    z\n  end\n  def helper(x) do\n    x + 1\n  end\nend\ndefmodule EdbFixture.Other do\n  def go do\n    :erlang.self()\n  end\nend\n",
    ok = file:write_file(Source, Text),
    Compiled = 'Elixir.Code':compile_file(list_to_binary(Source)),
    lists:foreach(
        fun({M, Binary}) ->
            Beam = filename:join(PrivDir, atom_to_list(M) ++ ".beam"),
            ok = file:write_file(Beam, Binary),
            ok = 'Elixir.Mix.Tasks.Compile.Edb':instrument(list_to_binary(Beam))
        end,
        Compiled
    ),
    true = code:add_patha(PrivDir),
    try
        AdapterEnv = [{"ERL_AFLAGS", "-eval application:set_env(edb,dap_language,edb_dap_language_elixir)"}],
        {ok, Client, #{peer := Peer}} = edb_dap_test_support:start_session_via_launch(
            Config, #{}, #{copy_code_path => true}, AdapterEnv
        ),
        Response = edb_dap_test_client:set_breakpoints(Client, #{
            source => #{path => list_to_binary(Source)},
            breakpoints => [#{line => 3}, #{line => 5}, #{line => 14}]
        }),
        ?assertMatch(
            #{
                success := true,
                body := #{
                    breakpoints := [
                        #{verified := true}, #{verified := true}, #{verified := true}
                    ]
                }
            },
            Response
        ),
        #{success := true} = edb_dap_test_client:configuration_done(Client),
        {ok, _} = peer:call(Peer, application, ensure_all_started, [elixir]),
        {ok, Thread, [#{id := Frame, name := ~"EdbFixture.go/1", line := 3} | _]} =
            edb_dap_test_support:spawn_and_wait_for_bp(Client, Peer, {'Elixir.EdbFixture', go, [2]}),
        ?assertMatch(
            #{success := true, body := #{result := ~"3"}},
            edb_dap_test_client:evaluate(Client, #{frameId => Frame, expression => ~"x + 1"})
        ),
        #{success := true} = edb_dap_test_client:step_in(Client, #{threadId => Thread}),
        {ok, Thread, [#{name := ~"EdbFixture.helper/1", line := 9} | _]} =
            wait_for_step(Client),
        #{success := true} = edb_dap_test_client:step_out(Client, #{threadId => Thread}),
        {ok, Thread, [#{line := 4} | _]} = wait_for_step(Client),
        #{success := true} = edb_dap_test_client:next(Client, #{threadId => Thread}),
        {ok, Thread, [#{id := Frame2, line := 5} | _]} = wait_for_step(Client),
        ?assertMatch(
            #{vars := #{~"x" := ~"2", ~"y" := ~"3", ~"z" := ~"%{answer: 3}"}},
            edb_dap_test_support:get_top_frame(Client, Thread)
        ),
        ?assertMatch(
            #{success := true, body := #{result := ~"%{answer: 3}"}},
            edb_dap_test_client:evaluate(Client, #{frameId => Frame2, expression => ~"z"})
        ),
        ?assertMatch(
            #{success := false},
            edb_dap_test_client:evaluate(Client, #{frameId => Frame2, expression => ~"z +"})
        ),
        assert_expandable_expression(Client, Frame2),
        #{success := true} = edb_dap_test_client:continue(Client, #{threadId => Thread}),
        % Replacing all source breakpoints also clears every module in the file.
        ?assertMatch(
            #{success := true, body := #{breakpoints := []}},
            edb_dap_test_client:set_breakpoints(Client, #{
                source => #{path => list_to_binary(Source)}, breakpoints => []
            })
        ),
        ?assertMatch(
            #{success := true, body := #{breakpoints := [#{verified := true}]}},
            edb_dap_test_client:set_function_breakpoints(Client, #{breakpoints => [#{name => ~"EdbFixture.Other.go/0"}]})
        ),
        peer:call(Peer, erlang, spawn, ['Elixir.EdbFixture.Other', go, []]),
        {ok, OtherThread, [#{name := ~"EdbFixture.Other.go/0", line := 14} | _]} = wait_for_step(Client),
        #{success := true} = edb_dap_test_client:continue(Client, #{threadId => OtherThread})
    after
        code:del_path(PrivDir)
    end.

wait_for_step(Client) ->
    {ok, [#{body := #{threadId := Thread, reason := Reason}}]} =
        edb_dap_test_client:wait_for_event(~"stopped", Client),
    ?assert(lists:member(Reason, [~"step", ~"breakpoint", ~"function_breakpoint"])),
    #{success := true, body := #{stackFrames := Frames}} =
        edb_dap_test_client:stack_trace(Client, #{threadId => Thread}),
    {ok, Thread, Frames}.

test_mix_launch(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    Project = filename:join(PrivDir, "mix_project"),
    ok = filelib:ensure_dir(filename:join([Project, "lib", "fixture.ex"])),
    TaskSource = proplists:get_value(source, 'Elixir.Mix.Tasks.Compile.Edb':module_info(compile)),
    PackagePath = lists:foldl(fun(_, Path) -> filename:dirname(Path) end, TaskSource, lists:seq(1, 4)),
    ok = file:write_file(
        filename:join(Project, "mix.exs"),
        io_lib:format(
            "defmodule EdbLaunch.MixProject do\n use Mix.Project\n def project, do: [app: :edb_launch, version: \"0.1.0\", compilers: Mix.compilers() ++ [:edb], deps: [{:edb_mix, path: ~p, runtime: false}]]\nend\n",
            [PackagePath]
        )
    ),
    Source = filename:join([Project, "lib", "fixture.ex"]),
    ok = file:write_file(
        Source,
        ~"defmodule EdbLaunch do\n def go(x) do\n  y = x + 1\n  :erlang.send(self(), y)\n end\nend\n"
    ),
    {ok, Client} = edb_dap_test_support:start_test_client(Config),
    #{success := true} = edb_dap_test_client:initialize(Client, #{adapterID => ~"edb-elixir-test"}),
    TaskDir = filename:dirname(code:which('Elixir.Mix.Tasks.Compile.Edb')),
    #{success := true} = edb_dap_test_client:launch(Client, #{
        run => #{
            cwd => list_to_binary(Project),
            args => [
                list_to_binary(os:find_executable("elixir")),
                ~"-pa",
                list_to_binary(TaskDir),
                ~"-S",
                ~"mix",
                ~"edb",
                ~"--no-halt",
                ~"-e",
                ~"EdbLaunch.go(2)"
            ]
        },
        config => #{
            nameDomain => shortnames,
            language => elixir,
            nodeInitCodeInEnvVar => ~"EDB_DAP_DEBUGGEE_INIT",
            timeout => 30
        }
    }),
    try
        {ok, [_]} = edb_dap_test_client:wait_for_event(~"initialized", Client),
        ?assertMatch(
            #{success := true, body := #{breakpoints := [#{verified := true}]}},
            edb_dap_test_client:set_breakpoints(Client, #{
                source => #{path => list_to_binary(Source)},
                breakpoints => [#{line => 4}]
            })
        ),
        #{success := true} = edb_dap_test_client:configuration_done(Client),
        {ok, Thread, [#{id := Frame, name := ~"EdbLaunch.go/1", line := 4} | _]} =
            edb_dap_test_support:wait_for_bp(Client),
        ?assertMatch(
            #{success := true, body := #{result := ~"5"}},
            edb_dap_test_client:evaluate(Client, #{frameId => Frame, expression => ~"x + y"})
        ),
        #{success := true} = edb_dap_test_client:continue(Client, #{threadId => Thread})
    after
        edb_dap_test_client:disconnect(Client, #{terminateDebuggee => true})
    end.

assert_expandable_expression(Client, Frame) ->
    #{success := true, body := #{variablesReference := MapRef}} =
        edb_dap_test_client:evaluate(Client, #{
            frameId => Frame,
            expression => ~"%{\"lists:nth(\" => [[x, y]]}"
        }),
    MapVars = edb_dap_test_support:get_variables(Client, MapRef),
    [#{variablesReference := ListRef, evaluateName := ListExpression}] = maps:values(MapVars),
    ?assertMatch(
        #{success := true, body := #{result := ~"[[2, 3]]"}},
        edb_dap_test_client:evaluate(Client, #{frameId => Frame, expression => ListExpression})
    ),
    #{~"1" := #{evaluateName := ElementExpression}} = edb_dap_test_support:get_variables(Client, ListRef),
    ?assertMatch(
        #{success := true, body := #{result := ~"[2, 3]"}},
        edb_dap_test_client:evaluate(Client, #{frameId => Frame, expression => ElementExpression})
    ).

test_mix_exunit_launch(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    Project = filename:join(PrivDir, "mix_exunit_project"),
    ok = filelib:ensure_dir(filename:join([Project, "test", "example_test.exs"])),
    TaskSource = proplists:get_value(source, 'Elixir.Mix.Tasks.Compile.Edb':module_info(compile)),
    PackagePath = lists:foldl(fun(_, Path) -> filename:dirname(Path) end, TaskSource, lists:seq(1, 4)),
    ok = file:write_file(
        filename:join(Project, "mix.exs"),
        io_lib:format(
            "defmodule EdbExUnit.MixProject do\n use Mix.Project\n def project, do: [app: :edb_exunit, version: \"0.1.0\", deps: [{:edb_mix, path: ~p, runtime: false}]]\nend\n",
            [PackagePath]
        )
    ),
    ok = file:write_file(
        filename:join([Project, "test", "test_helper.exs"]),
        ~"File.write!(\"helper_calls\", \"called\n\", [:append])\nExUnit.start()\n"
    ),
    Source = filename:join([Project, "test", "example_test.exs"]),
    ok = file:write_file(
        Source,
        ~"defmodule EdbRuntimeTest do\n use ExUnit.Case, async: true\n setup do\n  value = 40\n  {:ok, value: value}\n end\n test \"selected\", %{value: value} do\n  answer = value + 2\n  assert answer == 42\n end\n test \"excluded\" do\n  flunk(\"line selection was lost\")\n end\nend\ndefmodule EdbOtherRuntimeTest do\n use ExUnit.Case, async: true\n test \"also excluded\", do: flunk(\"other module ran\")\nend\n"
    ),
    {ok, Client} = launch_exunit(Config, Project, "test/example_test.exs:7"),
    try
        ?assertMatch(
            #{success := true, body := #{breakpoints := [#{verified := true}, #{verified := true}]}},
            edb_dap_test_client:set_breakpoints(Client, #{
                source => #{path => list_to_binary(Source)},
                breakpoints => [#{line => 4}, #{line => 8}]
            })
        ),
        #{success := true} = edb_dap_test_client:configuration_done(Client),
        {ok, Thread, [#{line := 4} | _]} = edb_dap_test_support:wait_for_bp(Client),
        #{success := true} = edb_dap_test_client:continue(Client, #{threadId => Thread}),
        {ok, Thread2, [#{id := Frame, name := ~"EdbRuntimeTest.test selected/1", line := 8} | _]} =
            edb_dap_test_support:wait_for_bp(Client),
        #{success := true, body := #{threads := Threads}} = edb_dap_test_client:threads(Client),
        [ThreadName] = [Name || #{id := Id, name := Name} <- Threads, Id =:= Thread2],
        ?assertNotEqual(nomatch, binary:match(ThreadName, ~"EdbRuntimeTest: test selected")),
        ?assertMatch(
            #{success := true, body := #{result := ~"42"}},
            edb_dap_test_client:evaluate(Client, #{frameId => Frame, expression => ~"value + 2"})
        ),
        #{success := true} = edb_dap_test_client:next(Client, #{threadId => Thread2}),
        {ok, Thread2, [#{id := Frame2, line := 9} | _]} = wait_for_step(Client),
        ?assertMatch(
            #{success := true, body := #{result := ~"42"}},
            edb_dap_test_client:evaluate(Client, #{frameId => Frame2, expression => ~"answer"})
        ),
        #{success := true} = edb_dap_test_client:continue(Client, #{threadId => Thread2}),
        {ok, [#{body := #{exitCode := 0}}]} = edb_dap_test_client:wait_for_event(~"exited", Client),
        ?assertEqual({ok, ~"called\n"}, file:read_file(filename:join(Project, "helper_calls")))
    after
        edb_dap_test_client:disconnect(Client, #{terminateDebuggee => true})
    end,
    % The same entry point must retain Mix's failing-test exit status.
    {ok, FailedClient} = launch_exunit(Config, Project, "test/example_test.exs:11"),
    try
        #{success := true} = edb_dap_test_client:configuration_done(FailedClient),
        {ok, [#{body := #{exitCode := 2}}]} = edb_dap_test_client:wait_for_event(~"exited", FailedClient)
    after
        edb_dap_test_client:disconnect(FailedClient, #{terminateDebuggee => true})
    end.

launch_exunit(Config, Project, Selection) ->
    {ok, Client} = edb_dap_test_support:start_test_client(Config),
    #{success := true} = edb_dap_test_client:initialize(Client, #{adapterID => ~"edb-exunit-test"}),
    TaskDir = filename:dirname(code:which('Elixir.Mix.Tasks.Compile.Edb')),
    #{success := true} = edb_dap_test_client:launch(Client, #{
        run => #{
            cwd => list_to_binary(Project),
            args => [
                list_to_binary(os:find_executable("elixir")),
                ~"-pa",
                list_to_binary(TaskDir),
                ~"-S",
                ~"mix",
                ~"edb.test",
                list_to_binary(Selection),
                ~"--seed",
                ~"0",
                ~"--exit-status",
                ~"2"
            ],
            env => #{~"MIX_ENV" => ~"test"}
        },
        config => #{
            nameDomain => shortnames,
            language => elixir,
            nodeInitCodeInEnvVar => ~"EDB_DAP_DEBUGGEE_INIT",
            timeout => 30
        }
    }),
    {ok, [_]} = edb_dap_test_client:wait_for_event(~"initialized", Client),
    {ok, Client}.
