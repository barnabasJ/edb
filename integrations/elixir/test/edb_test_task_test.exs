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
defmodule Edb.TestTaskTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "test"))

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
    :ok
  end

  test "clean tests pass warnings-as-errors without a parallel compiler deprecation", %{
    tmp_dir: dir
  } do
    {output, status} = run_fixture(dir, "assert true")
    assert status == 0, output
    refute output =~ "you must pass return_diagnostics"
    assert output =~ "Running ExUnit"
  end

  test "compile warnings still fail preparation with warnings-as-errors", %{tmp_dir: dir} do
    {output, status} = run_fixture(dir, "unused_value = 1\nassert true")
    assert status != 0
    assert output =~ "unused_value"
    assert output =~ "Test preparation produced warnings with --warnings-as-errors"
    refute output =~ "you must pass return_diagnostics"
  end

  test "application warnings are allowed on cold builds like mix test", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "lib/example.ex"), """
    defmodule Fixture.ApplicationWarning do
      def value do
        unused_application_value = 1
        :ok
      end
    end
    """)

    for task <- ["test", "edb.test"] do
      {output, status} = run_fixture(dir, "assert true", "", [], task)
      assert output =~ "unused_application_value"
      assert status == 0, output
      assert output =~ "Result: 1 passed"
    end
  end

  test "runtime warnings still fail preparation with warnings-as-errors", %{tmp_dir: dir} do
    {output, status} = run_fixture(dir, "assert true", "IO.warn(\"fixture runtime warning\")")
    assert status != 0
    assert output =~ "fixture runtime warning"
    assert output =~ "Test preparation produced warnings with --warnings-as-errors"
    refute output =~ "you must pass return_diagnostics"
  end

  test "CLI filters are configured before loading helpers and test files", %{tmp_dir: dir} do
    for {flag, key} <- [{"--include", :include}, {"--exclude", :exclude}, {"--only", :include}] do
      check = """
      unless :integration in ExUnit.configuration()[#{inspect(key)}] do
        raise "#{flag} was configured too late"
      end
      """

      File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start()\n" <> check)
      {output, status} = run_fixture(dir, "assert true", check, [flag, "integration"])
      assert status == 0, output
    end
  end

  test "CLI options win over helper configuration before test files load", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "test/test_helper.exs"), """
    ExUnit.start(include: [:from_helper], exclude: [:helper_excluded], seed: 99)
    """)

    check = """
    config = ExUnit.configuration()
    unless :integration in config[:include] and config[:seed] == 42 do
      raise "helper overrode CLI configuration"
    end
    unless :helper_excluded in config[:exclude] and :cli_excluded in config[:exclude] do
      raise "helper and CLI excludes must be combined"
    end
    """

    {output, status} =
      run_fixture(dir, "assert true", check, [
        "--include",
        "integration",
        "--exclude",
        "cli_excluded",
        "--seed",
        "42"
      ])

    assert status == 0, output
  end

  test "helper excludes still prevent tests from running", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start(exclude: [:integration])\n")

    {output, status} =
      run_fixture(dir, "flunk(\"helper exclude was lost\")", "", ["--seed", "42"])

    assert status == 0, output
    assert output =~ "excluded"
  end

  defp run_fixture(dir, body, top_level \\ "", args \\ [], task \\ "edb.test") do
    File.write!(Path.join(dir, "test/example_test.exs"), """
    #{top_level}
    defmodule FixtureTest do
      use ExUnit.Case
      @tag :integration
      test "works" do
        #{body}
      end
    end
    """)

    options = [
      cd: dir,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "test"},
        {"MIX_BUILD_PATH", Path.join([dir, "_build", task])},
        {"EDB_DAP_DEBUGGEE_INIT", "ok"}
      ]
    ]

    mix = System.find_executable("mix")
    {compile_output, status} = System.cmd(mix, ["deps.compile"], options)
    assert status == 0, compile_output
    System.cmd(mix, [task, "--warnings-as-errors" | args], options)
  end
end
