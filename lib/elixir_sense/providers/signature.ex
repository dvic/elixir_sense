defmodule ElixirSense.Providers.Signature do
  @moduledoc """
  Provider responsible for introspection information about function signatures.
  """

  alias ElixirSense.Core.Binding
  alias ElixirSense.Core.Introspection
  alias ElixirSense.Core.Metadata
  alias ElixirSense.Core.Source
  alias ElixirSense.Core.State
  alias ElixirSense.Core.TypeInfo

  @type signature_info :: %{
          active_param: non_neg_integer,
          signatures: [Metadata.signature_t()]
        }

  @doc """
  Returns the signature info from the function or type defined in the prefix, if any.
  """
  @spec find(String.t(), {pos_integer, pos_integer}, State.Env.t(), Metadata.t()) ::
          signature_info | :none
  def find(prefix, cursor_position, env, metadata) do
    %State.Env{
      imports: imports,
      requires: requires,
      aliases: aliases,
      module: module,
      scope: scope
    } = env

    binding_env = Binding.from_env(env, metadata)

    with %{candidate: {m, f}, npar: npar, elixir_prefix: elixir_prefix} <-
           Source.which_func(prefix, binding_env),
         {mod, fun, true, kind} <-
           Introspection.actual_mod_fun(
             {m, f},
             imports,
             requires,
             if(elixir_prefix, do: [], else: aliases),
             module,
             scope,
             metadata.mods_funs_to_positions,
             metadata.types,
             cursor_position
           ) do
      signatures = find_signatures({mod, fun}, npar, kind, env, metadata)
      %{active_param: npar, signatures: signatures}
    else
      _ ->
        :none
    end
  end

  defp find_signatures({mod, fun}, npar, kind, env, metadata) do
    signatures =
      case kind do
        :mod_fun -> find_function_signatures({mod, fun}, env, metadata)
        :type -> find_type_signatures({mod, fun}, metadata)
      end

    signatures
    |> Enum.filter(fn %{params: params} ->
      params_length = length(params)

      if params_length == 0 do
        npar == 0
      else
        params_length > npar
      end
    end)
    |> Enum.sort_by(&length(&1.params))
  end

  defp find_function_signatures({nil, _fun}, _env, _metadata), do: []

  defp find_function_signatures({mod, fun}, env, metadata) do
    signatures =
      case Metadata.get_function_signatures(metadata, mod, fun) do
        [] ->
          Introspection.get_signatures(mod, fun)

        signatures ->
          for signature <- signatures do
            arity = length(signature.params)

            behaviour_implementation =
              Metadata.get_module_behaviours(metadata, env, mod)
              |> Enum.find_value(fn behaviour ->
                if Introspection.is_callback(behaviour, fun, arity, metadata) do
                  behaviour
                end
              end)

            case behaviour_implementation do
              nil ->
                signature

              behaviour ->
                case metadata.specs[{behaviour, fun, arity}] do
                  %State.SpecInfo{} = spec_info ->
                    specs =
                      spec_info.specs
                      |> Enum.reject(&String.starts_with?(&1, "@spec"))
                      |> Enum.reverse()

                    # TODO provide docs
                    %{
                      signature
                      | spec: specs |> Enum.join("\n"),
                        documentation: ""
                    }

                  nil ->
                    fun_info = Map.fetch!(metadata.mods_funs_to_positions, {mod, fun, arity})

                    {spec, doc, _} =
                      Metadata.get_doc_spec_from_behaviour(
                        behaviour,
                        fun,
                        arity,
                        State.ModFunInfo.get_category(fun_info)
                      )

                    %{
                      signature
                      | documentation: doc,
                        spec: spec
                    }
                end
            end
          end
      end

    signatures |> Enum.uniq_by(fn sig -> sig.params end)
  end

  defp find_type_signatures({nil, fun}, _metadata) do
    TypeInfo.get_signatures(nil, fun)
  end

  defp find_type_signatures({mod, fun}, metadata) do
    case Metadata.get_type_signatures(metadata, mod, fun) do
      [] -> TypeInfo.get_signatures(mod, fun)
      signature -> signature
    end
  end
end
