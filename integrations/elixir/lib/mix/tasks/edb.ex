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
