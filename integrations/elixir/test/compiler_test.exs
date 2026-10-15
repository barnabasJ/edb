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
end
