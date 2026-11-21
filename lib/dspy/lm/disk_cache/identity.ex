defmodule Dspy.LM.DiskCache.Identity do
  @moduledoc false

  alias Dspy.LM.ReqLLM, as: ReqLLMLM
  alias ReqLLM.Providers.OpenAI

  @version 1
  @model_id "gpt-4.1-mini"
  @model_spec "openai:" <> @model_id
  @generation_keys [:temperature, :max_tokens, :max_completion_tokens, :stop, :n]
  @default_keys [:api_key, :base_url | @generation_keys]

  @spec key(term(), term(), term()) :: String.t() | nil
  def key(
        %ReqLLMLM{
          model: @model_spec,
          cache_namespace: namespace,
          default_opts: defaults,
          client_module: ReqLLM,
          context_module: ReqLLM.Context,
          response_module: ReqLLM.Response,
          generation_module: ReqLLM.Generation
        },
        request,
        rollout_id
      )
      when is_nil(rollout_id) or is_integer(rollout_id) do
    with true <- is_binary(namespace) and ReqLLMLM.valid_cache_namespace?(namespace),
         true <- recognized_options?(defaults, @default_keys),
         true <- valid_request?(request),
         true <- Application.get_env(:req, :default_options, []) == [],
         true <- Application.get_env(:req_llm, :finch, []) == [],
         {:ok, OpenAI} <- ReqLLM.provider(:openai),
         {:ok, %LLMDB.Model{provider: :openai, id: @model_id} = model} <-
           resolve_model(),
         true <- responses_model?(model),
         {:ok, operation} <- operation(model, request[:output_contract]),
         {:ok, endpoint} <- endpoint(defaults, model),
         metadata = Map.take(model, [:capabilities, :limits, :cost, :pricing]),
         true <- portable?(metadata) do
      defaults = defaults |> Keyword.take(@generation_keys) |> Map.new()

      per_request =
        request |> Map.take(@generation_keys) |> Map.reject(fn {_key, value} -> is_nil(value) end)

      generation = Map.merge(defaults, per_request)

      # The typed request also contains the complete output contract. Credentials
      # are never read. A namespace identifies the caller's account across key rotations.
      {@version, namespace, :openai_responses, operation, endpoint, @model_spec, metadata,
       generation, request, rollout_id}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    else
      _ -> nil
    end
  rescue
    # ReqLLM registries and configuration can be unavailable during startup.
    _error -> nil
  end

  # Custom LMs, provider/transport overrides, and other routes stay memory-only.
  def key(_lm, _request, _rollout_id), do: nil

  defp recognized_options?(options, allowed) do
    Keyword.keyword?(options) and length(options) == length(Keyword.keys(options) |> Enum.uniq()) and
      Enum.all?(options, fn {key, value} -> key in allowed and valid_option?(key, value) end)
  end

  defp valid_option?(:api_key, _value), do: true
  defp valid_option?(:base_url, value), do: utf8?(value)
  defp valid_option?(:temperature, value), do: is_number(value)

  defp valid_option?(key, value) when key in [:max_tokens, :max_completion_tokens],
    do: is_integer(value) and value > 0

  defp valid_option?(:n, value), do: value === 1

  defp valid_option?(:stop, value) when is_integer(length(value)), do: Enum.all?(value, &utf8?/1)
  defp valid_option?(:stop, value), do: utf8?(value)

  defp valid_request?(%{messages: [_ | _] = messages} = request)
       when not is_struct(request) and is_integer(length(messages)) do
    Enum.all?(messages, &text_message?/1) and
      Enum.all?(request, fn
        {:messages, _messages} ->
          true

        {:tools, nil} ->
          true

        {:output_contract, contract} ->
          is_nil(contract) or (is_map(contract) and portable?(contract))

        {key, value} when key in @generation_keys ->
          is_nil(value) or valid_option?(key, value)

        _other ->
          false
      end)
  end

  defp valid_request?(_request), do: false

  defp text_message?(%{role: role, content: content} = message) when map_size(message) == 2,
    do: role in ["system", "assistant", "user"] and utf8?(content)

  defp text_message?(%{"role" => role, "content" => content} = message)
       when map_size(message) == 2,
       do: role in ["system", "assistant", "user"] and utf8?(content)

  defp text_message?(_message), do: false

  # Generation resolves the catalog spec, then the OpenAI provider normalizes
  # that model struct again before preparing the request.
  defp resolve_model do
    with {:ok, model} <- ReqLLM.model(@model_spec), do: ReqLLM.model(model)
  end

  defp responses_model?(%LLMDB.Model{provider_model_id: provider_model_id} = model) do
    protocol =
      get_in(model, [Access.key(:extra, %{}), :wire, :protocol]) ||
        get_in(model, [Access.key(:extra, %{}), "wire", "protocol"])

    provider_model_id in [nil, @model_id] and protocol == "openai_responses"
  end

  defp operation(_model, nil), do: {:ok, :text}

  defp operation(model, _contract) do
    case OpenAI.determine_output_mode(model, []) do
      :tool_strict -> {:ok, :object}
      _ -> :error
    end
  end

  defp endpoint(defaults, model) do
    provider_config = Application.get_env(:req_llm, :openai, [])

    with true <- recognized_options?(provider_config, [:base_url, :api_key]),
         base =
           defaults[:base_url] || model.base_url || provider_config[:base_url] ||
             registry_base_url() || OpenAI.default_base_url(),
         true <- utf8?(base) and base != "" and String.trim(base) == base,
         {:ok, %URI{userinfo: nil, query: nil, fragment: nil} = uri} <- URI.new(base),
         true <-
           uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
             uri.port in 1..65_535 do
      path = uri.path || ""
      # Req appends the provider path while preserving all existing path segments.
      path = if String.ends_with?(path, "/"), do: path <> "responses", else: path <> "/responses"
      {:ok, {uri.scheme, String.downcase(uri.host), uri.port, path}}
    else
      _ -> :error
    end
  end

  defp registry_base_url do
    case LLMDB.provider(:openai) do
      {:ok, %{base_url: base_url}} -> base_url
      _ -> nil
    end
  end

  defp utf8?(value), do: is_binary(value) and String.valid?(value)

  defp portable?(value) when is_atom(value) or is_number(value), do: true
  defp portable?(value) when is_binary(value), do: utf8?(value)
  defp portable?(value) when is_integer(length(value)), do: Enum.all?(value, &portable?/1)

  defp portable?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, item} -> (is_atom(key) or utf8?(key)) and portable?(item) end)
  end

  defp portable?(_value), do: false
end
