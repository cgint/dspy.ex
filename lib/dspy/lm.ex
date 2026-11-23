defmodule Dspy.LM do
  @moduledoc """
  Behaviour for language model clients.

  Defines the interface for interacting with different language model providers
  like OpenAI, Anthropic, local models, etc.
  """

  alias Dspy.{Lifecycle, Telemetry}
  alias Dspy.LM.{HistoryCapture, HistoryPayload}
  alias Dspy.Signature.Adapter.Callbacks

  @max_captured_message_count 256

  @type content_part :: map()

  @type content :: String.t() | [content_part()]

  @type message :: %{
          role: String.t(),
          content: content()
        }

  @type request :: %{
          optional(:tool_choice) => atom() | String.t() | map() | nil,
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

  @doc "Returns whether the LM handles transport retries itself."
  @spec owns_transport_retries?(term()) :: boolean()
  def owns_transport_retries?(%Dspy.LM.ReqLLM{}), do: true
  def owns_transport_retries?(_), do: false

  @doc """
  Create an LM instance from a model string.

  This is the ergonomic, Python-DSPy-style constructor for configuring real providers.
  Internally it returns a `Dspy.LM.ReqLLM` adapter.

  Accepts model specs in either form:

  - "provider/model" (DSPy intro + DSPex-snakepit style), e.g. "openai/gpt-4.1-mini"
  - "provider:model" (`req_llm` style), e.g. "openai:gpt-4.1-mini"

  Options are forwarded as default provider options (e.g. `:temperature`, `:max_tokens`,
  `:api_key`). `:cache_namespace` identifies the provider account for eligible
  disk cache entries.

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
      {namespace, opts} = Keyword.pop(opts, :cache_namespace)

      with true <- Dspy.LM.ReqLLM.valid_cache_namespace?(namespace),
           {:ok, normalized_opts} <- normalize_lm_new_opts(normalized, opts) do
        {:ok,
         Dspy.LM.ReqLLM.new(
           model: normalized,
           cache_namespace: namespace,
           default_opts: normalized_opts
         )}
      else
        false -> {:error, :invalid_cache_namespace}
        {:error, _} = error -> error
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
  Generate one text completion and call `on_delta` for each text fragment.

  Invoke `on_delta` in the process that called `stream_generate/3`.
  Return the normalized completion after the stream ends. A callback returning
  `:halt` cancels the stream. A callback returning `{:error, reason}` aborts it.
  """
  @callback stream_generate(lm :: t(), request :: request(), on_delta :: (String.t() -> term())) ::
              {:ok, response()} | {:error, term()}

  @doc """
  Check if the language model supports a specific feature.

  Return `true` for `:structured_streaming` when `stream_generate/3` accepts
  a map output contract and emits its JSON response fragments.
  """
  @callback supports?(lm :: t(), feature :: atom()) :: boolean()

  @doc """
  Train on adapter-formatted examples and return the trained LM binding.

  Implement this optional callback to support fine-tuning.
  The callback receives the training rows and caller-supplied training options.
  """
  @callback finetune(lm :: t(), training_rows :: [map()], train_kwargs :: keyword() | map()) ::
              {:ok, t()} | {:error, term()}

  @optional_callbacks [supports?: 2, stream_generate: 3, finetune: 3]

  @doc false
  def validate_binding!(nil), do: nil

  def validate_binding!(lm) do
    if is_struct(lm) and Code.ensure_loaded?(lm.__struct__) and
         function_exported?(lm.__struct__, :generate, 2) do
      lm
    else
      raise ArgumentError, "expected lm: to be a Dspy.LM struct or nil"
    end
  end

  @doc """
  Generate a completion using the configured language model.
  """
  def generate(request), do: generate_with_options(nil, request, [])

  @doc """
  Generate a completion using a specific language model.

  This function also applies global defaults from `Dspy.Settings` (if running)
  for request fields like `:temperature` and `:max_tokens`, without overriding
  per-request values.
  """
  def generate(lm, request) do
    generate_request(lm, request, [])
  end

  @doc """
  Stream a single completion using an LM that implements streaming.

  Applies the same request defaults as `generate/2`. A delta is a text fragment
  in provider order. A callback returning `:halt` yields `{:error, :cancelled}`.
  A callback returning `{:error, reason}` stops the stream with that error.
  Streaming bypasses DSPy caching and retries.

  A map `:output_contract` requires an LM that advertises
  `:structured_streaming`. Its deltas are JSON fragments.
  """
  @spec stream_generate(t(), request(), (String.t() -> term())) ::
          {:ok, response()} | {:error, term()}
  def stream_generate(lm, request, on_delta),
    do: stream_generate_with_options(lm, request, on_delta, :uncached)

  @doc false
  def stream_generate_with_options(%module{} = lm, request, on_delta, opts)
      when is_map(request) and is_function(on_delta, 1) do
    with true <- Code.ensure_loaded?(module) and function_exported?(module, :stream_generate, 3),
         {:ok, _operation} <- stream_operation(lm, request) do
      opts = if opts == :uncached, do: opts, else: Keyword.put(opts, :streaming?, true)
      generate = &module.stream_generate(lm, &1, on_delta)
      observed_request(lm, request, opts, generate)
    else
      false -> {:error, :streaming_unsupported}
      {:error, _} = error -> error
    end
  end

  @doc false
  def stream_operation(lm, request) do
    contract = stream_option(request, :output_contract)

    operation =
      if is_map(contract) and not is_struct(contract) and
           supports?(lm, :structured_streaming) === true do
        {:object, contract}
      else
        :text
      end

    with :ok <- validate_stream_options(request, operation), do: {:ok, operation}
  end

  @doc false
  def validate_stream_options(options), do: validate_stream_options(options, :text)

  defp validate_stream_options(options, operation) do
    unsupported =
      Enum.find([:output_contract, :response_format, :tools, :tool_choice, :n], fn key ->
        not streaming_option_allowed?(key, stream_option(options, key), operation)
      end)

    if unsupported, do: {:error, {:unsupported_streaming_option, unsupported}}, else: :ok
  end

  defp stream_option(%{} = options, key) do
    case Dspy.Attrs.fetch_map(options, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp stream_option(options, key) when is_list(options), do: Keyword.get(options, key)
  defp stream_option(_options, _key), do: nil

  defp streaming_option_allowed?(_key, nil, _operation), do: true
  defp streaming_option_allowed?(:output_contract, contract, {:object, contract}), do: true
  defp streaming_option_allowed?(:tools, [], _operation), do: true
  defp streaming_option_allowed?(:n, 1, _operation), do: true

  defp streaming_option_allowed?(:response_format, %{} = format, _operation),
    do: stream_option(format, :type) in [:text, "text"]

  defp streaming_option_allowed?(_key, _value, _operation), do: false

  @doc false
  def generate_with_options(nil, request, opts) do
    case Dspy.Settings.get(:lm) do
      nil -> {:error, :no_lm_configured}
      lm -> generate_request(lm, request, opts)
    end
  end

  def generate_with_options(lm, request, opts), do: generate_request(lm, request, opts)

  defp generate_request(lm, request, opts),
    do: observed_request(lm, request, opts, &lm.__struct__.generate(lm, &1))

  defp observed_request(lm, request, opts, generate),
    do: observe_generation(lm, &do_generate_request(lm, request, opts, generate, &1, &2))

  defp observe_generation(lm, generation) do
    {callbacks, telemetry?} = Dspy.Settings.lifecycle_observability()
    captures = HistoryCapture.current()

    with %{__struct__: type} when is_atom(type) <- lm,
         handlers = Callbacks.lm_handlers(callbacks),
         true <- telemetry? or handlers != [] or captures != [] do
      capture =
        if captures != [], do: {captures, Lifecycle.active_call_id()}

      Lifecycle.run(
        type,
        handlers,
        {:lm_start, :lm_end},
        fn -> generation.(telemetry?, capture) end,
        nil,
        telemetry?
      )
    else
      _ -> generation.(false, nil)
    end
  end

  defp do_generate_request(lm, request, opts, generate, telemetry?, capture) do
    request = apply_settings_defaults(request)
    started_at_ms = System.monotonic_time(:millisecond)

    if opts != :uncached and cache_enabled?() and cacheable_request?(request) do
      rollout_id = Keyword.get_lazy(opts, :rollout_id, fn -> Dspy.Settings.get(:rollout_id) end)
      cache_opts = [rollout_id: rollout_id, table: Dspy.LM.Cache.table_ref()]

      case fetch_cached_response(lm, request, cache_opts) do
        {:hit, cached} ->
          duration_ms = System.monotonic_time(:millisecond) - started_at_ms

          record_success(lm, request, cached, telemetry?, capture,
            cache_hit?: true,
            duration_ms: duration_ms
          )

          case Keyword.get(opts, :on_cache_hit) do
            nil -> {:ok, cached}
            notify -> with :ok <- notify.(), do: {:ok, cached}
          end

        {:miss, disk} ->
          case generate.(request) do
            {:ok, response} ->
              duration_ms = System.monotonic_time(:millisecond) - started_at_ms

              record_success(lm, request, response, telemetry?, capture,
                cache_hit?: false,
                duration_ms: duration_ms
              )

              if cacheable_response?(response, Keyword.get(opts, :streaming?, false)) do
                :ok = Dspy.LM.Cache.put(lm, request, response, cache_opts)
                :ok = maybe_store_disk(disk, lm, request, response, cache_opts)
              end

              {:ok, response}

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      case generate.(request) do
        {:ok, response} = ok ->
          duration_ms = System.monotonic_time(:millisecond) - started_at_ms

          record_success(lm, request, response, telemetry?, capture,
            cache_hit?: false,
            duration_ms: duration_ms
          )

          ok

        other ->
          other
      end
    end
  end

  defp cacheable_response?(_response, false), do: true

  defp cacheable_response?(response, true) do
    # An HTTP EOF without a provider completion can still return an OK response.
    case stream_option(response, :choices) do
      choices when is_integer(length(choices)) ->
        Enum.all?(choices, fn choice ->
          stream_option(choice, :finish_reason) not in [
            :incomplete,
            :cancelled,
            :error,
            "incomplete",
            "cancelled",
            "error"
          ]
        end)

      _ ->
        true
    end
  end

  defp fetch_cached_response(lm, request, opts) do
    case Dspy.LM.Cache.fetch(lm, request, opts) do
      {:hit, _} = hit ->
        hit

      :miss ->
        with epoch when is_reference(epoch) <- Dspy.LM.DiskCache.context(),
             key when is_binary(key) <- disk_key(lm, request, opts) do
          case Dspy.LM.DiskCache.fetch(epoch, key) do
            {:hit, response} = hit ->
              :ok = Dspy.LM.Cache.put(lm, request, response, opts)
              hit

            :miss ->
              {:miss, {epoch, key}}
          end
        else
          nil -> {:miss, nil}
        end
    end
  end

  defp maybe_store_disk(nil, _lm, _request, _response, _opts), do: :ok

  defp maybe_store_disk({epoch, key}, lm, request, response, opts) do
    # The provider's effective route or options can change during generation.
    if disk_key(lm, request, opts) == key do
      Dspy.LM.DiskCache.put(epoch, key, response, Keyword.fetch!(opts, :table))
    else
      :ok
    end
  end

  defp disk_key(lm, request, opts) do
    Dspy.LM.DiskCache.Identity.key(lm, request, Keyword.fetch!(opts, :rollout_id))
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
  Extract normalized first-choice content and tool_calls from a model response.
  """
  @spec choice_from_response(response() | String.t()) ::
          {:ok, %{text: String.t() | nil, tool_calls: list() | nil | any(), raw: map()}}
          | {:error, any()}
  def choice_from_response(response) when is_binary(response) do
    {:ok, %{text: response, tool_calls: nil, raw: %{content: response}}}
  end

  def choice_from_response(response) do
    with {:ok, message} <- first_choice_message(response) do
      {:ok, normalize_choice_message(message)}
    end
  end

  @doc false
  @spec choices_from_response(response() | String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def choices_from_response(response, count) do
    with choices when is_integer(length(choices)) <- response_choices(response),
         :ok <- check_choice_count(length(choices), count) do
      choices
      |> Enum.reduce_while({:ok, []}, fn choice, {:ok, acc} ->
        with {:ok, message} <- choice_message(choice),
             %{text: text} = choice when is_binary(text) <- normalize_choice_message(message) do
          {:cont, {:ok, [choice | acc]}}
        else
          {:error, _} = error -> {:halt, error}
          _ -> {:halt, {:error, {:missing_content, nil}}}
        end
      end)
      |> case do
        {:ok, choices} -> {:ok, Enum.reverse(choices)}
        {:error, _} = error -> error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, {:missing_content, nil}}
    end
  end

  defp response_choices(response) when is_binary(response), do: [%{message: %{content: response}}]

  defp response_choices(response) when is_map(response),
    do: Map.get(response, :choices) || Map.get(response, "choices")

  defp response_choices(_), do: nil

  defp check_choice_count(count, count), do: :ok

  defp check_choice_count(actual, expected),
    do: {:error, {:unexpected_choice_count, %{expected: expected, actual: actual}}}

  defp normalize_choice_message(message) do
    text = Map.get(message, :content) || Map.get(message, "content")

    %{
      text: if(is_binary(text), do: text, else: nil),
      # Retain malformed tool calls so the pipeline can report its merge error.
      tool_calls: Map.get(message, :tool_calls) || Map.get(message, "tool_calls"),
      raw: message
    }
  end

  @doc """
  Extract the first assistant message content from a model response.

  Accepts both atom-keyed and string-keyed response maps.
  """
  @spec text_from_response(response() | String.t()) :: {:ok, String.t()} | {:error, any()}
  def text_from_response(response) when is_binary(response), do: {:ok, response}

  def text_from_response(response) do
    with {:ok, choice} <- choice_from_response(response),
         text when is_binary(text) <- Map.get(choice, :text) do
      {:ok, text}
    else
      {:error, _} = error -> error
      _ -> {:error, {:missing_content, nil}}
    end
  end

  defp first_choice_message(response) when is_map(response) do
    case response_choices(response) do
      [first | _] -> choice_message(first)
      _ -> {:error, {:missing_content, nil}}
    end
  end

  defp first_choice_message(_), do: {:error, {:missing_content, nil}}

  defp choice_message(choice) when is_map(choice) do
    case Map.get(choice, :message) || Map.get(choice, "message") do
      message when is_map(message) -> {:ok, message}
      other -> {:error, {:missing_content, other}}
    end
  end

  defp choice_message(_), do: {:error, {:missing_content, nil}}

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

  defp record_success(lm, request, response, telemetry?, capture, opts) do
    track_usage? =
      not is_nil(Process.whereis(Dspy.Settings)) and Dspy.Settings.get(:track_usage) == true

    if telemetry? or track_usage? or capture != nil do
      usage_raw = response_usage(response)
      usage = normalize_usage_for_history(usage_raw)
      cache_hit? = Keyword.fetch!(opts, :cache_hit?)

      if telemetry?, do: Telemetry.record(:lm, %{cache_hit?: cache_hit?}, usage || %{})

      if track_usage? or capture != nil do
        model_key = lm_model_key(lm)

        record = %{
          at: DateTime.utc_now(),
          model: model_key,
          cache_hit?: cache_hit?,
          duration_ms: Keyword.get(opts, :duration_ms),
          usage: usage
        }

        if track_usage? do
          Dspy.LM.UsageAcc.add(model_key, usage_raw)
          Dspy.LM.History.record(Map.put(record, :request, summarize_request(request)))
        end

        if capture, do: record_capture(capture, record, request, response)
      end
    end

    :ok
  end

  defp record_capture({scopes, parent_call_id}, record, request, response) do
    record =
      Map.merge(record, %{
        model: HistoryPayload.model_label(record.model),
        call_id: Lifecycle.active_call_id(),
        request: summarize_captured_request(request)
      })

    record =
      if is_reference(parent_call_id),
        do: Map.put(record, :parent_call_id, parent_call_id),
        else: record

    HistoryCapture.record(scopes, record, request, response)
  end

  defp response_usage(%{usage: usage}), do: usage
  defp response_usage(%{"usage" => usage}), do: usage
  defp response_usage(_response), do: nil

  defp normalize_usage_for_history(%{} = usage) do
    prompt_tokens =
      Map.get(usage, :prompt_tokens) || Map.get(usage, "prompt_tokens") ||
        Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens")

    completion_tokens =
      Map.get(usage, :completion_tokens) || Map.get(usage, "completion_tokens") ||
        Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens")

    total_tokens = Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens")
    cached_tokens = Map.get(usage, :cached_tokens) || Map.get(usage, "cached_tokens")
    reasoning_tokens = Map.get(usage, :reasoning_tokens) || Map.get(usage, "reasoning_tokens")

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

  defp summarize_request(%{messages: msgs}) when is_integer(length(msgs)) do
    %{message_count: length(msgs)}
  end

  defp summarize_request(%{"messages" => msgs}) when is_integer(length(msgs)) do
    %{message_count: length(msgs)}
  end

  defp summarize_request(_other), do: %{}

  defp summarize_captured_request(%{messages: messages}) when is_list(messages),
    do: count_captured_messages(messages, 0)

  defp summarize_captured_request(%{"messages" => messages}) when is_list(messages),
    do: count_captured_messages(messages, 0)

  defp summarize_captured_request(_other), do: %{}

  defp count_captured_messages([], count), do: %{message_count: count}

  defp count_captured_messages([_message | rest], count) when count < @max_captured_message_count,
    do: count_captured_messages(rest, count + 1)

  defp count_captured_messages(_unread, count),
    do: %{message_count: count, message_count_truncated?: true}

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
