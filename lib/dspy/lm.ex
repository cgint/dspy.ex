defmodule Dspy.LM do
  @moduledoc """
  Behaviour for language model clients.

  Defines the interface for interacting with different language model providers
  like OpenAI, Anthropic, local models, etc.
  """

  @type content_part :: map()

  @type content :: String.t() | [content_part()]

  @type message :: %{
          role: String.t(),
          content: content()
        }

  @type request :: %{
          messages: [message()] | nil,
          max_tokens: pos_integer() | nil,
          # Some providers (OpenAI reasoning models) use max_completion_tokens instead.
          max_completion_tokens: pos_integer() | nil,
          temperature: float() | nil,
          stop: [String.t()] | nil,
          tools: [map()] | nil,
          # Additional fields for different model types
          input: String.t() | nil,
          text: String.t() | nil,
          prompt: String.t() | nil,
          file: String.t() | nil,
          n: pos_integer() | nil,
          size: String.t() | nil,
          voice: String.t() | nil,
          response_format: map() | nil
        }

  @type response :: %{
          choices: [
            %{
              message: message(),
              finish_reason: String.t() | nil
            }
          ],
          usage: map() | nil
        }

  @type t :: struct()

  @doc """
  Create an LM instance from a model string.

  This is the ergonomic, Python-DSPy-style constructor for configuring real providers.
  Internally it returns a `Dspy.LM.ReqLLM` adapter.

  Accepts model specs in either form:

  - "provider/model" (DSPy intro + DSPex-snakepit style), e.g. "openai/gpt-4.1-mini"
  - "provider:model" (`req_llm` style), e.g. "openai:gpt-4.1-mini"

  Options are forwarded as default provider options (e.g. `:temperature`, `:max_tokens`,
  `:api_key`).

  ## Examples

      {:ok, lm} = Dspy.LM.new("openai/gpt-4.1-mini", api_key: System.get_env("OPENAI_API_KEY"))
      :ok = Dspy.configure(lm: lm)

      # Snakepit-style arity (second arg is ignored positional args list)
      {:ok, lm} = Dspy.LM.new("gemini/gemini-flash-lite-latest", [], temperature: 0.7)
  """
  @spec new(String.t(), keyword() | list(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(model, args_or_opts \\ [], opts \\ [])

  def new(model, args_or_opts, opts)
      when is_binary(model) and is_list(args_or_opts) and is_list(opts) do
    cond do
      opts != [] and Keyword.keyword?(opts) ->
        do_new(model, opts)

      opts == [] and Keyword.keyword?(args_or_opts) ->
        do_new(model, args_or_opts)

      opts == [] and args_or_opts == [] ->
        do_new(model, [])

      true ->
        {:error, {:invalid_lm_new_args, args_or_opts, opts}}
    end
  end

  @doc "Bang variant of `new/2` / `new/3`."
  @spec new!(String.t(), keyword() | list(), keyword()) :: t()
  def new!(model, args_or_opts \\ [], opts \\ []) do
    case new(model, args_or_opts, opts) do
      {:ok, lm} -> lm
      {:error, reason} -> raise ArgumentError, "failed to create LM: #{inspect(reason)}"
    end
  end

  defp do_new(model, opts) when is_binary(model) and is_list(opts) do
    model = String.trim(model)

    if model == "" do
      {:error, :invalid_model}
    else
      normalized = normalize_model_spec(model)

      with {:ok, normalized_opts} <- normalize_lm_new_opts(normalized, opts) do
        {:ok, Dspy.LM.ReqLLM.new(model: normalized, default_opts: normalized_opts)}
      end
    end
  end

  # Normalize model strings into ReqLLM's `provider:model` format.
  #
  # Onboarding-first compatibility:
  # - Accept Python-DSPy-style `gemini/<model>` and `vertex_ai/<model>` prefixes.
  defp normalize_model_spec(model) when is_binary(model) do
    cond do
      String.contains?(model, ":") ->
        case String.split(model, ":", parts: 2) do
          [provider, rest] when rest != "" -> map_provider_alias(provider) <> ":" <> rest
          _ -> model
        end

      String.contains?(model, "/") ->
        case String.split(model, "/", parts: 2) do
          [provider, rest] when rest != "" -> map_provider_alias(provider) <> ":" <> rest
          _ -> model
        end

      true ->
        model
    end
  end

  defp map_provider_alias("gemini"), do: "google"
  defp map_provider_alias("vertex_ai"), do: "google_vertex"
  defp map_provider_alias(other), do: other

  # Translate curated Python-DSPy-style constructor options into ReqLLM options.
  #
  # Currently supported:
  # - `thinking_budget: <non-negative integer>` → `provider_options: [google_thinking_budget: <int>]`
  # - `reasoning_effort: <atom|string>` → `reasoning_effort: <atom>`
  #
  # Precedence:
  # - explicit `provider_options[:google_thinking_budget]` wins over `thinking_budget`
  defp normalize_lm_new_opts(normalized_model, opts)
       when is_binary(normalized_model) and is_list(opts) do
    with {:ok, opts} <- normalize_thinking_budget_opt(opts),
         {:ok, opts} <- normalize_reasoning_effort_opt(opts) do
      # Keep normalized_model in the signature to make it easy to extend later.
      _ = normalized_model
      {:ok, opts}
    end
  end

  defp normalize_thinking_budget_opt(opts) when is_list(opts) do
    thinking_budget = Keyword.get(opts, :thinking_budget)

    cond do
      is_nil(thinking_budget) ->
        {:ok, opts}

      not is_integer(thinking_budget) ->
        {:error, {:invalid_thinking_budget, thinking_budget}}

      thinking_budget < 0 ->
        {:error, {:invalid_thinking_budget, thinking_budget}}

      true ->
        # Drop the ergonomic alias and encode into provider_options.
        opts = Keyword.delete(opts, :thinking_budget)

        provider_opts = Keyword.get(opts, :provider_options, [])

        # If the user provided the raw provider option, keep it.
        provider_opts =
          if Keyword.has_key?(provider_opts, :google_thinking_budget) do
            provider_opts
          else
            Keyword.put(provider_opts, :google_thinking_budget, thinking_budget)
          end

        opts = Keyword.put(opts, :provider_options, provider_opts)
        {:ok, opts}
    end
  end

  @allowed_reasoning_effort_atoms [:none, :minimal, :low, :medium, :high, :xhigh]

  defp normalize_reasoning_effort_opt(opts) when is_list(opts) do
    case Keyword.fetch(opts, :reasoning_effort) do
      :error ->
        {:ok, opts}

      {:ok, nil} ->
        {:ok, opts}

      {:ok, :disable} ->
        {:ok, Keyword.put(opts, :reasoning_effort, :none)}

      {:ok, effort} when is_atom(effort) ->
        if effort in @allowed_reasoning_effort_atoms do
          {:ok, opts}
        else
          {:error, {:invalid_reasoning_effort, effort}}
        end

      {:ok, effort} when is_binary(effort) ->
        normalized = effort |> String.trim() |> String.downcase()

        atom_effort =
          case normalized do
            "disable" -> :none
            "none" -> :none
            "minimal" -> :minimal
            "low" -> :low
            "medium" -> :medium
            "high" -> :high
            "xhigh" -> :xhigh
            other -> {:error, {:invalid_reasoning_effort, other}}
          end

        case atom_effort do
          {:error, _} = err -> err
          atom -> {:ok, Keyword.put(opts, :reasoning_effort, atom)}
        end

      {:ok, other} ->
        {:error, {:invalid_reasoning_effort, other}}
    end
  end

  @doc """
  Generate a completion from the language model.
  """
  @callback generate(lm :: t(), request :: request()) :: {:ok, response()} | {:error, any()}

  @doc """
  Check if the language model supports a specific feature.
  """
  @callback supports?(lm :: t(), feature :: atom()) :: boolean()

  @optional_callbacks [supports?: 2]

  @doc """
  Generate a completion using the configured language model.
  """
  def generate(request) do
    case Dspy.Settings.get(:lm) do
      nil -> {:error, :no_lm_configured}
      lm -> generate(lm, request)
    end
  end

  @doc """
  Generate a completion using a specific language model.

  This function also applies global defaults from `Dspy.Settings` (if running)
  for request fields like `:temperature` and `:max_tokens`, without overriding
  per-request values.
  """
  def generate(lm, request) do
    request = apply_settings_defaults(request)
    started_at_ms = System.monotonic_time(:millisecond)

    if cache_enabled?() and cacheable_request?(request) do
      case Dspy.LM.Cache.fetch(lm, request) do
        {:hit, cached} ->
          duration_ms = System.monotonic_time(:millisecond) - started_at_ms
          maybe_track_usage(lm, request, cached, cache_hit?: true, duration_ms: duration_ms)
          {:ok, cached}

        :miss ->
          case lm.__struct__.generate(lm, request) do
            {:ok, response} ->
              duration_ms = System.monotonic_time(:millisecond) - started_at_ms

              maybe_track_usage(lm, request, response,
                cache_hit?: false,
                duration_ms: duration_ms
              )

              :ok = Dspy.LM.Cache.put(lm, request, response)
              {:ok, response}

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      case lm.__struct__.generate(lm, request) do
        {:ok, response} = ok ->
          duration_ms = System.monotonic_time(:millisecond) - started_at_ms
          maybe_track_usage(lm, request, response, cache_hit?: false, duration_ms: duration_ms)
          ok

        other ->
          other
      end
    end
  end

  @doc """
  Backwards-compatible helper for call sites that pass a prompt string + options.

  Prefer calling `generate/2` with a request map in new code.
  """
  def generate(lm, prompt, opts) when is_binary(prompt) and is_list(opts) do
    generate_text(lm, prompt, opts)
  end

  @doc """
  Generate text from a simple prompt string.
  """
  def generate_text(prompt, opts \\ []) do
    case Dspy.Settings.get(:lm) do
      nil -> {:error, :no_lm_configured}
      lm -> generate_text(lm, prompt, opts)
    end
  end

  @doc """
  Generate text from a prompt string using a specific language model.
  """
  def generate_text(lm, prompt, opts) when is_binary(prompt) and is_list(opts) do
    request = %{
      messages: [%{role: "user", content: prompt}],
      max_tokens: Keyword.get(opts, :max_tokens),
      max_completion_tokens: Keyword.get(opts, :max_completion_tokens),
      temperature: Keyword.get(opts, :temperature),
      stop: Keyword.get(opts, :stop),
      tools: Keyword.get(opts, :tools)
    }

    with {:ok, response} <- generate(lm, request) do
      text_from_response(response)
    end
  end

  @doc """
  Extract the first assistant message content from a model response.

  Accepts both atom-keyed and string-keyed response maps.
  """
  @spec text_from_response(response() | String.t()) :: {:ok, String.t()} | {:error, any()}
  def text_from_response(response) when is_binary(response), do: {:ok, response}

  def text_from_response(response) do
    case get_in(response, [:choices, Access.at(0), :message]) do
      %{"content" => content} when is_binary(content) -> {:ok, content}
      # Support atom keys
      %{content: content} when is_binary(content) -> {:ok, content}
      message -> {:error, {:missing_content, message}}
    end
  end

  @doc """
  Check if a language model supports a feature.
  """
  def supports?(lm, feature) do
    if function_exported?(lm.__struct__, :supports?, 2) do
      lm.__struct__.supports?(lm, feature)
    else
      false
    end
  end

  @doc """
  Create a chat message.
  """
  def message(role, content) do
    %{role: to_string(role), content: content}
  end

  @doc """
  Create a user message.
  """
  def user_message(content), do: message("user", content)

  @doc """
  Create an assistant message.
  """
  def assistant_message(content), do: message("assistant", content)

  @doc """
  Create a system message.
  """
  def system_message(content), do: message("system", content)

  @doc """
  Create a request for embedding generation.
  """
  def embedding_request(text, opts \\ []) do
    %{
      input: text,
      encoding_format: Keyword.get(opts, :encoding_format, "float"),
      dimensions: Keyword.get(opts, :dimensions)
    }
  end

  @doc """
  Create a request for image generation.
  """
  def image_request(prompt, opts \\ []) do
    %{
      prompt: prompt,
      n: Keyword.get(opts, :n, 1),
      size: Keyword.get(opts, :size, "1024x1024"),
      quality: Keyword.get(opts, :quality, "standard"),
      style: Keyword.get(opts, :style, "vivid")
    }
  end

  @doc """
  Create a request for text-to-speech.
  """
  def tts_request(text, opts \\ []) do
    %{
      input: text,
      voice: Keyword.get(opts, :voice, "alloy"),
      response_format: Keyword.get(opts, :response_format, "mp3"),
      speed: Keyword.get(opts, :speed, 1.0)
    }
  end

  @doc """
  Create a request for speech-to-text transcription.
  """
  def transcription_request(file, opts \\ []) do
    %{
      file: file,
      language: Keyword.get(opts, :language),
      prompt: Keyword.get(opts, :prompt),
      response_format: Keyword.get(opts, :response_format, "json"),
      temperature: Keyword.get(opts, :temperature, 0)
    }
  end

  @doc """
  Create a request for content moderation.
  """
  def moderation_request(content, opts \\ []) do
    %{
      input: content,
      model: Keyword.get(opts, :model, "omni-moderation-latest")
    }
  end

  @doc """
  Generate structured output from a signature and inputs.
  """
  def generate_structured_output(signature, inputs) do
    # Build the prompt from the signature.
    # Respect the configured signature adapter for output-format instructions.
    adapter =
      if Process.whereis(Dspy.Settings) do
        Dspy.Settings.get(:adapter) || Dspy.Signature.Adapters.Default
      else
        Dspy.Signature.Adapters.Default
      end

    prompt = Dspy.Signature.to_prompt(signature, adapter: adapter)

    # Add the input values to the prompt
    input_text =
      inputs
      |> Enum.map(fn {key, value} ->
        field_name = key |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
        "#{field_name}: #{inspect(value)}"
      end)
      |> Enum.join("\n")

    full_prompt = "#{prompt}\n\n#{input_text}"

    # Generate the response
    case generate_text(full_prompt) do
      {:ok, response_text} ->
        # Parse the outputs according to the signature
        outputs = Dspy.Signature.parse_outputs(signature, response_text)
        {:ok, outputs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cache_enabled? do
    if Process.whereis(Dspy.Settings) do
      Dspy.Settings.get(:cache) == true
    else
      false
    end
  end

  # Avoid caching multimodal/attachment requests (can include large binaries).
  defp cacheable_request?(request) when is_map(request) do
    case request[:messages] do
      messages when is_list(messages) ->
        Enum.all?(messages, fn msg ->
          content =
            case msg do
              %{content: c} -> c
              %{"content" => c} -> c
              _ -> nil
            end

          is_nil(content) or is_binary(content)
        end)

      _ ->
        true
    end
  end

  defp cacheable_request?(_), do: false

  defp lm_model_key(%{model: model}) when is_binary(model) and model != "", do: model
  defp lm_model_key(%{__struct__: mod}) when is_atom(mod), do: Atom.to_string(mod)
  defp lm_model_key(_), do: "unknown"

  defp maybe_track_usage(lm, request, response, opts) when is_list(opts) do
    if not is_nil(Process.whereis(Dspy.Settings)) and Dspy.Settings.get(:track_usage) == true do
      usage_raw =
        case response do
          %{usage: u} -> u
          %{"usage" => u} -> u
          _ -> nil
        end

      model_key = lm_model_key(lm)

      Dspy.LM.UsageAcc.add(model_key, usage_raw)

      record = %{
        at: DateTime.utc_now(),
        model: model_key,
        cache_hit?: Keyword.get(opts, :cache_hit?, false),
        duration_ms: Keyword.get(opts, :duration_ms),
        usage: normalize_usage_for_history(usage_raw),
        request: summarize_request(request)
      }

      _ = Dspy.LM.History.record(record)
    end

    :ok
  end

  defp normalize_usage_for_history(%{} = usage) do
    # Prefer Python/DSPy-style keys if present.
    prompt_tokens = usage[:prompt_tokens] || usage["prompt_tokens"]
    completion_tokens = usage[:completion_tokens] || usage["completion_tokens"]
    total_tokens = usage[:total_tokens] || usage["total_tokens"]

    # Fallback to ReqLLM-style keys.
    prompt_tokens = prompt_tokens || usage[:input_tokens] || usage["input_tokens"]
    completion_tokens = completion_tokens || usage[:output_tokens] || usage["output_tokens"]
    total_tokens = total_tokens || usage[:total_tokens] || usage["total_tokens"]

    cached_tokens = usage[:cached_tokens] || usage["cached_tokens"]
    reasoning_tokens = usage[:reasoning_tokens] || usage["reasoning_tokens"]

    if is_integer(prompt_tokens) and is_integer(completion_tokens) and is_integer(total_tokens) do
      base = %{
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: total_tokens
      }

      base =
        if is_integer(cached_tokens), do: Map.put(base, :cached_tokens, cached_tokens), else: base

      base =
        if is_integer(reasoning_tokens),
          do: Map.put(base, :reasoning_tokens, reasoning_tokens),
          else: base

      base
    else
      nil
    end
  end

  defp normalize_usage_for_history(_other), do: nil

  defp summarize_request(%{messages: msgs}) when is_list(msgs) do
    %{message_count: length(msgs)}
  end

  defp summarize_request(%{"messages" => msgs}) when is_list(msgs) do
    %{message_count: length(msgs)}
  end

  defp summarize_request(_other), do: %{}

  defp apply_settings_defaults(request) when is_map(request) do
    if Process.whereis(Dspy.Settings) do
      request
      |> put_default(:temperature, Dspy.Settings.get(:temperature))
      |> put_default(:max_tokens, Dspy.Settings.get(:max_tokens))
      |> put_default(:max_completion_tokens, Dspy.Settings.get(:max_completion_tokens))
    else
      request
    end
  end

  defp apply_settings_defaults(other), do: other

  defp put_default(request, _key, nil), do: request

  defp put_default(request, key, default) do
    case Map.get(request, key) do
      nil -> Map.put(request, key, default)
      _ -> request
    end
  end
end
