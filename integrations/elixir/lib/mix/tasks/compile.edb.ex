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
defmodule Mix.Tasks.Compile.Edb do
  use Mix.Task.Compiler

  @instrumentation_version <<2>>

  @shortdoc "Adds edb breakpoint and variable instrumentation to Elixir modules"
  @moduledoc """
  Add `:edb` after `:elixir` in your project's `:compilers` in development/test.
  Requires OTP 29 or later and Elixir debug information. Run `mix compile --force`
  after enabling or disabling this compiler.
  """

  @impl true
  def run(_args) do
    if String.to_integer(System.otp_release()) < 29 do
      Mix.raise("The edb compiler requires Erlang/OTP 29 or later")
    end

    results =
      Mix.Project.compile_path()
      |> Path.join("Elixir.*.beam")
      |> Path.wildcard()
      |> Enum.map(&instrument/1)

    if :ok in results, do: {:ok, []}, else: {:noop, []}
  end

  @doc false
  def instrument(path) do
    {:ok, module, chunks} = :beam_lib.all_chunks(String.to_charlist(path))

    # The custom marker avoids rebuilding unchanged modules on every Mix run.
    if List.keyfind(chunks, ~c"EdbI", 0) == {~c"EdbI", @instrumentation_version} do
      :noop
    else
      compile(path, module, chunks)
    end
  end

  defp compile(path, module, chunks) do
    {:ok,
     {^module,
      [
        abstract_code: {:raw_abstract_v1, forms},
        compile_info: info,
        debug_info: {:debug_info_v1, backend, data}
      ]}} =
      case :beam_lib.chunks(String.to_charlist(path), [:abstract_code, :compile_info, :debug_info]) do
        {:ok, {_, [{:abstract_code, :no_abstract_code} | _]}} ->
          Mix.raise("#{path} has no debug info; enable elixirc_options: [debug_info: true]")

        result ->
          result
      end

    # Retain Elixir's documentation and checker chunks, and its original debug
    # backend so Code.fetch_docs and other Elixir tools continue to work.
    extras =
      for {name, value} <- chunks, name in [~c"Docs", ~c"ExCk"], do: {List.to_string(name), value}

    opts = Keyword.get(info, :options, []) -- [:from_core, :no_core_prepare]

    opts = [
      :binary,
      :return_errors,
      :return_warnings,
      :beam_debug_info,
      :beam_debug_stack,
      {:source, Keyword.fetch!(info, :source)},
      {:debug_info, {backend, data}},
      :debug_info,
      {:extra_chunks, [{"EdbI", @instrumentation_version} | extras]}
      | opts
    ]

    case :compile.forms(Edb.PipelineSteps.rewrite(forms), opts) do
      {:ok, ^module, binary, _warnings} ->
        File.write!(path, binary)
        # Mix may have already loaded the module during compilation. Reloading
        # on_load modules repeats initialization and can fail for NIF libraries
        # without an upgrade callback. Leave their current code intact; the
        # instrumented BEAM takes effect on the next ordinary load.
        on_load? = Enum.any?(forms, &match?({:attribute, _, :on_load, _}, &1))

        if :code.is_loaded(module) != false and not on_load? do
          unless :code.soft_purge(module), do: Mix.raise("Old code for #{module} is still in use")
          {:module, ^module} = :code.load_binary(module, String.to_charlist(path), binary)
        end

        :ok

      {:error, errors, warnings} ->
        Mix.raise("edb instrumentation failed for #{path}: #{inspect({errors, warnings})}")
    end
  end
end
