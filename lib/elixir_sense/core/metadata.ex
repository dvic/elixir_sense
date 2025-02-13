defmodule ElixirSense.Core.Metadata do
  @moduledoc """
  Core Metadata
  """

  alias ElixirSense.Core.Behaviours
  alias ElixirSense.Core.Introspection
  alias ElixirSense.Core.Normalized.Code, as: NormalizedCode
  alias ElixirSense.Core.State

  @type t :: %ElixirSense.Core.Metadata{
          source: String.t(),
          mods_funs_to_positions: State.mods_funs_to_positions_t(),
          lines_to_env: State.lines_to_env_t(),
          calls: State.calls_t(),
          vars_info_per_scope_id: State.vars_info_per_scope_id_t(),
          types: State.types_t(),
          specs: State.specs_t(),
          structs: State.structs_t(),
          error: nil | term,
          first_alias_positions: map(),
          moduledoc_positions: map()
        }

  defstruct source: "",
            mods_funs_to_positions: %{},
            lines_to_env: %{},
            calls: %{},
            vars_info_per_scope_id: %{},
            types: %{},
            specs: %{},
            structs: %{},
            error: nil,
            first_alias_positions: %{},
            moduledoc_positions: %{}

  @type signature_t :: %{
          name: String.t(),
          params: [String.t()],
          spec: String.t(),
          documentation: String.t()
        }

  @spec get_env(__MODULE__.t(), {pos_integer, pos_integer}) :: State.Env.t()
  def get_env(%__MODULE__{} = metadata, {line, column}) do
    all_scopes =
      Enum.to_list(metadata.types) ++
        Enum.to_list(metadata.specs) ++
        Enum.to_list(metadata.mods_funs_to_positions)

    closest_scopes =
      all_scopes
      |> Enum.map(fn
        {{_, fun, nil}, _} when fun != nil ->
          nil

        {key, %type{positions: positions, end_positions: end_positions, generated: generated}} ->
          closest_scope =
            Enum.zip([positions, end_positions, generated])
            |> Enum.map(fn
              {_, _, true} ->
                nil

              {{begin_line, begin_column}, {end_line, end_column}, _}
              when (line > begin_line or (line == begin_line and column >= begin_column)) and
                     (line < end_line or (line == end_line and column <= end_column)) ->
                {{begin_line, begin_column}, {end_line, end_column}}

              {{begin_line, begin_column}, nil, _}
              when line > begin_line or (line == begin_line and column >= begin_column) ->
                case find_closest_ending(all_scopes, {begin_line, begin_column}) do
                  nil ->
                    {{begin_line, begin_column}, nil}

                  {end_line, end_column} ->
                    if line < end_line or (line == end_line and column < end_column) do
                      {{begin_line, begin_column}, {end_line, end_column}}
                    end
                end

              _ ->
                nil
            end)
            |> Enum.filter(&(&1 != nil))
            |> Enum.max(fn -> nil end)

          if closest_scope do
            {key, type, closest_scope}
          end
      end)
      |> Enum.filter(&(&1 != nil))
      |> Enum.sort_by(
        fn {_key, _type, {begin_position, _end_position}} ->
          begin_position
        end,
        :desc
      )

    case closest_scopes do
      [_ | _] = scopes ->
        metadata.lines_to_env
        |> Enum.filter(fn {metadata_line, env} ->
          Enum.any?(scopes, fn {key, type, {{begin_line, _begin_column}, _}} ->
            if metadata_line >= begin_line do
              case {key, type} do
                {{module, nil, nil}, _} ->
                  module in env.module_variants and is_atom(env.scope) and env.scope != Elixir

                {{module, fun, arity}, State.ModFunInfo} ->
                  module in env.module_variants and env.scope == {fun, arity}

                {{module, fun, arity}, type} when type in [State.TypeInfo, State.SpecInfo] ->
                  module in env.module_variants and env.scope == {:typespec, fun, arity}
              end
            end
          end)
        end)

      [] ->
        metadata.lines_to_env
    end
    |> Enum.max_by(
      fn
        {metadata_line, _env} when metadata_line <= line -> metadata_line
        _ -> 0
      end,
      &>=/2,
      fn ->
        {line, State.default_env()}
      end
    )
    |> elem(1)
  end

  defp find_closest_ending(all_scopes, {line, column}) do
    all_scopes
    |> Enum.map(fn
      {{_, fun, nil}, _} when fun != nil ->
        nil

      {_key, %{positions: positions, end_positions: end_positions, generated: generated}} ->
        Enum.zip([positions, end_positions, generated])
        |> Enum.map(fn
          {_, _, true} ->
            nil

          {{begin_line, begin_column}, {end_line, end_column}, _} ->
            if {begin_line, begin_column} > {line, column} do
              {begin_line, begin_column}
            else
              if {end_line, end_column} > {line, column} do
                {end_line, end_column}
              end
            end

          {{begin_line, begin_column}, nil, _} ->
            if {begin_line, begin_column} > {line, column} do
              {begin_line, begin_column}
            end
        end)
        |> Enum.filter(&(&1 != nil))
        |> Enum.min(fn -> nil end)
    end)
    |> Enum.filter(&(&1 != nil))
    |> Enum.min(fn -> nil end)
  end

  def add_scope_vars(
        %State.Env{} = env,
        %__MODULE__{vars_info_per_scope_id: vars_info_per_scope_id},
        {line, column},
        predicate \\ fn _ -> true end
      ) do
    scope_vars = vars_info_per_scope_id[env.scope_id] || []
    env_vars_names = env.vars |> Enum.map(& &1.name)

    scope_vars_missing_in_env =
      scope_vars
      |> Enum.filter(fn var ->
        var.name not in env_vars_names and Enum.min(var.positions) <= {line, column} and
          predicate.(var)
      end)

    %{env | vars: env.vars ++ scope_vars_missing_in_env}
  end

  @spec at_module_body?(State.Env.t()) :: boolean()
  def at_module_body?(env) do
    is_atom(env.scope) and env.scope != Elixir
  end

  def get_position_to_insert_alias(%__MODULE__{} = metadata, {line, column}) do
    env = get_env(metadata, {line, column})
    module = env.module

    cond do
      Map.has_key?(metadata.first_alias_positions, module) ->
        Map.get(metadata.first_alias_positions, module)

      Map.has_key?(metadata.moduledoc_positions, module) ->
        Map.get(metadata.moduledoc_positions, module)

      true ->
        mod_info = Map.get(metadata.mods_funs_to_positions, {env.module, nil, nil})

        case mod_info do
          %State.ModFunInfo{positions: [{line, column}]} ->
            # Hacky :shrug
            line_offset = 1
            column_offset = 2
            {line + line_offset, column + column_offset}

          _ ->
            nil
        end
    end
  end

  def get_calls(%__MODULE__{} = metadata, line) do
    case Map.get(metadata.calls, line) do
      nil -> []
      calls -> Enum.sort_by(calls, fn %State.CallInfo{position: {_line, column}} -> column end)
    end
  end

  def get_call_arity(%__MODULE__{}, _module, nil, _line, _column), do: nil

  def get_call_arity(
        %__MODULE__{calls: calls, error: error, mods_funs_to_positions: mods_funs_to_positions},
        module,
        fun,
        line,
        column
      ) do
    result =
      case calls[line] do
        nil ->
          nil

        line_calls ->
          line_calls
          |> Enum.filter(fn %State.CallInfo{position: {_call_line, call_column}} ->
            call_column <= column
          end)
          |> Enum.find_value(fn call ->
            # call.mod in not expanded
            if call.func == fun do
              if error == {:error, :parse_error} do
                {:gte, call.arity}
              else
                call.arity
              end
            end
          end)
      end

    if result == nil do
      mods_funs_to_positions
      |> Enum.find_value(fn
        {{^module, ^fun, arity}, %{positions: positions}} when not is_nil(arity) ->
          if Enum.any?(positions, &match?({^line, _}, &1)) do
            arity
          end

        _ ->
          nil
      end)
    else
      result
    end
  end

  def get_function_info(%__MODULE__{} = metadata, module, function) do
    case Map.get(metadata.mods_funs_to_positions, {module, function, nil}) do
      nil -> %{positions: [], params: []}
      info -> info
    end
  end

  def get_function_params(%__MODULE__{} = metadata, module, function) do
    params =
      metadata
      |> get_function_info(module, function)
      |> Map.get(:params)
      |> Enum.reverse()

    Enum.map(params, fn param ->
      param
      |> Macro.to_string()
      |> String.slice(1..-2)
    end)
  end

  @spec get_function_signatures(__MODULE__.t(), module, atom) :: [signature_t]
  def get_function_signatures(%__MODULE__{} = metadata, module, function)
      when not is_nil(module) and not is_nil(function) do
    metadata.mods_funs_to_positions
    |> Enum.filter(fn
      {{^module, ^function, arity}, _function_info} when not is_nil(arity) -> true
      _ -> false
    end)
    |> Enum.map(fn {{_, _, arity}, %State.ModFunInfo{} = function_info} ->
      params = function_info.params |> List.last()

      spec =
        case metadata.specs[{module, function, arity}] do
          nil ->
            ""

          %State.SpecInfo{specs: specs} ->
            specs |> Enum.reverse() |> Enum.join("\n")
        end

      # fallback to callback spec done in signature provider

      %{
        name: Atom.to_string(function),
        params: params |> Enum.with_index() |> Enum.map(&Introspection.param_to_var/1),
        # TODO provide doc
        documentation: "",
        spec: spec
      }
    end)
  end

  @spec get_type_signatures(__MODULE__.t(), module, atom) :: [signature_t]
  def get_type_signatures(%__MODULE__{} = metadata, module, type)
      when not is_nil(module) and not is_nil(type) do
    metadata.types
    |> Enum.filter(fn
      {{^module, ^type, arity}, _type_info} when not is_nil(arity) -> true
      _ -> false
    end)
    |> Enum.map(fn {_, %State.TypeInfo{} = type_info} ->
      args = type_info.args |> List.last() |> Enum.join(", ")

      spec =
        case type_info.kind do
          :opaque -> "@opaque #{type}(#{args})"
          _ -> List.last(type_info.specs)
        end

      %{
        name: Atom.to_string(type),
        params: type_info.args |> List.last(),
        # TODO extract docs
        documentation: "",
        spec: spec
      }
    end)
  end

  def get_doc_spec_from_behaviour(behaviour, f, a, kind) do
    docs =
      NormalizedCode.callback_documentation(behaviour)
      |> Map.new()

    meta = %{implementing: behaviour}
    spec = Introspection.get_spec_as_string(nil, f, a, kind, meta)

    case docs[{f, a}] do
      nil ->
        {spec, "", meta}

      {_signatures, docs, callback_meta, mime_type} ->
        {spec, docs |> NormalizedCode.extract_docs(mime_type), callback_meta |> Map.merge(meta)}
    end
  end

  def get_last_module_env(_metadata, nil), do: nil

  def get_last_module_env(metadata, module) do
    metadata.lines_to_env
    |> Enum.filter(fn {_k, v} -> module in v.module_variants end)
    |> Enum.max_by(fn {k, _v} -> k end, fn -> {nil, nil} end)
    |> elem(1)
  end

  def get_module_behaviours(metadata, env, module) do
    # try to get behaviours from the target module - metadata
    behaviours =
      case get_last_module_env(metadata, module) do
        nil ->
          []

        module_env ->
          module_env.behaviours
      end

    # try to get behaviours from the target module - introspection
    behaviours =
      if behaviours == [] do
        Behaviours.get_module_behaviours(module)
      else
        behaviours
      end

    # get behaviours from current env
    behaviours =
      if behaviours == [] do
        env.behaviours
      else
        behaviours
      end

    behaviours
  end
end
