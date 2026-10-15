defmodule Edb.TestTaskTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "edb-task-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "test"))
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Fixture.MixProject do
      use Mix.Project
      def project do
        [app: :edb_task_fixture, version: "0.1.0",
         deps: [{:edb_mix, path: #{inspect(Path.expand("..", __DIR__))}, runtime: false}]]
      end
    end
    """)

    File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start()\n")
    %{dir: dir}
  end

  test "clean tests pass warnings-as-errors without a parallel compiler deprecation", %{dir: dir} do
    {output, status} = run_fixture(dir, "assert true")
    assert status == 0, output
    refute output =~ "you must pass return_diagnostics"
    assert output =~ "Running ExUnit"
  end

  test "compile warnings still fail preparation with warnings-as-errors", %{dir: dir} do
    {output, status} = run_fixture(dir, "unused_value = 1\nassert true")
    assert status != 0
    assert output =~ "unused_value"
    assert output =~ "Test preparation produced warnings with --warnings-as-errors"
    refute output =~ "you must pass return_diagnostics"
  end

  test "runtime warnings still fail preparation with warnings-as-errors", %{dir: dir} do
    {output, status} = run_fixture(dir, "assert true", "IO.warn(\"fixture runtime warning\")")
    assert status != 0
    assert output =~ "fixture runtime warning"
    assert output =~ "Test preparation produced warnings with --warnings-as-errors"
    refute output =~ "you must pass return_diagnostics"
  end

  defp run_fixture(dir, body, top_level \\ "") do
    File.write!(Path.join(dir, "test/example_test.exs"), """
    #{top_level}
    defmodule FixtureTest do
      use ExUnit.Case
      test "works" do
        #{body}
      end
    end
    """)

    options = [
      cd: dir,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "test"}, {"EDB_DAP_DEBUGGEE_INIT", "ok"}]
    ]

    mix = System.find_executable("mix")
    {compile_output, status} = System.cmd(mix, ["deps.compile"], options)
    assert status == 0, compile_output
    System.cmd(mix, ["edb.test", "--warnings-as-errors"], options)
  end
end
