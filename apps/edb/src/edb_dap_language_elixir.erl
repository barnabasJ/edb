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

%%% % @format

-module(edb_dap_language_elixir).
-oncall("whatsapp_server_devx").
-moduledoc "Elixir source lookup and presentation for the DAP adapter.".
-behaviour(edb_dap_language).
%% Elixir is supplied by the debuggee, not a dependency of the adapter.
-ignore_xref([{'Elixir.Code', eval_string, 3}, {'Elixir.Kernel', inspect, 2}]).
-export([init/0, source_to_modules/3]).
-export([find_modules/1, variable_name/1, visible_variables/1, evaluate/2, inspect/2, format_mfa/1]).

-spec init() -> #{}.
init() -> #{}.

-spec source_to_modules(binary(), [edb:line()], State) -> {ok, [module()], State} | {error, binary(), State}.
source_to_modules(Path, _Lines, State) ->
    case edb:eval(#{function => fun() -> find_modules(Path) end, timeout => 4000}) of
        {ok, Modules} -> {ok, Modules, State};
        {eval_error, _} -> {error, ~"Could not look up Elixir source modules on the debuggee", State}
    end.

%% Run on the debuggee: include BEAM files that Mix has not loaded yet, and
%% inspect metadata without loading modules or executing their on_load hooks.
-spec find_modules(binary()) -> [module()].
find_modules(Path) ->
    Target = filename:absname(Path),
    Loaded = maps:from_list(code:all_loaded()),
    FromLoaded = [M || M := _ <- Loaded, loaded_source(M) =:= Target],
    FromDisk = [
        M
     || {Name, BeamPath, false} <- code:all_available(),
        is_list(BeamPath),
        filename:extension(BeamPath) =:= ".beam",
        {ok, {M, [{compile_info, Info}]}} <- [beam_lib:chunks(BeamPath, [compile_info])],
        not maps:is_key(M, Loaded),
        source_path(Info) =:= Target,
        is_list(Name)
    ],
    lists:usort(FromLoaded ++ FromDisk).

-spec loaded_source(module()) -> binary() | undefined.
loaded_source(Module) ->
    try
        source_path(Module:module_info(compile))
    catch
        _:_ -> undefined
    end.

-spec source_path(list()) -> binary() | undefined.
source_path(Info) ->
    case proplists:get_value(source, Info) of
        undefined -> undefined;
        Source -> filename:absname(unicode:characters_to_binary(Source))
    end.

%% Elixir's Erlang forms use _name@version. Keep the most recent binding,
%% excluding compiler temporaries and hygienic macro variables (_@N).
-spec variable_name(binary()) -> binary().
variable_name(Name) ->
    case re:run(Name, ~"^_(.+)@([0-9]+)$", [{capture, [1], binary}]) of
        {match, [UserName]} -> UserName;
        nomatch -> Name
    end.

-spec visible_variables(map()) -> [{binary(), binary(), edb:value()}].
visible_variables(Vars) ->
    Latest = lists:foldl(
        fun({Raw, Value}, Acc) ->
            case re:run(Raw, ~"^_([^@]+)@([0-9]+)$", [{capture, [1, 2], binary}]) of
                {match, [Name, VersionBin]} ->
                    Version = binary_to_integer(VersionBin),
                    case maps:get(Name, Acc, undefined) of
                        {OldVersion, _, _} when OldVersion >= Version -> Acc;
                        _ -> Acc#{Name => {Version, Raw, Value}}
                    end;
                nomatch ->
                    Acc
            end
        end,
        #{},
        maps:to_list(Vars)
    ),
    [{Name, Raw, Value} || Name := {_, Raw, Value} <- Latest].

-spec evaluate(binary(), edb:stack_frame_vars()) -> term().
evaluate(Expression, FrameVars) ->
    Bindings = [
        {binary_to_atom(Name), Value}
     || {Name, _, {value, Value}} <- visible_variables(maps:get(vars, FrameVars, #{}))
    ],
    {Result, _} = 'Elixir.Code':eval_string(Expression, Bindings, []),
    Result.

-spec inspect(term(), pos_integer() | infinity) -> binary().
inspect(Value, Limit) ->
    PrintableLimit =
        case Limit of
            infinity -> infinity;
            _ -> 4096
        end,
    'Elixir.Kernel':inspect(Value, [{limit, Limit}, {printable_limit, PrintableLimit}, {safe, true}]).

-spec format_mfa(mfa()) -> binary().
format_mfa({Module, Function, Arity}) ->
    case atom_to_binary(Module) of
        <<"Elixir.", Name/binary>> ->
            iolist_to_binary([Name, ~".", atom_to_binary(Function), ~"/", integer_to_binary(Arity)]);
        _ ->
            unicode:characters_to_binary(io_lib:format("~p:~p/~p", [Module, Function, Arity]))
    end.
