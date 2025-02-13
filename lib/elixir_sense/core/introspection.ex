# This file includes modified code extracted from the elixir project. Namely:
#
# https://github.com/elixir-lang/elixir/blob/c983b3db6936ce869f2668b9465a50007ffb9896/lib/iex/lib/iex/introspection.ex
# https://github.com/elixir-lang/ex_doc/blob/82463a56053b29a406fd271e9e2e2f05e87d6248/lib/ex_doc/retriever.ex
#
# The original code is licensed as follows:
#
# Copyright 2012 Plataformatec
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ElixirSense.Core.Introspection do
  @moduledoc """
  A collection of functions to introspect/format docs, specs, types and callbacks.
  """

  alias ElixirSense.Core.BuiltinFunctions
  alias ElixirSense.Core.BuiltinTypes
  alias ElixirSense.Core.Metadata
  alias ElixirSense.Core.Normalized.Code, as: NormalizedCode
  alias ElixirSense.Core.Normalized.Typespec
  alias ElixirSense.Core.State
  alias ElixirSense.Core.TypeInfo

  @type mod_fun :: {module | nil, atom | nil}
  @type markdown :: String.t()
  @type docs :: %{docs: markdown}

  @type module_subtype ::
          :exception | :protocol | :implementation | :behaviour | :struct | :task | :alias | nil

  @wrapped_behaviours %{
    :gen_server => GenServer,
    :gen_event => GenEvent,
    :supervisor => Supervisor,
    :application => Application
  }

  defguard matches_arity?(is, expected)
           when is != nil and
                  (expected == :any or is == expected or
                     (is_tuple(expected) and elem(expected, 0) == :gte and is >= elem(expected, 1)))

  defguard matches_arity_with_defaults?(is, defaults, expected)
           when is != nil and
                  (expected == :any or (is_integer(expected) and expected in (is - defaults)..is) or
                     (is_tuple(expected) and elem(expected, 0) == :gte and is >= elem(expected, 1)))

  @spec get_exports(module) :: [{atom, {non_neg_integer, :macro | :function}}]
  def get_exports(Elixir), do: []

  def get_exports(module) do
    case Code.ensure_loaded(module) do
      {:module, _} ->
        for {f, a} <- module.module_info(:exports) do
          {f_dropped, a_dropped} = drop_macro_prefix({f, a})

          kind =
            if {f_dropped, a_dropped} != {f, a} do
              :macro
            else
              :function
            end

          {f_dropped, {a_dropped, kind}}
        end
        |> Kernel.++(
          BuiltinFunctions.erlang_builtin_functions(module)
          |> Enum.map(fn {f, a} -> {f, {a, :function}} end)
        )

      _otherwise ->
        []
    end
  end

  @spec get_callbacks(module) :: [{atom, non_neg_integer}]
  def get_callbacks(Elixir), do: []

  def get_callbacks(module) do
    with {:module, _} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :behaviour_info, 1) do
      for {f, a} <- module.behaviour_info(:callbacks) do
        drop_macro_prefix({f, a})
      end
    else
      _ -> []
    end
  end

  def drop_macro_prefix({f, a}) do
    case Atom.to_string(f) do
      "MACRO-" <> macro_name ->
        # extract macro name
        {String.to_atom(macro_name), a - 1}

      _ ->
        # normal public fun
        {f, a}
    end
  end

  @doc ~S"""
  Checks if function or macro is exported from module

  ## Example

      iex> ElixirSense.Core.Introspection.exported?(Atom, :to_string)
      true

      iex> ElixirSense.Core.Introspection.exported?(Kernel, :defmodule)
      true

      iex> ElixirSense.Core.Introspection.exported?(:erlang, :orelse)
      true

      iex> ElixirSense.Core.Introspection.exported?(:lists, :flatten)
      true

  """
  @spec exported?(module, atom) :: boolean
  def exported?(module, fun) do
    Keyword.has_key?(get_exports(module), fun)
  end

  def get_all_docs({mod, nil, _}, metadata, _env, :mod_fun) do
    doc_info =
      metadata.mods_funs_to_positions
      |> Enum.find_value(fn
        {{^mod, nil, nil}, _fun_info} ->
          %{
            module: mod,
            # TODO fill metadata and docs
            metadata: %{},
            doc: nil
          }

        _ ->
          false
      end)

    if doc_info == nil do
      get_docs_md(mod)
    else
      doc_info
    end
    |> format_module_doc
  end

  def get_all_docs({mod, fun, arity}, metadata, env, :mod_fun) do
    doc_infos =
      metadata.mods_funs_to_positions
      |> Enum.filter(fn
        {{^mod, ^fun, a}, fun_info} when not is_nil(a) ->
          default_args = fun_info.params |> Enum.at(-1) |> count_defaults()

          matches_arity_with_defaults?(a, default_args, arity)

        _ ->
          false
      end)
      |> Enum.sort_by(fn {{^mod, ^fun, a}, _fun_info} -> a end)
      |> Enum.map(fn {{^mod, ^fun, a}, fun_info} ->
        fun_args_text =
          fun_info.params
          |> List.last()
          |> Enum.with_index()
          |> Enum.map(&(&1 |> param_to_var |> String.replace("\\\\", "\\\\\\\\")))

        specs =
          case metadata.specs[{mod, fun, a}] do
            nil ->
              []

            %State.SpecInfo{specs: specs} ->
              specs |> Enum.reverse()
          end

        # TODO fill metadata
        meta = %{}

        behaviour_implementation =
          Metadata.get_module_behaviours(metadata, env, mod)
          |> Enum.find_value(fn behaviour ->
            if is_callback(behaviour, fun, a, metadata) do
              behaviour
            end
          end)

        case behaviour_implementation do
          nil ->
            %{
              module: mod,
              function: fun,
              metadata: meta,
              specs: specs,
              fun_args_text: fun_args_text,
              # TODO provide docs
              docs: nil
            }

          behaviour ->
            meta = Map.merge(meta, %{implementing: behaviour})

            case metadata.specs[{behaviour, fun, a}] do
              %State.SpecInfo{} = spec_info ->
                specs =
                  spec_info.specs
                  |> Enum.reject(&String.starts_with?(&1, "@spec"))
                  |> Enum.reverse()

                # TODO callback meta

                %{
                  module: mod,
                  function: fun,
                  metadata: meta,
                  specs: specs,
                  fun_args_text: fun_args_text,
                  # TODO provide callback docs
                  docs: nil
                }

              nil ->
                callback_docs_entry =
                  NormalizedCode.callback_documentation(behaviour)
                  |> Enum.find_value(fn
                    {{^fun, ^a}, doc} -> doc
                    _ -> false
                  end)

                case callback_docs_entry do
                  nil ->
                    # pass meta with implementing flag to trigger looking for specs in behaviour module
                    # assume there is a typespec for behaviour module
                    specs = [
                      get_spec_as_string(
                        mod,
                        fun,
                        a,
                        State.ModFunInfo.get_category(fun_info),
                        meta
                      )
                    ]

                    %{
                      module: mod,
                      function: fun,
                      metadata: meta,
                      specs: specs,
                      fun_args_text: fun_args_text,
                      docs: nil
                    }

                  {_, docs, callback_meta, mime_type} ->
                    docs = docs |> NormalizedCode.extract_docs(mime_type)
                    # as of OTP 25 erlang callback doc entry does not have signature in meta
                    # pass meta with implementing flag to trigger looking for specs in behaviour module
                    # assume there is a typespec for behaviour module
                    specs = [
                      get_spec_as_string(
                        mod,
                        fun,
                        a,
                        State.ModFunInfo.get_category(fun_info),
                        meta
                      )
                    ]

                    %{
                      module: mod,
                      function: fun,
                      metadata: callback_meta |> Map.merge(meta),
                      specs: specs,
                      fun_args_text: fun_args_text,
                      docs: docs
                    }
                end
            end
        end
      end)

    doc_infos =
      if doc_infos == [] do
        get_func_docs_md(mod, fun, arity)
      else
        doc_infos
      end

    doc_infos
    |> Enum.map(&format_func_docs/1)
    |> join_docs
  end

  def get_all_docs({mod, fun, arity}, metadata, _env, :type) do
    doc_infos =
      metadata.types
      |> Enum.filter(fn
        {{^mod, ^fun, a}, _type_info} when not is_nil(a) ->
          matches_arity?(a, arity)

        _ ->
          false
      end)
      |> Enum.sort_by(fn {{_mod, _fun, a}, _fun_info} -> a end)
      |> Enum.map(fn {_, type_info} ->
        args = type_info.args |> List.last() |> Enum.join(", ")

        spec =
          case type_info.kind do
            :opaque -> "@opaque #{fun}(#{args})"
            _ -> List.last(type_info.specs)
          end

        %{
          module: mod,
          type: fun,
          # TODO fill meta
          metadata: %{},
          spec: spec,
          args: args,
          # TODO provide docs
          docs: nil
        }
      end)

    doc_infos =
      if doc_infos == [] do
        get_type_docs_md(mod, fun, arity)
      else
        doc_infos
      end

    doc_infos
    |> Enum.map(&format_type_docs/1)
    |> join_docs
  end

  defp join_docs([]), do: nil

  defp join_docs(docs) do
    Enum.join(docs, "\n\n---\n\n") <> "\n"
  end

  def count_defaults(nil), do: 0

  def count_defaults(args) do
    Enum.count(args, &match?({:\\, _, _}, &1))
  end

  @spec get_signatures(module, atom, nil | [NormalizedCode.fun_doc_entry_t()]) :: [
          ElixirSense.Core.Metadata.signature_t()
        ]
  def get_signatures(mod, fun, code_docs \\ nil)

  def get_signatures(mod, fun, _code_docs)
      when not is_nil(mod) and fun in [:module_info, :behaviour_info, :__info__] do
    for {f, a} <- BuiltinFunctions.all(), f == fun do
      spec = BuiltinFunctions.get_specs({f, a}) |> Enum.join("\n")
      params = BuiltinFunctions.get_args({f, a})
      %{name: Atom.to_string(fun), params: params, documentation: "Built-in function", spec: spec}
    end
  end

  def get_signatures(mod, fun, code_docs) when not is_nil(mod) and not is_nil(fun) do
    case code_docs || NormalizedCode.get_docs(mod, :docs) do
      docs when is_list(docs) ->
        results =
          for {{f, arity}, _, kind, args, text, metadata} <- docs, f == fun do
            fun_args = get_fun_args_from_doc_or_typespec(mod, f, arity, args, metadata)

            fun_str = Atom.to_string(fun)
            doc = extract_summary_from_docs(text)

            spec = get_spec_as_string(mod, fun, arity, kind, metadata)
            %{name: fun_str, params: fun_args, documentation: doc, spec: spec}
          end

        case results do
          [] ->
            get_spec_from_typespec(mod, fun)

          other ->
            other
        end

      nil ->
        get_spec_from_typespec(mod, fun)
    end
    |> Enum.sort_by(&length(&1.params))
  end

  defp get_spec_from_typespec(mod, fun) do
    # TypeInfo.get_function_specs does fallback to behaviours
    {behaviour, specs} = TypeInfo.get_function_specs(mod, fun, :any)

    results =
      for {{_name, _arity}, [params | _]} = spec <- specs do
        params = TypeInfo.extract_params(params) |> Enum.map(&Atom.to_string/1)

        %{
          name: Atom.to_string(fun),
          params: params,
          documentation: "",
          spec: spec |> spec_to_string(if(behaviour, do: :callback, else: :spec))
        }
      end

    case results do
      [] ->
        # no typespecs
        # provide dummy spec basing on module_info(:exports)
        get_spec_from_module_info(mod, fun)

      other ->
        other
    end
  end

  defp get_spec_from_module_info(mod, fun) do
    # no fallback to behaviours here - we assume that behaviours have typespecs
    # and were already handled
    for {f, {a, _kind}} <- get_exports(mod),
        f == fun do
      dummy_params = if a == 0, do: [], else: Enum.map(1..a, fn _ -> "term" end)

      %{
        name: Atom.to_string(fun),
        params: dummy_params,
        documentation: "",
        spec: ""
      }
    end
  end

  defp format_func_docs(info) do
    mod_str = inspect(info.module)
    fun_str = Atom.to_string(info.function)

    spec_text =
      if info.specs != [] do
        joined = Enum.join(info.specs, "\n")
        "### Specs\n\n```\n#{joined}\n```\n\n"
      else
        ""
      end

    "> #{mod_str}.#{fun_str}(#{info.fun_args_text})\n\n#{get_metadata_md(info.metadata)}#{spec_text}#{info.docs || ""}"
  end

  @spec get_func_docs_md(nil | module, atom, non_neg_integer | :any) :: list(markdown)
  def get_func_docs_md(mod, fun, arity)
      when mod != nil and fun in [:module_info, :behaviour_info, :__info__] do
    for {f, a} <- BuiltinFunctions.all(), f == fun, matches_arity?(a, arity) do
      spec = BuiltinFunctions.get_specs({f, a})
      args = BuiltinFunctions.get_args({f, a})

      fun_args_text = Enum.join(args, ", ")
      metadata = %{builtin: true}

      %{
        module: mod,
        function: fun,
        metadata: metadata,
        specs: spec,
        fun_args_text: fun_args_text,
        # TODO provide docs
        docs: nil
      }
    end
  end

  def get_func_docs_md(mod, fun, call_arity) do
    case NormalizedCode.get_docs(mod, :docs) do
      nil ->
        # no docs, fallback to typespecs
        get_func_docs_md_from_typespec(mod, fun, call_arity)

      docs ->
        results =
          for {{f, arity}, _, kind, args, text, metadata} <- docs,
              f == fun,
              matches_arity_with_defaults?(arity, Map.get(metadata, :defaults, 0), call_arity) do
            fun_args_text = get_fun_args_from_doc_or_typespec(mod, f, arity, args, metadata)

            %{
              module: mod,
              function: fun,
              metadata: metadata,
              specs: get_specs_text(mod, fun, arity, kind, metadata),
              fun_args_text:
                fun_args_text |> Enum.map_join(", ", &String.replace(&1, "\\\\", "\\\\\\\\")),
              docs: text
            }
          end

        case results do
          [] ->
            get_func_docs_md_from_typespec(mod, fun, call_arity)

          other ->
            other
        end
    end
  end

  defp get_func_docs_md_from_typespec(mod, fun, call_arity) do
    # TypeInfo.get_function_specs does fallback to behaviours
    {behaviour, specs} = TypeInfo.get_function_specs(mod, fun, call_arity)

    meta =
      if behaviour do
        %{implementing: behaviour}
      else
        %{}
      end

    results =
      for {{_name, arity}, [params | _]} <- specs do
        fun_args_text = TypeInfo.extract_params(params) |> Enum.map_join(", ", &Atom.to_string/1)

        %{
          module: mod,
          function: fun,
          metadata: meta,
          specs: get_specs_text(mod, fun, arity, :function, meta),
          fun_args_text: fun_args_text,
          docs: nil
        }
      end

    case results do
      [] ->
        # no docs and no typespecs
        get_func_docs_md_from_module_info(mod, fun, call_arity)

      other ->
        other
    end
  end

  defp get_func_docs_md_from_module_info(mod, fun, call_arity) do
    # it is not worth doing fallback to behaviours here
    # we'll not get much more useful info

    # provide dummy docs basing on module_info(:exports)
    for {f, {arity, _kind}} <- get_exports(mod),
        f == fun,
        matches_arity?(arity, call_arity) do
      fun_args_text =
        if arity == 0, do: "", else: Enum.map_join(1..arity, ", ", fn _ -> "term" end)

      metadata =
        if {f, arity} in BuiltinFunctions.erlang_builtin_functions(mod) do
          %{builtin: true}
        else
          %{}
        end

      %{
        module: mod,
        function: fun,
        metadata: metadata,
        specs: get_specs_text(mod, fun, arity, :function, metadata),
        fun_args_text: fun_args_text,
        docs: nil
      }
    end
  end

  defp format_module_doc(nil), do: nil

  defp format_module_doc(info) do
    mod_str = inspect(info.module)
    doc = info.doc || ""
    "> #{mod_str}\n\n" <> get_metadata_md(info.metadata) <> doc
  end

  def get_docs_md(mod) when is_atom(mod) do
    case NormalizedCode.get_docs(mod, :moduledoc) do
      {_line, doc, metadata} when is_binary(doc) ->
        %{
          module: mod,
          metadata: metadata,
          doc: doc
        }

      _ ->
        if Code.ensure_loaded?(mod) do
          %{
            module: mod,
            metadata: %{},
            doc: nil
          }
        end
    end
  end

  def get_metadata_md(metadata) do
    text =
      metadata
      |> Enum.sort()
      |> Enum.map(&get_metadata_entry_md/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    case text do
      "" -> ""
      not_empty -> not_empty <> "\n\n"
    end
  end

  # erlang name
  defp get_metadata_entry_md({:name, _text}), do: nil

  # erlang signature
  defp get_metadata_entry_md({:signature, _text}), do: nil

  # erlang edit_url
  defp get_metadata_entry_md({:edit_url, _text}), do: nil

  # erlang :otp_doc_vsn
  defp get_metadata_entry_md({:otp_doc_vsn, _text}), do: nil

  # erlang :source
  defp get_metadata_entry_md({:source, _text}), do: nil

  # erlang :types
  defp get_metadata_entry_md({:types, _text}), do: nil

  # erlang :equiv
  defp get_metadata_entry_md({:equiv, {:function, name, arity}}) do
    "**Equivalent**\n#{name}/#{arity}"
  end

  defp get_metadata_entry_md({:deprecated, text}) do
    "**Deprecated**\n#{text}"
  end

  defp get_metadata_entry_md({:since, text}) do
    "**Since**\n#{text}"
  end

  defp get_metadata_entry_md({:group, text}) do
    "**Group**\n#{text}"
  end

  defp get_metadata_entry_md({:guard, true}) do
    "**Guard**"
  end

  defp get_metadata_entry_md({:builtin, true}) do
    "**Built-in**"
  end

  defp get_metadata_entry_md({:implementing, module}) do
    "**Implementing behaviour**\n#{inspect(module)}"
  end

  defp get_metadata_entry_md({:optional, true}) do
    "**Optional**"
  end

  defp get_metadata_entry_md({:optional, false}), do: nil

  defp get_metadata_entry_md({:opaque, true}) do
    "**Opaque**"
  end

  defp get_metadata_entry_md({:defaults, _}), do: nil

  defp get_metadata_entry_md({:delegate_to, {m, f, a}}) do
    "**Delegates to**\n#{inspect(m)}.#{f}/#{a}"
  end

  defp get_metadata_entry_md({key, value}) do
    "**#{key}**\n#{value}"
  end

  defp format_type_docs(info) do
    formatted_spec = "```\n#{info.spec}\n```"

    mod_formatted =
      case info.module do
        nil -> ""
        atom -> inspect(atom) <> "."
      end

    docs = info.docs || ""

    "> #{mod_formatted}#{info.type}(#{info.args})\n\n#{get_metadata_md(info.metadata)}### Definition\n\n#{formatted_spec}\n\n#{docs}"
  end

  @spec get_type_docs_md(nil | module, atom, non_neg_integer | :any) :: list(markdown)
  defp get_type_docs_md(nil, fun, arity) do
    for info <- BuiltinTypes.get_builtin_type_info(fun),
        matches_arity?(length(info.params), arity) do
      {spec, args} =
        case info do
          %{signature: signature, params: params} ->
            {"@type #{signature}", Enum.map_join(params, ", ", &(&1 |> Atom.to_string()))}

          %{spec: spec_ast, params: params} ->
            {TypeInfo.format_type_spec_ast(spec_ast, :type),
             Enum.map_join(params, ", ", &(&1 |> Atom.to_string()))}

          _ ->
            {"@type #{fun}()", ""}
        end

      %{
        module: nil,
        type: fun,
        args: args,
        metadata: %{builtin: true},
        spec: spec,
        docs: info[:doc]
      }
    end
  end

  defp get_type_docs_md(mod, fun, arity) do
    case TypeInfo.get_type_docs(mod, fun, arity) do
      [] ->
        for {kind, {name, _type, args}} = typedef <- Typespec.get_types(mod),
            name == fun,
            matches_arity?(length(args), arity),
            kind in [:type, :opaque] do
          spec = TypeInfo.format_type_spec(typedef)

          type_args = Enum.map_join(args, ", ", &(&1 |> elem(2) |> Atom.to_string()))

          %{
            module: mod,
            type: fun,
            args: type_args,
            metadata: %{},
            spec: spec,
            docs: nil
          }
        end

      docs ->
        for {{f, arity}, _, _, text, metadata} <- docs, f == fun do
          spec =
            mod
            |> TypeInfo.get_type_spec(f, arity)

          {_kind, {_name, _def, args}} = spec
          type_args = Enum.map_join(args, ", ", &(&1 |> elem(2) |> Atom.to_string()))

          %{
            module: mod,
            type: fun,
            args: type_args,
            metadata: metadata,
            spec: TypeInfo.format_type_spec(spec),
            docs: text
          }
        end
    end
  end

  def get_callbacks_with_docs(mod) when is_atom(mod) do
    mod =
      @wrapped_behaviours
      |> Map.get(mod, mod)

    optional_callbacks =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :behaviour_info, 1),
        do: mod.behaviour_info(:optional_callbacks),
        else: []

    case get_callbacks_and_docs(mod) do
      {callbacks, []} ->
        Enum.map(callbacks, fn {{name, arity}, [spec | _]} ->
          spec_ast =
            Typespec.spec_to_quoted(name, spec)
            |> Macro.prewalk(&drop_macro_env/1)

          signature = get_typespec_signature(spec_ast, arity)
          definition = format_spec_ast(spec_ast)

          %{
            name: name,
            kind: :callback,
            arity: arity,
            callback: "@callback #{definition}",
            signature: signature,
            doc: nil,
            metadata: %{optional: {name, arity} in optional_callbacks}
          }
        end)

      {callbacks, docs} ->
        Enum.map(docs, fn
          {{fun, arity}, _, kind, doc, metadata} ->
            get_callback_with_doc(
              kind,
              doc,
              metadata,
              {fun, arity},
              callbacks,
              optional_callbacks
            )
        end)
    end
    |> Enum.sort_by(&{&1.name, &1.arity})
  end

  def get_types_with_docs(module) when is_atom(module) do
    docs = NormalizedCode.get_docs(module, :type_docs)

    module
    |> Typespec.get_types()
    |> Enum.filter(fn {kind, {_t, _, _args}} -> kind in [:type, :opaque] end)
    |> Enum.map(fn {_, {t, _, args}} = type ->
      {doc, metadata} =
        if docs do
          TypeInfo.get_type_doc_desc(docs, t, length(args))
        else
          {"", %{}}
        end

      type_args = Enum.map_join(args, ", ", &(&1 |> elem(2) |> Atom.to_string()))

      %{
        type_name: t,
        type_args: type_args,
        type: format_type(type),
        doc: doc,
        metadata: metadata
      }
    end)
  end

  def extract_summary_from_docs(doc) when doc in [nil, "", false], do: ""

  def extract_summary_from_docs(doc) when is_binary(doc) do
    doc
    |> String.split("\n\n")
    |> Enum.at(0)
  end

  defp format_type({:opaque, type}) do
    {:"::", _, [ast, _]} = Typespec.type_to_quoted(type)
    "@opaque #{format_spec_ast(ast)}"
  end

  defp format_type({kind, type}) do
    ast = Typespec.type_to_quoted(type)
    "@#{kind} #{format_spec_ast(ast)}"
  end

  def format_spec_ast(spec_ast) do
    parts =
      spec_ast
      |> Macro.prewalk(&drop_macro_env/1)
      |> extract_spec_ast_parts

    name_str = Macro.to_string(parts.name)

    when_str =
      case parts[:when_part] do
        nil ->
          ""

        ast ->
          {:when, [], [:fake_lhs, ast]}
          |> Macro.to_string()
          |> String.replace_prefix(":fake_lhs", "")
      end

    returns_str =
      if parts.returns != [] do
        returns_str =
          parts.returns
          |> Enum.map_join(" |\n  ", &Macro.to_string(&1))

        case length(parts.returns) do
          1 -> " :: #{returns_str}#{when_str}"
          _ -> " ::\n  #{returns_str}#{when_str}"
        end
      else
        ""
      end

    formated_spec = name_str <> returns_str

    formated_spec |> String.replace("()", "")
  end

  def define_callback?(mod, fun, arity) do
    mod
    |> Typespec.get_callbacks()
    |> Enum.any?(fn {{f, a}, _} ->
      drop_macro_prefix({f, a}) == {fun, arity}
    end)
  end

  def get_returns_from_callback(module, func, arity) do
    @wrapped_behaviours
    |> Map.get(module, module)
    |> get_callback_ast(func, arity)
    |> get_returns_from_spec_ast
  end

  def get_returns_from_spec_ast(ast) do
    parts = extract_spec_ast_parts(ast)

    for return <- parts.returns do
      ast = return |> strip_return_types()

      return =
        case parts[:when_part] do
          nil -> return
          _ -> {:when, [], [return, parts.when_part]}
        end

      spec = return |> TypeInfo.spec_ast_to_string()
      stripped = ast |> TypeInfo.spec_ast_to_string()
      snippet = ast |> return_to_snippet()
      %{description: stripped, spec: spec, snippet: snippet}
    end
  end

  defp extract_spec_ast_parts({:when, _, [{:"::", _, [name_part, return_part]}, when_part]}) do
    %{name: name_part, returns: extract_return_part(return_part, []), when_part: when_part}
  end

  defp extract_spec_ast_parts({:"::", _, [name_part, return_part]}) do
    %{name: name_part, returns: extract_return_part(return_part, [])}
  end

  defp extract_spec_ast_parts({_name, _meta, _args} = name_part) do
    %{name: name_part, returns: []}
  end

  defp extract_return_part({:|, _, [lhs, rhs]}, returns) do
    [lhs | extract_return_part(rhs, returns)]
  end

  defp extract_return_part(ast, returns) do
    [ast | returns]
  end

  defp get_callback_with_doc(
         kind,
         doc,
         metadata,
         {name, arity},
         callbacks,
         optional_callbacks
       ) do
    key =
      {spec_name, _spec_arity} =
      if kind == :macrocallback do
        {:"MACRO-#{name}", arity + 1}
      else
        # some erlang callbacks have broken docs e.g. :gen_statem.state_name
        {name |> Atom.to_string() |> Macro.underscore() |> String.to_atom(), arity}
      end

    {_, [spec | _]} = List.keyfind(callbacks, key, 0)

    spec_ast =
      Typespec.spec_to_quoted(spec_name, spec)
      |> Macro.prewalk(&drop_macro_env/1)

    spec_ast =
      if kind == :macrocallback do
        spec_ast |> remove_first_macro_arg()
      else
        spec_ast
      end

    signature = get_typespec_signature(spec_ast, arity)
    definition = format_spec_ast(spec_ast)

    %{
      name: name,
      kind: kind,
      arity: arity,
      callback: "@#{kind} #{definition}",
      signature: signature,
      doc: doc,
      metadata: metadata |> Map.put(:optional, key in optional_callbacks)
    }
  end

  defp get_callbacks_and_docs(mod) do
    callbacks = Typespec.get_callbacks(mod)

    docs =
      @wrapped_behaviours
      |> Map.get(mod, mod)
      |> NormalizedCode.get_docs(:callback_docs)

    # no fallback here as :docsh as ov v0.7.2 does not seem to support callbacks

    {callbacks, docs || []}
  end

  defp drop_macro_env({name, meta, [{:"::", _, [_, {{:., _, [Macro.Env, :t]}, _, _}]} | args]}),
    do: {name, meta, args}

  defp drop_macro_env(other), do: other

  defp get_typespec_signature({:when, _, [{:"::", _, [{name, meta, args}, _]}, _]}, arity) do
    to_string_with_parens({name, meta, strip_types(args, arity)})
  end

  defp get_typespec_signature({:"::", _, [{name, meta, args}, _]}, arity) do
    to_string_with_parens({name, meta, strip_types(args, arity)})
  end

  defp get_typespec_signature({name, meta, args}, arity) do
    to_string_with_parens({name, meta, strip_types(args, arity)})
  end

  def to_string_with_parens({name, meta, args}) when is_atom(name) do
    if Code.Formatter.local_without_parens?(
         name,
         length(args),
         Code.Formatter.locals_without_parens()
       ) do
      # Macro.to_string formats some locals without parens
      # notable case is Phoenix.Endpoint.config/2 callback
      replacement = :__elixir_sense_replace_me__

      Macro.to_string({replacement, meta, args})
      |> String.replace(Atom.to_string(replacement), Atom.to_string(name))
    else
      Macro.to_string({name, meta, args})
    end
  end

  def to_string_with_parens(ast) do
    Macro.to_string(ast)
  end

  defp strip_types(args, arity) do
    args
    |> Enum.take(-arity)
    |> Enum.with_index()
    |> Enum.map(fn
      {{:"::", _, [left, _]}, i} -> to_var(left, i)
      {{:|, _, _}, i} -> to_var({}, i)
      {left, i} -> to_var(left, i)
    end)
  end

  defp strip_return_types(returns) when is_list(returns) do
    returns |> Enum.map(&strip_return_types/1)
  end

  defp strip_return_types({:"::", _, [left, _]}) do
    left
  end

  defp strip_return_types({:|, meta, args}) do
    {:|, meta, strip_return_types(args)}
  end

  defp strip_return_types({:{}, meta, args}) do
    {:{}, meta, strip_return_types(args)}
  end

  defp strip_return_types(value) do
    value
  end

  defp return_to_snippet(ast) do
    {ast, _} = Macro.prewalk(ast, 1, &term_to_snippet/2)
    ast |> Macro.to_string()
  end

  defp term_to_snippet({name, _, nil} = ast, index) when is_atom(name) do
    next_snippet(ast, index)
  end

  defp term_to_snippet({:__aliases__, _, _} = ast, index) do
    next_snippet(ast, index)
  end

  defp term_to_snippet({{:., _, _}, _, _} = ast, index) do
    next_snippet(ast, index)
  end

  defp term_to_snippet({:|, _, _} = ast, index) do
    next_snippet(ast, index)
  end

  defp term_to_snippet(ast, index) do
    {ast, index}
  end

  defp next_snippet(ast, index) do
    {"${#{index}:#{TypeInfo.spec_ast_to_string(ast)}}$", index + 1}
  end

  def param_to_var({{:=, _, [_lhs, {name, _, _} = rhs]}, arg_index}) when is_atom(name) do
    rhs
    |> to_var(arg_index + 1)
    |> Macro.to_string()
  end

  def param_to_var({{:=, _, [{name, _, _} = lhs, _rhs]}, arg_index}) when is_atom(name) do
    lhs
    |> to_var(arg_index + 1)
    |> Macro.to_string()
  end

  def param_to_var({{:\\, _, _} = ast, _}) do
    ast
    |> Macro.to_string()
  end

  def param_to_var({ast, arg_index}) do
    ast
    |> to_var(arg_index + 1)
    |> Macro.to_string()
  end

  defp to_var({:%, meta, [name, _]}, _), do: {:%, meta, [name, {:%{}, meta, []}]}
  defp to_var([{:->, _, _} | _], _), do: {:function, [], nil}
  defp to_var({:<<>>, _, _}, _), do: {:binary, [], nil}
  defp to_var({:%{}, _, _}, _), do: {:map, [], nil}
  defp to_var({:{}, _, _}, _), do: {:tuple, [], nil}
  defp to_var({name, meta, _}, _) when is_atom(name), do: {name, meta, nil}
  defp to_var({_, _}, _), do: {:tuple, [], nil}
  defp to_var(integer, _) when is_integer(integer), do: {:integer, [], nil}
  defp to_var(float, _) when is_integer(float), do: {:float, [], nil}
  defp to_var(list, _) when is_list(list), do: {:list, [], nil}
  defp to_var(atom, _) when is_atom(atom), do: {:atom, [], nil}
  defp to_var(_, position), do: {:"arg#{position}", [], nil}

  def get_module_docs_summary(module) do
    case NormalizedCode.get_docs(module, :moduledoc) do
      {_, doc, metadata} ->
        {extract_summary_from_docs(doc), metadata}

      _ ->
        {"", %{}}
    end
  end

  @doc ~S"""
  Returns module subtype if known

  ## Examples

      iex> ElixirSense.Core.Introspection.get_module_subtype(ArgumentError)
      :exception
      iex> ElixirSense.Core.Introspection.get_module_subtype(Enumerable)
      :protocol
      iex> ElixirSense.Core.Introspection.get_module_subtype(Enumerable.List)
      :implementation
      iex> ElixirSense.Core.Introspection.get_module_subtype(Access)
      :behaviour
      iex> ElixirSense.Core.Introspection.get_module_subtype(URI)
      :struct
      iex> ElixirSense.Core.Introspection.get_module_subtype(Mix.Tasks.Run)
      :task
      iex> ElixirSense.Core.Introspection.get_module_subtype(NotExistingModule)
      :alias
      iex> ElixirSense.Core.Introspection.get_module_subtype(Elixir)
      :alias
  """
  @spec get_module_subtype(module()) :: module_subtype()
  def get_module_subtype(module) do
    has_func = fn f, a -> module_has_function(module, f, a) end

    cond do
      has_func.(:__protocol__, 1) ->
        :protocol

      has_func.(:__impl__, 1) ->
        :implementation

      has_func.(:__struct__, 0) ->
        if Map.get(module.__struct__, :__exception__) do
          :exception
        else
          :struct
        end

      has_func.(:behaviour_info, 1) ->
        :behaviour

      match?("Elixir.Mix.Tasks." <> _, Atom.to_string(module)) ->
        if has_func.(:run, 1) do
          :task
        end

      module == Elixir ->
        :alias

      not has_func.(:module_info, 1) and match?("Elixir." <> _, Atom.to_string(module)) ->
        :alias

      true ->
        nil
    end
  end

  # NOTE does not work for macro
  def module_has_function(Elixir, _func, _arity), do: false

  def module_has_function(module, func, arity) do
    Code.ensure_loaded?(module) and Kernel.function_exported?(module, func, arity)
  end

  def module_is_struct?(module) do
    module_has_function(module, :__struct__, 0)
  end

  def extract_fun_args({{_fun, _}, _line, _kind, args, _doc, _metadata}) do
    (args || [])
    |> Enum.map(&format_doc_arg(&1))
  end

  def extract_fun_args(atom) when atom in [nil, false] do
    []
  end

  # erlang docs have signature included in metadata
  def get_spec_as_string(_module, _function, _arity, :function, %{signature: signature}) do
    [{:attribute, _, :spec, spec}] = signature
    spec |> spec_to_string()
  end

  def get_spec_as_string(_module, function, arity, :macro, %{implementing: behaviour}) do
    TypeInfo.get_callback(behaviour, :"MACRO-#{function}", arity + 1)
    |> spec_to_string(:macrocallback)
  end

  def get_spec_as_string(_module, function, arity, :function, %{implementing: behaviour}) do
    TypeInfo.get_callback(behaviour, function, arity) |> spec_to_string(:callback)
  end

  def get_spec_as_string(module, function, arity, :macro, _) do
    TypeInfo.get_spec(module, :"MACRO-#{function}", arity + 1) |> spec_to_string()
  end

  def get_spec_as_string(module, function, arity, :function, _) do
    TypeInfo.get_spec(module, function, arity) |> spec_to_string()
  end

  def get_specs_text(mod, fun, arity, kind, metadata) do
    for arity <- (arity - Map.get(metadata, :defaults, 0))..arity,
        spec = get_spec_as_string(mod, fun, arity, kind, metadata),
        spec != "",
        do: spec
  end

  # This function is used only for protocols so no macros
  # and we don't expect docs to be nil
  def module_functions_info(module) do
    docs = NormalizedCode.get_docs(module, :docs) || []
    specs = TypeInfo.get_module_specs(module)

    for {{f, a}, _line, func_kind, args, doc, metadata} <- docs, doc != false, into: %{} do
      spec = Map.get(specs, {f, a})

      formatted_args =
        (args || [])
        |> Enum.map(&format_doc_arg(&1))

      desc = extract_summary_from_docs(doc)

      {{f, a}, {func_kind, formatted_args, desc, metadata, spec_to_string(spec, :callback)}}
    end
  end

  def get_callback_ast(module, callback, arity) do
    {{name, _}, [spec | _]} =
      module
      |> Typespec.get_callbacks()
      |> Enum.find(fn {{f, a}, _} ->
        drop_macro_prefix({f, a}) == {callback, arity}
      end)

    Typespec.spec_to_quoted(name, spec)
    |> Macro.prewalk(&drop_macro_env/1)
  end

  defp format_doc_arg({:\\, _, [left, right]}) do
    format_doc_arg(left) <> " \\\\ " <> Macro.to_string(right)
  end

  defp format_doc_arg({var, _, _}) do
    Atom.to_string(var)
  end

  def remove_first_macro_arg(
        {:when, info3, [{:"::", info, [{name, info2, rest_args}, ret]}, var_params]}
      ) do
    "MACRO-" <> rest = Atom.to_string(name)

    sub = [{String.to_atom(rest), info2, rest_args |> tl}, ret]

    {:when, info3, [{:"::", info, sub}, var_params]}
  end

  def remove_first_macro_arg({:"::", info, [{name, info2, [_term_arg | rest_args]}, return]}) do
    "MACRO-" <> rest = Atom.to_string(name)
    {:"::", info, [{String.to_atom(rest), info2, rest_args}, return]}
  end

  def spec_to_string(spec, kind \\ :spec)

  def spec_to_string(nil, _kind) do
    ""
  end

  def spec_to_string({{name, arity}, specs}, kind) when is_atom(name) and is_integer(arity) do
    is_macro = Atom.to_string(name) |> String.starts_with?("MACRO-")

    specs
    |> Enum.map_join("\n", fn spec ->
      quoted =
        Typespec.spec_to_quoted(name, spec)
        |> Macro.prewalk(&drop_macro_env/1)

      quoted =
        if is_macro do
          quoted |> remove_first_macro_arg()
        else
          quoted
        end

      binary = Macro.to_string(quoted)
      "@#{kind} #{binary}" |> String.replace("()", "")
    end)
  end

  def spec_to_string({{_module, name, arity}, specs}, kind)
      when is_atom(name) and is_integer(arity) do
    # spec with module - transform it to moduleless form
    spec_to_string({{name, arity}, specs}, kind)
  end

  @spec actual_module(
          nil | module,
          [{module, module}],
          nil | module,
          # TODO better type
          any,
          ElixirSense.Core.State.mods_funs_to_positions_t()
        ) :: {nil | module, boolean}
  def actual_module(module, aliases, current_module, scope, mods_funs) do
    {m, nil, res, _} =
      actual_mod_fun(
        {module, nil},
        [],
        [],
        aliases,
        current_module,
        scope,
        mods_funs,
        %{},
        {1, 1}
      )

    {m, res}
  end

  @doc ~S"""
  Expand module using aliases list

  ## Examples

      iex> ElixirSense.Core.Introspection.expand_alias(MyList, [])
      MyList
      iex> ElixirSense.Core.Introspection.expand_alias(:erlang_module, [])
      :erlang_module
      iex> ElixirSense.Core.Introspection.expand_alias(MyList, [{MyList, List}])
      List
      iex> ElixirSense.Core.Introspection.expand_alias(MyList.Sub, [{MyList, List}])
      List.Sub
      iex> ElixirSense.Core.Introspection.expand_alias(MyList.Sub, [{MyList, List.Some}])
      List.Some.Sub
      iex> ElixirSense.Core.Introspection.expand_alias(MyList, [{MyList, :lists}])
      :lists
      iex> ElixirSense.Core.Introspection.expand_alias(MyList.Sub, [{MyList, :lists}])
      :"Elixir.lists.Sub"
      iex> ElixirSense.Core.Introspection.expand_alias(Elixir, [{MyList, :lists}])
      Elixir
      iex> ElixirSense.Core.Introspection.expand_alias(E.String, [{E, Elixir}])
      String
      iex> ElixirSense.Core.Introspection.expand_alias(E, [{E, Elixir}])
      Elixir
      iex> ElixirSense.Core.Introspection.expand_alias(nil, [])
      nil
  """
  def expand_alias(mod, aliases) do
    if elixir_module?(mod) do
      [mod_head | mod_tail] = Module.split(mod)

      case Enum.find(aliases, fn {alias_mod, _alias_expansion} ->
             [alias_head] = Module.split(alias_mod)
             alias_head == mod_head
           end) do
        nil ->
          # alias not found
          mod

        {_alias_mod, alias_expansion} ->
          # Elixir alias expansion rules are strange as they allow submodules to aliased erlang modules
          # however when they are expanded an elixir module is created, e.g. in
          # alias :erl, as: E
          # E.Sub.fun()
          # results in
          # :"Elixir.erl.Sub".fun()
          if mod_tail != [] do
            # append submodule to expansion
            Module.concat([alias_expansion | mod_tail])
          else
            # alias expands to erlang module
            alias_expansion
          end
      end
    else
      # erlang module or `Elixir`
      mod
    end
  end

  @spec actual_mod_fun(
          {nil | module, nil | atom},
          [module],
          [module],
          [{module, module}],
          nil | module,
          # TODO better type
          any(),
          ElixirSense.Core.State.mods_funs_to_positions_t(),
          ElixirSense.Core.State.types_t(),
          {pos_integer, pos_integer}
        ) :: {nil | module, nil | atom, boolean, nil | :mod_fun | :type}
  def actual_mod_fun({nil, nil}, _, _, _, _, _, _, _, _), do: {nil, nil, false, nil}

  def actual_mod_fun(
        {mod, fun} = mod_fun,
        imports,
        requires,
        aliases,
        current_module,
        scope,
        mods_funs,
        metadata_types,
        cursor_position
      ) do
    expanded_mod = expand_alias(mod, aliases)

    with {:mod_fun, {nil, nil}} <- {:mod_fun, find_kernel_special_forms_macro(mod_fun)},
         {:mod_fun, {nil, nil}} <-
           {:mod_fun,
            find_function_or_module(
              {expanded_mod, fun},
              current_module,
              scope,
              imports,
              requires,
              mods_funs,
              cursor_position
            )},
         {:type, {nil, nil}} <-
           {:type, find_type({expanded_mod, fun}, current_module, scope, metadata_types)} do
      {expanded_mod, fun, false, nil}
    else
      {kind, {m, f}} -> {m, f, true, kind}
    end
  end

  # local type
  defp find_type({nil, type}, current_module, {:typespec, _, _}, metadata_types) do
    case metadata_types[{current_module, type, nil}] do
      nil ->
        if BuiltinTypes.builtin_type?(type) do
          {nil, type}
        else
          {nil, nil}
        end

      %State.TypeInfo{} ->
        # local types are hoisted, no need to check position
        {current_module, type}
    end
  end

  # Elixir proxy
  defp find_type({Elixir, _type}, _current_module, _scope, _metadata_types), do: {nil, nil}

  # invalid case
  defp find_type({_mod, nil}, _current_module, _scope, _metadata_types), do: {nil, nil}

  # remote type
  defp find_type({mod, type}, _current_module, {:typespec, _, _}, metadata_types) do
    found =
      case metadata_types[{mod, type, nil}] do
        nil ->
          Typespec.get_types(mod)
          |> Enum.any?(fn {kind, {name, _def, _args}} ->
            name == type and kind in [:type, :opaque]
          end)

        %State.TypeInfo{kind: kind} ->
          kind in [:type, :opaque]
      end

    if found do
      {mod, type}
    else
      {nil, nil}
    end
  end

  defp find_type({_mod, _type}, _current_module, _scope, _metadata_types), do: {nil, nil}

  defp find_function_or_module(
         {_mod, fun},
         _current_module,
         {:typespec, _, _},
         _imports,
         _requires,
         _mods_funs,
         _cursor_position
       )
       when fun != nil,
       do: {nil, nil}

  # local call
  defp find_function_or_module(
         {nil, fun},
         current_module,
         _scope,
         imports,
         _requires,
         mods_funs,
         cursor_position
       ) do
    found_in_metadata = mods_funs[{current_module, fun, nil}]

    case found_in_metadata do
      %State.ModFunInfo{} = info ->
        if fun in [:module_info, :behaviour_info, :__info__] do
          {nil, nil}
        else
          if State.ModFunInfo.get_category(info) != :macro or
               List.last(info.positions) < cursor_position do
            # local macros are available after definition
            # local functions are hoisted
            {current_module, fun}
          else
            {nil, nil}
          end
        end

      nil ->
        {functions, macros} = expand_imports(imports, mods_funs)

        found_in_imports =
          Enum.find_value(functions ++ macros, fn {module, imported} ->
            if Keyword.has_key?(imported, fun) do
              {module, fun}
            end
          end)

        if found_in_imports do
          found_in_imports
        else
          {nil, nil}
        end
    end
  end

  # Elixir proxy
  defp find_function_or_module(
         {Elixir, _},
         _current_module,
         _scope,
         _imports,
         _requires,
         _mods_funs,
         _cursor_position
       ),
       do: {nil, nil}

  # module
  defp find_function_or_module(
         {mod, nil},
         _current_module,
         _scope,
         _imports,
         _requires,
         mods_funs,
         _cursor_position
       ) do
    if Map.has_key?(mods_funs, {mod, nil, nil}) or match?({:module, _}, Code.ensure_loaded(mod)) do
      {mod, nil}
    else
      {nil, nil}
    end
  end

  # remote call
  defp find_function_or_module(
         {mod, fun},
         _current_module,
         _imports,
         _scope,
         requires,
         mods_funs,
         _cursor_position
       ) do
    found =
      case mods_funs[{mod, fun, nil}] do
        nil ->
          case get_exports(mod) |> Keyword.get(fun) do
            nil -> false
            {_arity, :function} -> true
            {_arity, :macro} -> mod in requires
          end

        info ->
          is_pub(info.type) and
            (is_function_type(info.type) or mod in requires)
      end

    if found do
      {mod, fun}
    else
      {nil, nil}
    end
  end

  defp find_kernel_special_forms_macro({nil, fun}) when fun not in [:__info__, :module_info] do
    if exported?(Kernel.SpecialForms, fun) do
      {Kernel.SpecialForms, fun}
    else
      {nil, nil}
    end
  end

  defp find_kernel_special_forms_macro({_mod, _fun}) do
    {nil, nil}
  end

  @doc ~S"""
  Tests if term is an elixir module

  ## Examples

      iex> ElixirSense.Core.Introspection.elixir_module?(List)
      true
      iex> ElixirSense.Core.Introspection.elixir_module?(List.Submodule)
      true
      iex> ElixirSense.Core.Introspection.elixir_module?(:lists)
      false
      iex> ElixirSense.Core.Introspection.elixir_module?(:"NotAModule")
      false
      iex> ElixirSense.Core.Introspection.elixir_module?(:"Elixir.SomeModule")
      true
      iex> ElixirSense.Core.Introspection.elixir_module?(:"Elixir.someModule")
      true
      iex> ElixirSense.Core.Introspection.elixir_module?(Elixir.SomeModule)
      true
      iex> ElixirSense.Core.Introspection.elixir_module?(Elixir)
      false
  """
  def elixir_module?(term) when is_atom(term) do
    term == Module.concat(Elixir, term)
  end

  def elixir_module?(_) do
    false
  end

  def is_pub(type), do: type in [:def, :defmacro, :defdelegate, :defguard]
  def is_priv(type), do: type in [:defp, :defmacrop, :defguardp]
  def is_function_type(type), do: type in [:def, :defp, :defdelegate]
  def is_macro_type(type), do: type in [:defmacro, :defmacrop, :defguard, :defguardp]

  def expand_imports(list, mods_funs) do
    {functions, macros} =
      list
      |> Enum.reduce([], fn {module, opts}, acc ->
        all_exported =
          if acc[module] != nil and Keyword.keyword?(opts[:except]) do
            acc[module]
          else
            if Map.has_key?(mods_funs, {module, nil, nil}) do
              mods_funs
              |> Enum.filter(fn {{m, _f, a}, info} ->
                m == module and a != nil and is_pub(info.type)
              end)
              |> Enum.flat_map(fn {{_m, f, _a}, info} ->
                kind = if(is_macro_type(info.type), do: :macro, else: :function)

                for {arity, default_args} <- State.ModFunInfo.get_arities(info),
                    args <- (arity - default_args)..arity do
                  {f, {args, kind}}
                end
              end)
            else
              get_exports(module)
            end
          end

        imported =
          all_exported
          |> Enum.reject(fn
            {:__info__, {1, :function}} ->
              true

            {:module_info, {arity, :function}} when arity in [0, 1] ->
              true

            {:behaviour_info, {1, :function}} ->
              if Version.match?(System.version(), ">= 1.15.0") do
                true
              else
                # elixir < 1.15 imports behaviour_info from erlang behaviours
                # https://github.com/elixir-lang/elixir/commit/4b26edd8c164b46823e1dc1ec34b639cc3563246
                elixir_module?(module)
              end

            {:orelse, {2, :function}} ->
              module == :erlang

            {:andalso, {2, :function}} ->
              module == :erlang

            {name, {arity, kind}} ->
              name_string = name |> Atom.to_string()

              rejected_after_only? =
                cond do
                  opts[:only] == :sigils and not String.starts_with?(name_string, "sigil_") ->
                    true

                  opts[:only] == :macros and kind != :macro ->
                    true

                  opts[:only] == :functions and kind != :function ->
                    true

                  Keyword.keyword?(opts[:only]) ->
                    {name, arity} not in opts[:only]

                  String.starts_with?(name_string, "_") ->
                    true

                  true ->
                    false
                end

              if rejected_after_only? do
                true
              else
                if Keyword.keyword?(opts[:except]) do
                  {name, arity} in opts[:except]
                else
                  false
                end
              end
          end)

        Keyword.put(acc, module, imported)
      end)
      |> Enum.reduce({[], []}, fn {module, imported}, {functions_acc, macros_acc} ->
        {functions, macros} =
          imported
          |> Enum.split_with(fn {_name, {_arity, kind}} -> kind == :function end)

        {append_expanded_module_imports(functions, module, functions_acc),
         append_expanded_module_imports(macros, module, macros_acc)}
      end)

    {Enum.reverse(functions), Enum.reverse(macros)}
  end

  defp append_expanded_module_imports([], _module, acc), do: acc

  defp append_expanded_module_imports(list, module, acc) do
    list = list |> Enum.map(fn {name, {arity, _kind}} -> {name, arity} end)
    [{module, list} | acc]
  end

  def combine_imports({functions, macros}) do
    Enum.reduce(functions, macros, fn {module, imports}, acc ->
      case acc[module] do
        nil -> Keyword.put(acc, module, imports)
        acc_imports -> Keyword.put(acc, module, acc_imports ++ imports)
      end
    end)
  end

  def is_callback(behaviour, fun, arity, metadata) when is_atom(behaviour) do
    metadata_callback =
      metadata.specs
      |> Enum.any?(
        &match?(
          {{^behaviour, ^fun, cb_arity}, %{kind: kind}}
          when kind in [:callback, :macrocallback] and
                 matches_arity?(cb_arity, arity),
          &1
        )
      )

    metadata_callback or
      (Code.ensure_loaded?(behaviour) and
         function_exported?(behaviour, :behaviour_info, 1) and
         behaviour.behaviour_info(:callbacks)
         |> Enum.map(&drop_macro_prefix/1)
         |> Enum.any?(&match?({^fun, cb_arity} when matches_arity?(cb_arity, arity), &1)))
  end

  defp get_fun_args_from_doc_or_typespec(mod, f, arity, args, metadata) do
    # as of otp 25 erlang modules do not return args
    # instead they return typespecs in metadata[:signature]
    case metadata[:signature] do
      nil ->
        if args != nil and length(args) == arity do
          # elixir doc
          args
          |> List.wrap()
          |> Enum.map(&format_doc_arg(&1))
        else
          # as of otp 25 erlang callback implementation do not have signature metadata

          behaviour = metadata[:implementing]

          if arity != 0 and behaviour != nil do
            # try to get callback spec
            # we don't expect macros here
            case TypeInfo.get_callback(behaviour, f, arity) do
              {_, [params | _]} ->
                TypeInfo.extract_params(params) |> Enum.map(&Atom.to_string/1)

              _ ->
                # provide dummy
                Enum.map(1..arity, fn _ -> "term" end)
            end
          else
            # provide dummy
            if arity == 0, do: [], else: Enum.map(1..arity, fn _ -> "term" end)
          end
        end

      [{:attribute, _, :spec, {{^f, ^arity}, [params | _]}}] ->
        # erlang doc with signature meta - moduleless form
        TypeInfo.extract_params(params) |> Enum.map(&Atom.to_string/1)

      [{:attribute, _, :spec, {{^mod, ^f, ^arity}, [params | _]}}] ->
        # erlang doc with signature meta - form with module
        TypeInfo.extract_params(params) |> Enum.map(&Atom.to_string/1)
    end
  end
end
