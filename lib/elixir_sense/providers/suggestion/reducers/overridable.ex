defmodule ElixirSense.Providers.Suggestion.Reducers.Overridable do
  @moduledoc false

  alias ElixirSense.Core.Introspection
  alias ElixirSense.Core.State
  alias ElixirSense.Providers.Suggestion.Matcher

  @doc """
  A reducer that adds suggestions of overridable functions.
  """
  def add_overridable(_hint, %State.Env{scope: {_f, _a}}, _metadata, _cursor_context, acc),
    do: {:cont, acc}

  def add_overridable(hint, env, metadata, _cursor_context, acc) do
    %State.Env{protocol: protocol, behaviours: behaviours, module: module} = env

    # overridable behaviour callbacks are returned by Reducers.Callbacks
    behaviour_callbacks =
      Enum.flat_map(behaviours, fn
        mod when is_atom(mod) and (protocol == nil or mod != elem(protocol, 0)) ->
          for %{
                name: name,
                arity: arity
              } <-
                Introspection.get_callbacks_with_docs(mod) do
            {name, arity}
          end

        _ ->
          []
      end)

    # no need to care of default args here
    # only the max arity version can be overridden
    list =
      for {{^module, name, arity}, %State.ModFunInfo{overridable: {true, origin}} = info}
          when is_integer(arity) <- metadata.mods_funs_to_positions,
          def_prefix?(hint, info.type) or Matcher.match?("#{name}", hint),
          {name, arity} not in behaviour_callbacks do
        spec =
          case metadata.specs[{module, name, arity}] do
            %State.SpecInfo{specs: specs} -> specs |> Enum.join("\n")
            nil -> ""
          end

        args_list = info.params |> hd |> Enum.map(&(&1 |> elem(0) |> Atom.to_string()))
        args = args_list |> Enum.join(", ")

        subtype =
          case State.ModFunInfo.get_category(info) do
            :function -> :callback
            :macro -> :macrocallback
          end

        %{
          type: :callback,
          subtype: subtype,
          name: Atom.to_string(name),
          arity: arity,
          args: args,
          args_list: args_list,
          origin: inspect(origin),
          summary: "",
          metadata: %{},
          spec: spec
        }
      end

    {:cont, %{acc | result: acc.result ++ Enum.sort(list)}}
  end

  defp def_prefix?(hint, type) when type in [:defmacro, :defmacrop] do
    String.starts_with?("defmacro", hint)
  end

  defp def_prefix?(hint, type) when type in [:def, :defp] do
    String.starts_with?("def", hint)
  end
end
