defmodule Mix.Tasks.Edb.Test do
  use Mix.Task

  @shortdoc "Runs ExUnit tests with edb breakpoints in test bodies"
  @moduledoc """
  Launch `mix edb.test [files/directories[:line]] [options]` through edb's DAP
  adapter with MIX_ENV=test and nodeInitCodeInEnvVar=EDB_DAP_DEBUGGEE_INIT.

  The selected test files are required and instrumented before connecting to
  the debugger. Test helpers and top-level file code execute during this phase;
  test bodies and setup callbacks execute after breakpoints have been installed.
  The actual test run is delegated to `mix test`, preserving its filtering and
  failure exit status. Test timeouts default to infinity during debugging.
  """

  @switches [
    seed: :integer,
    trace: :boolean,
    max_cases: :integer,
    max_failures: :integer,
    max_requires: :integer,
    timeout: :integer,
    include: :keep,
    exclude: :keep,
    only: :keep,
    name_pattern: :regex,
    formatter: :keep,
    color: :boolean,
    compile: :boolean,
    start: :boolean,
    force: :boolean,
    deps_check: :boolean,
    archives_check: :boolean,
    elixir_version_check: :boolean,
    all_warnings: :boolean,
    warnings_as_errors: :boolean,
    raise: :boolean,
    exit_status: :integer,
    slowest: :integer,
    slowest_modules: :integer,
    preload_modules: :boolean,
    repeat_until_failure: :integer,
    dry_run: :boolean
  ]

  @impl true
  def run(args) do
    if Mix.env() != :test, do: Mix.raise("Run edb.test with MIX_ENV=test")
    if Mix.Project.umbrella?(), do: Mix.raise("Run edb.test from an umbrella child application")

    if is_nil(System.get_env("EDB_DAP_DEBUGGEE_INIT")),
      do: Mix.raise("Launch edb.test through edb with nodeInitCodeInEnvVar=EDB_DAP_DEBUGGEE_INIT")

    {opts, paths} = OptionParser.parse!(args, strict: @switches, aliases: [n: :name_pattern])
    Application.ensure_loaded(:ex_unit)
    Mix.Task.run("app.start", args)
    ExUnit.start(autorun: false)
    ExUnit.configure(Keyword.take(opts, [:seed, :trace, :max_cases, :max_failures, :timeout]))

    directory =
      Path.join(
        System.tmp_dir!(),
        "edb-tests-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    Code.prepend_path(directory)

    try do
      prepare(paths, opts, directory)
      ExUnit.configure(timeout: opts[:timeout] || :infinity)
      Mix.Tasks.Edb.connect()
      Mix.Task.run("test", args)
    after
      Code.delete_path(directory)
      File.rm_rf!(directory)
    end
  end

  defp prepare(paths, opts, directory) do
    project = Mix.Project.config()
    test_paths = project[:test_paths] || ["test"]
    compiler_options = Keyword.merge(project[:test_elixirc_options] || [], debug_info: true)
    previous = Code.compiler_options(compiler_options)

    try do
      for path <- test_paths do
        helper = Path.join(path, "test_helper.exs")

        if File.regular?(helper) do
          {modules, diagnostics} =
            Code.with_diagnostics([log: true], fn -> Code.require_file(helper) end)

          check_warnings!(diagnostics, opts)

          for {module, binary} <- modules || [] do
            instrument(module, binary, directory)
          end
        end
      end

      files = selected_files(paths, test_paths, project)

      options = [
        return_diagnostics: true,
        each_module: fn _file, module, binary -> instrument(module, binary, directory) end
      ]

      options =
        if opts[:max_requires],
          do: Keyword.put(options, :max_concurrency, opts[:max_requires]),
          else: options

      case Kernel.ParallelCompiler.require(files, options) do
        {:ok, _, info} -> check_warnings!(info.compile_warnings ++ info.runtime_warnings, opts)
        {:error, errors, _} -> Mix.raise("Could not load tests for edb: #{inspect(errors)}")
      end
    after
      Code.compiler_options(previous)
    end
  end

  defp check_warnings!(warnings, opts) do
    if opts[:warnings_as_errors] && warnings != [],
      do: Mix.raise("Test preparation produced warnings with --warnings-as-errors")

    :ok
  end

  defp selected_files(paths, test_paths, project) do
    {paths, _filters} = ExUnit.Filters.parse_paths(paths)
    paths = if paths == [], do: test_paths, else: paths
    pattern = project[:test_pattern] || "*.{ex,exs}"
    filters = project[:test_load_filters] || [&String.ends_with?(&1, "_test.exs")]

    paths
    |> Enum.flat_map(fn path ->
      if File.dir?(path) do
        Path.wildcard(Path.join([path, "**", pattern]))
        |> Enum.filter(fn file -> Enum.any?(filters, &matches?(&1, file)) end)
      else
        if File.regular?(path), do: [path], else: []
      end
    end)
    |> Enum.uniq()
  end

  defp matches?(%Regex{} = regex, file), do: Regex.match?(regex, file)
  defp matches?(filter, file) when is_function(filter, 1), do: filter.(file)
  defp matches?(path, file) when is_binary(path), do: path == file

  defp instrument(module, binary, directory) do
    path = Path.join(directory, "#{module}.beam")
    File.write!(path, binary)
    Mix.Tasks.Compile.Edb.instrument(path)
  end
end
