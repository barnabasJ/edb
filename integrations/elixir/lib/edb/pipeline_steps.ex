defmodule Edb.PipelineSteps do
  @moduledoc false

  # Elixir lowers a pipeline to nested first-argument calls. Erlang's initial
  # debug line then belongs to the outermost (last) call. Introduce bindings at
  # each stage so source stops and step-in targets follow evaluation order.
  def rewrite(forms) do
    used = variables(forms, MapSet.new())
    {forms, _state} = walk(forms, {0, used})
    forms
  end

  # Patterns and guards must retain their original grammar; blocks and new
  # bindings are only introduced into expression bodies.
  defp walk({:clause, anno, patterns, guards, body}, state) do
    {body, state} = walk(body, state)
    {{:clause, anno, patterns, guards, body}, state}
  end

  defp walk({:attribute, _, _, _} = attribute, state), do: {attribute, state}

  defp walk({:match, anno, pattern, expression}, state) do
    call? = match?({:call, _, _, _}, expression)
    {expression, state} = walk(expression, state)

    case expression do
      {:block, first_anno, steps} when call? ->
        {prefix, [last]} = Enum.split(steps, -1)
        # Bind the result after the last stage. Leaving the match outside the
        # block inserts a call-free stop before the first pipeline stage.
        last_anno = elem(last, 1)
        {{:block, first_anno, prefix ++ [{:match, last_anno, pattern, last}]}, state}

      _ ->
        {{:match, anno, pattern, expression}, state}
    end
  end

  defp walk({kind, anno, pattern, expression}, state)
       when kind in [
              :generate,
              :b_generate,
              :m_generate,
              :generate_strict,
              :b_generate_strict,
              :m_generate_strict
            ] do
    {expression, state} = walk(expression, state)
    {{kind, anno, pattern, expression}, state}
  end

  defp walk({:call, _, _, [_ | _]} = call, state) do
    {steps, call, state} = split(call, state)
    {steps, state} = walk(steps, state)
    {:call, anno, target, args} = call
    {args, state} = walk(args, state)
    {target, state} = walk(target, state)
    call = {:call, anno, target, args}

    case steps do
      [] -> {call, state}
      [{:match, first_anno, _, _} | _] -> {{:block, first_anno, steps ++ [call]}, state}
    end
  end

  defp walk(list, state) when is_list(list), do: Enum.map_reduce(list, state, &walk/2)

  defp walk(tuple, state) when is_tuple(tuple) do
    {items, state} = tuple |> Tuple.to_list() |> walk(state)
    {List.to_tuple(items), state}
  end

  defp walk(value, state), do: {value, state}

  defp split(
         {:call, anno, target, [{:call, inner_anno, inner_target, _} = inner | rest]} = call,
         state
       ) do
    if static_target?(target) and static_target?(inner_target) and
         :erl_anno.line(inner_anno) < :erl_anno.line(anno) and
         not :erl_anno.generated(anno) and not :erl_anno.generated(inner_anno) do
      {steps, inner, state} = split(inner, state)
      {name, state} = fresh_variable(state)
      variable = {:var, inner_anno, name}
      binding = {:match, inner_anno, variable, inner}
      {steps ++ [binding], {:call, anno, target, [variable | rest]}, state}
    else
      {[], call, state}
    end
  end

  defp split(call, state), do: {[], call, state}

  # Moving an argument ahead of a dynamic callee could change side effects.
  defp static_target?({:atom, _, _}), do: true
  defp static_target?({:remote, _, {:atom, _, _}, {:atom, _, _}}), do: true
  defp static_target?(_), do: false

  defp fresh_variable({counter, used}) do
    name = String.to_atom("_@edb_pipeline_#{counter}")

    if MapSet.member?(used, name) do
      fresh_variable({counter + 1, used})
    else
      {name, {counter + 1, MapSet.put(used, name)}}
    end
  end

  defp variables({:var, _, name}, used), do: MapSet.put(used, name)
  defp variables(list, used) when is_list(list), do: Enum.reduce(list, used, &variables/2)
  defp variables(tuple, used) when is_tuple(tuple), do: variables(Tuple.to_list(tuple), used)
  defp variables(_, used), do: used
end
