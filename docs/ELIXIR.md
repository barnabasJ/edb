# Debugging Elixir with edb

The Elixir integration supports source and function breakpoints, pause/continue,
step into/over/out, stack traces, local variables, expandable values, process
inspection, and Elixir expression evaluation through the existing DAP adapter.
Use Erlang/OTP 29 or later and Elixir 1.18 or later; the integration is tested with
OTP 29.1 and Elixir 1.20.4.

## Prepare a Mix project

Add the local integration package to your project's dependencies (replace the
path with your edb checkout):

```elixir
defp deps do
  [
    {:edb_mix, path: "/path/to/edb/integrations/elixir", only: [:dev, :test], runtime: false}
  ]
end
```

Add the compiler after Elixir's compiler in `project/0`:

```elixir
compilers: Mix.compilers() ++ if(Mix.env() in [:dev, :test], do: [:edb], else: []),
elixirc_options: [debug_info: true]
```

Run `mix deps.get` and `mix compile --force`. Recompile with `--force` again if
you disable the integration so the instrumentation is removed. Configure this
compiler in each umbrella child or dependency whose code you want to debug.

Elixir normally compiles through Core Erlang, bypassing the pass that inserts
edb's executable breakpoint locations. The `:edb` compiler rebuilds the stored
Erlang forms with `beam_debug_info` and `beam_debug_stack`. It retains Elixir's
debug metadata, documentation and checker information. Unchanged BEAM files
are skipped on later compilations. Instrumentation increases stack usage; keep
it in development and test builds.

## Launch from an IDE

Configure your DAP client to start the edb executable with argument `dap`.
For VS Code with the Erlang Language Platform extension, add this to
`.vscode/launch.json`:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "erlang-edb",
      "request": "launch",
      "name": "Launch Mix application",
      "runInTerminal": {
        "kind": "integrated",
        "cwd": "${workspaceFolder}",
        "args": ["mix", "edb", "--no-halt"]
      },
      "config": {
        "language": "elixir",
        "nameDomain": "shortnames",
        "nodeInitCodeInEnvVar": "EDB_DAP_DEBUGGEE_INIT",
        "timeout": 300
      }
    }
  ]
}
```

`mix edb` compiles the project, connects to the debugger, and then forwards its
arguments to `mix run`. Application startup waits until the IDE has configured
breakpoints. For example, use `["mix", "edb", "-e", "MyApp.example()"]` to debug
an expression. Clients without terminal support can use `run` instead of
`runInTerminal`; see [the DAP guide](DAP.md).

## Attach to an existing node

Start the instrumented application with debugging and distribution enabled:

```sh
elixir --erl '+D' --sname myapp --cookie mycookie -S mix run --no-halt
```

Use the actual hostname reported by `Node.self()` in your attach configuration:

```json
{
  "type": "erlang-edb",
  "request": "attach",
  "name": "Attach to Mix application",
  "config": {
    "language": "elixir",
    "node": "myapp@hostname",
    "cookie": "mycookie",
    "cwd": "${workspaceFolder}"
  }
}
```

## Expressions and source files

Use `MyApp.Worker.run/1` or `&MyApp.Worker.run/1` for function breakpoints. Erlang
function notation remains accepted. Source lookup uses compiled source metadata,
so nested modules and multiple modules in one `.ex` or `.exs` file are supported,
including modules on the code path that have not yet been loaded. Files must be
compiled before setting breakpoints; top-level script expressions outside a
module are not instrumented by the Mix compiler.

ExUnit compiles `.exs` test files at runtime, after the Mix compiler has finished.
Those test modules are currently not instrumented, so breakpoints in test bodies
are not supported. You can debug compiled library code exercised by an existing
test by launching `mix edb -e 'Mix.Task.run("test", ["test/example_test.exs:42"])'`
with `MIX_ENV=test` through DAP.

Watch/REPL expressions use Elixir syntax and the selected frame's most recent
variable bindings. Compiler-generated temporaries are hidden. Values use Elixir's
`inspect` representation. Expressions run in a separate evaluator process, as in
Erlang sessions; `self()` refers to that process. Lexical aliases, imports, module
attributes and private functions from the original source scope are not restored;
use fully qualified public calls. Exceptions and unsupported DAP capabilities have
the same handling as Erlang sessions.

## Run integration tests

From `integrations/elixir`, run:

```sh
ELIXIR_ERL_OPTIONS='+D' mix test
```

From the repository root, add the Elixir installation and the built integration
package to Erlang's library path, then run the DAP suite:

```sh
export ERL_LIBS="$(elixir -e 'IO.write(Path.dirname(:code.lib_dir(:elixir)))'):$PWD/integrations/elixir/_build/test/lib"
rebar3 ct --suite apps/edb/test/edb_dap_elixir_SUITE
```
