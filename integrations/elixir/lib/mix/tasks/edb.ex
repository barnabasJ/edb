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
defmodule Mix.Tasks.Edb do
  use Mix.Task

  @shortdoc "Runs a Mix application under edb"
  @requirements ["compile"]
  @moduledoc """
  Run as `mix edb --no-halt` from an edb DAP launch configuration with
  `nodeInitCodeInEnvVar` set to `EDB_DAP_DEBUGGEE_INIT`. Compilation finishes
  before the debugger attaches; application startup waits for breakpoints.
  All arguments are forwarded to `mix run`.
  """

  @impl true
  def run(args) do
    connect()
    Mix.Task.run("run", args)
  end

  @doc false
  def connect do
    code = System.fetch_env!("EDB_DAP_DEBUGGEE_INIT")
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(code <> "."))
    {:ok, expressions} = :erl_parse.parse_exprs(tokens)
    :erl_eval.exprs(expressions, :erl_eval.new_bindings())
  end
end
