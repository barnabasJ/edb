# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
defmodule Edb.CompilerTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup do
    options = Code.compiler_options(debug_info: true, docs: true)
    on_exit(fn -> Code.compiler_options(options) end)
  end

  test "instruments real Elixir code while retaining Elixir metadata", %{tmp_dir: dir} do
    source = Path.join(dir, "fixture.ex")

    File.write!(source, """
    defmodule Edb.CompilerFixture do
      @moduledoc "Fixture documentation"
      def go(x) do
        y = x + 1
        IO.inspect(y)
        y * 2
      end
    end
    """)

    [{module, binary}] = Code.compile_file(source)
    path = Path.join(dir, "#{module}.beam")
    File.write!(path, binary)
    assert :ok == Mix.Tasks.Compile.Edb.instrument(path)
    assert :noop == Mix.Tasks.Compile.Edb.instrument(path)
    assert [{4, _}, {5, _}, {6, _}] = :code.get_debug_info(module)

    assert {:docs_v1, _, :elixir, _, %{"en" => "Fixture documentation"}, _, _} =
             Code.fetch_docs(path)

    assert apply(module, :go, [2]) == 6

    assert {:ok, {^module, [debug_info: {:debug_info_v1, :elixir_erl, _}]}} =
             :beam_lib.chunks(String.to_charlist(path), [:debug_info])

    assert {:ok, {^module, [abstract_code: {:raw_abstract_v1, [_ | _]}]}} =
             :beam_lib.chunks(String.to_charlist(path), [:abstract_code])
  end

  test "reports modules compiled without debug information", %{tmp_dir: dir} do
    [{module, binary}] =
      Code.compile_string(
        """
        defmodule Edb.NoDebugFixture do
          @compile {:debug_info, false}
          def go, do: :ok
        end
        """,
        Path.join(dir, "no_debug.ex")
      )

    path = Path.join(dir, "#{module}.beam")
    File.write!(path, binary)
    assert_raise Mix.Error, ~r/no debug info/, fn -> Mix.Tasks.Compile.Edb.instrument(path) end
  end

  test "compiler discovers Elixir by backend and leaves Erlang modules intact", %{tmp_dir: dir} do
    in_project(dir, fn compile_path ->
      modules =
        Code.compile_string("""
        defmodule :edb_atom_fixture do
          def value(x), do: x + 1
        end
        defmodule Edb.DiscoveryFixture do
          def value(x), do: x + 2
        end
        """)

      for {module, binary} <- modules do
        on_exit(fn -> unload(module) end)
        File.write!(Path.join(compile_path, "#{module}.beam"), binary)
      end

      erlang_modules =
        for module <- [:edb_erlang_fixture, Edb.ErlangFixture] do
          source = Path.join(dir, "#{module}.erl")

          File.write!(source, """
          -module('#{module}').
          -export([value/1]).
          value(X) -> X + 3.
          """)

          {:ok, ^module, binary} =
            :compile.file(String.to_charlist(source), [:binary, :debug_info])

          path = Path.join(compile_path, "#{module}.beam")
          File.write!(path, binary)
          {path, binary}
        end

      assert {:ok, []} == Mix.Tasks.Compile.Edb.run([])

      for {module, _} <- modules do
        assert [_ | _] = :code.get_debug_info(module)
        assert apply(module, :value, [1]) in [2, 3]
      end

      for {path, binary} <- erlang_modules, do: assert(File.read!(path) == binary)
      assert {:noop, []} == Mix.Tasks.Compile.Edb.run([])
    end)
  end

  test "compiler reports namespaced Elixir modules without debug information", %{tmp_dir: dir} do
    in_project(dir, fn compile_path ->
      [{module, binary}] =
        Code.compile_string("""
        defmodule Edb.DiscoveryNoDebugFixture do
          @compile {:debug_info, false}
          def value, do: :ok
        end
        """)

      on_exit(fn -> unload(module) end)
      File.write!(Path.join(compile_path, "#{module}.beam"), binary)
      assert_raise Mix.Error, ~r/no debug info/, fn -> Mix.Tasks.Compile.Edb.run([]) end
    end)
  end

  test "instrumentation does not rerun on_load and takes effect on the next load", %{tmp_dir: dir} do
    calls = Path.join(dir, "on_load_calls")

    [{module, binary}] =
      Code.compile_string("""
      defmodule Edb.OnLoadFixture do
        @on_load :initialize
        def initialize, do: File.write!(#{inspect(calls)}, "loaded\n", [:append])
        def value, do: 42
      end
      """)

    on_exit(fn -> unload(module) end)
    original_md5 = module.module_info(:md5)
    path = Path.join(dir, "#{module}.beam")
    File.write!(path, binary)

    assert :ok == Mix.Tasks.Compile.Edb.instrument(path)
    assert File.read!(calls) == "loaded\n"
    assert module.module_info(:md5) == original_md5
    assert apply(module, :value, []) == 42
    assert :noop == Mix.Tasks.Compile.Edb.instrument(path)

    unload(module)
    assert {:module, ^module} = :code.load_abs(String.to_charlist(Path.rootname(path)))
    assert File.read!(calls) == "loaded\nloaded\n"
    assert module.module_info(:md5) != original_md5
    assert [_ | _] = :code.get_debug_info(module)
    assert apply(module, :value, []) == 42
  end

  test "instrumentation preserves a loaded NIF without an upgrade callback", %{tmp_dir: dir} do
    nif_path = Path.join(dir, "fixture_nif")
    source = nif_path <> ".c"

    File.write!(source, """
    #include "erl_nif.h"
    static ERL_NIF_TERM value(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
      return enif_make_int(env, 42);
    }
    static ErlNifFunc functions[] = {{"value", 0, value, 0}};
    ERL_NIF_INIT(Elixir.Edb.NifFixture, functions, NULL, NULL, NULL, NULL)
    """)

    include = Path.join([List.to_string(:code.root_dir()), "usr", "include"])

    platform_flags =
      if match?({:unix, :darwin}, :os.type()), do: ["-undefined", "dynamic_lookup"], else: []

    {output, status} =
      System.cmd(
        "cc",
        ["-shared", "-fPIC", "-I", include, "-o", nif_path <> ".so", source] ++ platform_flags,
        stderr_to_stdout: true
      )

    assert status == 0, output

    [{module, binary}] =
      Code.compile_string("""
      defmodule Edb.NifFixture do
        @on_load :initialize
        def initialize, do: :erlang.load_nif(#{inspect(String.to_charlist(nif_path))}, 0)
        def value, do: :erlang.nif_error(:not_loaded)
      end
      """)

    on_exit(fn -> unload(module) end)
    assert apply(module, :value, []) == 42
    original_md5 = module.module_info(:md5)
    path = Path.join(dir, "#{module}.beam")
    File.write!(path, binary)

    assert :ok == Mix.Tasks.Compile.Edb.instrument(path)
    assert module.module_info(:md5) == original_md5
    assert apply(module, :value, []) == 42

    unload(module)
    assert {:module, ^module} = :code.load_abs(String.to_charlist(Path.rootname(path)))
    assert [_ | _] = :code.get_debug_info(module)
    assert apply(module, :value, []) == 42
  end

  test "pipeline instrumentation preserves effects, branches, guards and tail calls", %{
    tmp_dir: dir
  } do
    source = """
    defmodule Edb.PipelineSemantics do
      def run(enabled) do
        Process.put(:edb_pipeline_events, [])
        result = if enabled do
          0
          |> stage(:first)
          |> stage(argument())
          |> stage(:third)
        else
          :untouched
        end
        {result, Process.get(:edb_pipeline_events)}
      end
      def fail do
        Process.put(:edb_pipeline_events, [])
        0
        |> stage(:first)
        |> raise_stage()
        |> stage(:unreachable)
      end
      def guarded(x) when x |> abs() |> is_integer(), do: x
      def loop(0), do: :done
      def loop(x) do
        x
        |> decrement()
        |> loop()
      end
      defp decrement(x), do: x - 1
      defp stage(value, tag) do
        Process.put(:edb_pipeline_events, Process.get(:edb_pipeline_events) ++ [tag])
        value + 1
      end
      defp argument do
        Process.put(:edb_pipeline_events, Process.get(:edb_pipeline_events) ++ [:argument])
        :second
      end
      defp raise_stage(value) do
        if value > 0, do: raise("pipeline failure"), else: value
      end
    end
    """

    [{module, binary}] = Code.compile_string(source, Path.join(dir, "pipeline.ex"))
    path = Path.join(dir, "#{module}.beam")
    File.write!(path, binary)
    before = apply(module, :run, [true])
    assert before == {3, [:first, :argument, :second, :third]}
    assert :ok == Mix.Tasks.Compile.Edb.instrument(path)
    assert apply(module, :run, [true]) == before
    assert apply(module, :run, [false]) == {:untouched, []}
    assert apply(module, :guarded, [-3]) == -3
    assert apply(module, :loop, [100_000]) == :done
    assert_raise RuntimeError, "pipeline failure", fn -> apply(module, :fail, []) end
    assert Process.get(:edb_pipeline_events) == [:first]

    {:beam_file, _, _, _, _, functions} = :beam_disasm.file(String.to_charlist(path))
    {:function, :loop, 1, _, instructions} = List.keyfind(functions, :loop, 1)
    assert Enum.any?(instructions, &match?({:call_last, 1, {^module, :loop, 1}, _}, &1))

    # Existing projects must upgrade instrumentation without a clean build.
    {:ok, ^module, chunks} = :beam_lib.all_chunks(String.to_charlist(path))

    {:ok, legacy} =
      :beam_lib.build_module(List.keyreplace(chunks, ~c"EdbI", 0, {~c"EdbI", <<1>>}))

    File.write!(path, legacy)
    assert :ok == Mix.Tasks.Compile.Edb.instrument(path)
    assert :noop == Mix.Tasks.Compile.Edb.instrument(path)
    assert apply(module, :run, [true]) == before
    Process.delete(:edb_pipeline_events)
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp in_project(dir, fun) do
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule CompilerFixture.MixProject do
      use Mix.Project
      def project, do: [app: :edb_compiler_fixture, version: "0.1.0"]
    end
    """)

    previous = System.get_env("MIX_BUILD_PATH")
    System.put_env("MIX_BUILD_PATH", Path.join(dir, "_build"))

    try do
      Mix.Project.in_project(:edb_compiler_fixture, dir, fn _ ->
        path = Mix.Project.compile_path()
        File.mkdir_p!(path)
        fun.(path)
      end)
    after
      if previous,
        do: System.put_env("MIX_BUILD_PATH", previous),
        else: System.delete_env("MIX_BUILD_PATH")
    end
  end
end
