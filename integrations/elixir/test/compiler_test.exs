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

  setup do
    options = Code.compiler_options(debug_info: true, docs: true)
    on_exit(fn -> Code.compiler_options(options) end)
    dir = Path.join(System.tmp_dir!(), "edb-mix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "instruments real Elixir code while retaining Elixir metadata", %{dir: dir} do
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

  test "reports modules compiled without debug information", %{dir: dir} do
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

  test "pipeline instrumentation preserves effects, branches, guards and tail calls", %{dir: dir} do
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
end
