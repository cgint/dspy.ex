defmodule Dspy.Signature.Adapter.Pipeline do
  @moduledoc """
  Centralized signature-adapter pipeline runner.

  This is the single boundary responsible for:
  - formatting an LM request via the active signature adapter
  - invoking the LM
  - parsing adapter outputs
  - emitting lifecycle callbacks around format/call/parse

  It is used by `Dspy.Predict` and `Dspy.ChainOfThought`.
  """

  alias Dspy.{LM, Prediction, PredictorConfig, Settings, Signature}
  alias Dspy.Signature.Adapter.Callbacks
  alias Dspy.Signature.AdapterPipeline
  require Logger

  # Max characters of a non-exception retry/exhaustion reason rendered via
  # inspect/1 in a log line. Keeps deep validation errors from bloating logs.

  @type opts :: [
          adapter: module() | nil,
          lm: Dspy.LM.t() | nil,
          config: PredictorConfig.t(),
          prediction_signature: Signature.t(),
          callbacks: Callbacks.callbacks(),
          max_retries: non_neg_integer(),
          max_output_retries: non_neg_integer()
        ]

  @doc false
  def run_prediction(signature, inputs, demos, opts) do
    case run(signature, inputs, demos, opts) do
      {:ok, {:parsed_choices, prediction}} -> {:ok, prediction}
      {:ok, outputs} -> {:ok, Prediction.new(outputs)}
      {:error, _} = error -> error
    end
  end

  @spec run(Signature.t(), map(), [Dspy.Example.t()], opts()) ::
          {:ok, map() | {:parsed_choices, Prediction.t()}} | {:error, term()}
  def run(%Signature{} = signature, inputs, demos, opts \\ [])
      when is_map(inputs) and is_list(demos) and is_list(opts) do
    adapter = AdapterPipeline.active_adapter(adapter: Keyword.get(opts, :adapter))

    global_callbacks =
      if Process.whereis(Dspy.Settings) do
        Dspy.Settings.get(:callbacks) || []
      else
        []
      end

    program_callbacks = Keyword.get(opts, :callbacks, [])
    call_callbacks = Callbacks.current_call_callbacks()
    callbacks = Callbacks.merge(global_callbacks, program_callbacks, call_callbacks)

    {request_options, cache_options} =
      opts |> Keyword.get(:config, %{}) |> PredictorConfig.execution_options()

    count = Map.get(request_options, :n)
    lm = choice_lm(Keyword.get(opts, :lm), count)

    lm_options = %{
      lm: lm,
      count: count,
      prediction_signature: Keyword.get(opts, :prediction_signature, signature),
      max_retries: Keyword.get(opts, :max_retries, 3),
      request_options: request_options,
      cache_options: cache_options
    }

    max_output_retries =
      case Keyword.fetch(opts, :max_output_retries) do
        {:ok, value} ->
          value

        :error ->
          if Process.whereis(Dspy.Settings) do
            value = Dspy.Settings.get(:max_output_retries)
            if is_integer(value) and value >= 0, do: value, else: 0
          else
            0
          end
      end

    call_id = make_ref()
    max_output_attempts = max_output_retries + 1

    with :ok <- validate_choice_request(count, lm, adapter, signature) do
      do_run_attempt(
        signature,
        inputs,
        demos,
        adapter,
        callbacks,
        call_id,
        1,
        lm_options,
        max_output_retries,
        max_output_attempts
      )
    end
  end

  defp choice_lm(nil, count) when is_integer(count) and count > 1 do
    if Process.whereis(Settings), do: Settings.get(:lm)
  end

  defp choice_lm(lm, _count), do: lm

  defp validate_choice_request(count, lm, adapter, signature)
       when is_integer(count) and count > 1 do
    cond do
      adapter == Dspy.Signature.Adapters.TwoStep ->
        {:error, {:multiple_choices_unsupported, {:adapter, adapter}}}

      Enum.any?(signature.output_fields, &(&1.type == :tool_calls)) ->
        {:error, {:multiple_choices_unsupported, :tool_calls}}

      is_nil(lm) ->
        {:error, :no_lm_configured}

      is_struct(lm) and Code.ensure_loaded?(lm.__struct__) and
        function_exported?(lm.__struct__, :supports?, 2) and
          LM.supports?(lm, :multiple_choices) == false ->
        {:error, {:multiple_choices_unsupported, {:lm, lm.__struct__}}}

      true ->
        :ok
    end
  end

  defp validate_choice_request(_count, _lm, _adapter, _signature), do: :ok

  defp do_run_attempt(
         %Signature{} = signature,
         inputs,
         demos,
         adapter,
         callbacks,
         call_id,
         attempt,
         %{lm: lm, max_retries: max_retries} = lm_options,
         output_retries_left,
         max_output_attempts
       )
       when is_map(inputs) and is_list(demos) and is_atom(adapter) and is_list(callbacks) and
              is_integer(attempt) and attempt >= 1 and is_integer(max_retries) and
              max_retries >= 0 and
              is_integer(output_retries_left) and output_retries_left >= 0 and
              is_integer(max_output_attempts) and max_output_attempts >= 1 do
    meta = meta(call_id, attempt, adapter, signature)

    callbacks = Callbacks.emit(callbacks, :format_start, meta, %{inputs_keys: Map.keys(inputs)})

    with {:ok, request0} <-
           AdapterPipeline.format_request(signature, inputs, demos, adapter: adapter),
         {:ok, request} <- merge_media_parts(signature, inputs, request0),
         {:ok, base_prompt} <- AdapterPipeline.primary_prompt_text(request) do
      request = Map.merge(request, lm_options.request_options)

      callbacks =
        Callbacks.emit(callbacks, :format_end, meta, %{request: request_summary(request, lm)})

      # `base_request` is the request we use as a stable template for prompt replacement
      # during typed-output retries.
      base_request = request

      do_call_and_parse(
        signature,
        inputs,
        demos,
        adapter,
        callbacks,
        call_id,
        attempt,
        lm_options,
        output_retries_left,
        max_output_attempts,
        request,
        base_request,
        base_prompt
      )
    end
  end

  defp do_call_and_parse(
         %Signature{} = signature,
         inputs,
         demos,
         adapter,
         callbacks,
         call_id,
         attempt,
         %{lm: lm, max_retries: max_retries, count: count} = lm_options,
         output_retries_left,
         max_output_attempts,
         request,
         base_request,
         base_prompt
       )
       when is_map(request) and is_map(base_request) and is_binary(base_prompt) and
              is_integer(max_output_attempts) and max_output_attempts >= 1 do
    meta = meta(call_id, attempt, adapter, signature)

    callbacks =
      Callbacks.emit(callbacks, :call_start, meta, %{request: request_summary(request, lm)})

    case call_with_retry_log(request, lm_options, call_id) do
      {:ok, response} ->
        usage_raw = extract_usage(response)

        callbacks =
          Callbacks.emit(callbacks, :call_end, meta, %{
            request: request_summary(request, lm),
            usage: normalize_usage(usage_raw)
          })

        with {:ok, choices} <- response_choices(response, count) do
          response_chars = Enum.sum(Enum.map(choices, &String.length(&1.text)))

          callbacks =
            Callbacks.emit(
              callbacks,
              :parse_start,
              meta,
              with_choice_count(%{response_chars: response_chars}, count)
            )

          case parse_choices(signature, adapter, choices, lm_options) do
            {:ok, result, keys} ->
              _callbacks =
                Callbacks.emit(
                  callbacks,
                  :parse_end,
                  meta,
                  with_choice_count(%{outputs_keys: keys}, count)
                )

              {:ok, result}

            {:error, reason, response_text, index} ->
              choice_index = if is_integer(count) and count > 1, do: index
              payload = with_choice_index(%{error: reason}, choice_index)
              _callbacks = Callbacks.emit(callbacks, :parse_end, meta, payload)

              maybe_retry_output(
                signature,
                inputs,
                demos,
                adapter,
                callbacks,
                call_id,
                attempt,
                lm_options,
                output_retries_left,
                max_output_attempts,
                base_request,
                base_prompt,
                response_text,
                reason,
                choice_index
              )
          end
        end

      {:error, reason} ->
        Logger.debug(
          "dspy.adapter_exhausted kind=transport call_id=#{inspect(call_id)} attempts_used=#{max_retries + 1} last_reason=#{Dspy.LogReason.format(reason)}"
        )

        {:error, reason}
    end
  end

  defp response_choices(response, nil) do
    with {:ok, choice} <- LM.choice_from_response(response),
         {:ok, text} <- LM.text_from_response(response) do
      {:ok, [%{choice | text: text}]}
    end
  end

  defp response_choices(response, count), do: LM.choices_from_response(response, count)

  defp parse_choices(signature, adapter, choices, %{count: count} = lm_options) do
    parse_signature = drop_tool_call_outputs(signature)

    choices
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {choice, index}, {:ok, rows} ->
      with {:ok, parsed} <- parse_choice(adapter, signature, parse_signature, choice),
           row = align_optional_fields(parsed, signature, count),
           :ok <- validate_row_shape(row, rows) do
        {:cont, {:ok, [row | rows]}}
      else
        {:error, reason} -> {:halt, {:error, reason, choice.text, index}}
      end
    end)
    |> case do
      {:ok, [outputs]} when is_nil(count) ->
        {:ok, outputs, Map.keys(outputs)}

      {:ok, rows} ->
        parsed_prediction(Enum.reverse(rows), lm_options.prediction_signature, hd(choices).text)

      {:error, _, _, _} = error ->
        error
    end
  end

  defp parse_choice(adapter, signature, parse_signature, choice) do
    case adapter.parse_outputs(parse_signature, choice.text, choice: choice) do
      outputs when is_map(outputs) -> merge_tool_call_outputs(signature, outputs, choice)
      {:error, _} = error -> error
      other -> {:error, {:parse_failed, other}}
    end
  end

  defp align_optional_fields(outputs, _signature, nil), do: outputs

  defp align_optional_fields(outputs, signature, _count) do
    Enum.reduce(signature.output_fields, outputs, fn field, row ->
      if Map.get(field, :required, true) || Dspy.Attrs.resolve_key(row, field.name) do
        row
      else
        Map.put_new(row, field.name, Map.get(field, :default))
      end
    end)
  end

  defp validate_row_shape(_row, []), do: :ok

  defp validate_row_shape(row, [previous | _]) do
    if MapSet.new(Map.keys(row)) == MapSet.new(Map.keys(previous)),
      do: :ok,
      else: {:error, {:invalid_outputs, :inconsistent_completion_fields}}
  end

  defp parsed_prediction([first | _] = rows, signature, first_text) do
    prediction = Prediction.from_completions(rows, signature)
    {:ok, {:parsed_choices, prediction}, Map.keys(first)}
  rescue
    ArgumentError -> {:error, {:invalid_outputs, :invalid_completion_fields}, first_text, 0}
  end

  defp with_choice_count(payload, count) when is_integer(count) and count > 1,
    do: Map.put(payload, :choices_count, count)

  defp with_choice_count(payload, _count), do: payload

  defp with_choice_index(payload, nil), do: payload
  defp with_choice_index(payload, index), do: Map.put(payload, :choice_index, index)

  defp maybe_retry_output(
         signature,
         inputs,
         demos,
         adapter,
         callbacks,
         call_id,
         attempt,
         %{lm: lm} = lm_options,
         output_retries_left,
         max_output_attempts,
         base_request,
         base_prompt,
         response_text,
         reason,
         choice_index
       )
       when is_map(base_request) and is_binary(base_prompt) and is_integer(max_output_attempts) and
              max_output_attempts >= 1 do
    cond do
      output_retries_left > 0 and output_retryable_reason?(reason) ->
        retry_prompt = build_output_retry_prompt(base_prompt, signature, adapter, reason)

        with {:ok, retry_request} <-
               AdapterPipeline.replace_primary_prompt_text(base_request, retry_prompt) do
          # Treat prompt replacement as the "format" phase for the next attempt.
          next_attempt = attempt + 1
          meta = meta(call_id, next_attempt, adapter, signature)

          Logger.debug(
            "dspy.adapter_retry kind=output call_id=#{inspect(call_id)} attempt=#{next_attempt}/#{max_output_attempts} reason=#{Dspy.LogReason.format(reason)}"
          )

          callbacks =
            Callbacks.emit(callbacks, :format_start, meta, %{inputs_keys: Map.keys(inputs)})

          callbacks =
            Callbacks.emit(callbacks, :format_end, meta, %{
              request: request_summary(retry_request, lm)
            })

          do_call_and_parse(
            signature,
            inputs,
            demos,
            adapter,
            callbacks,
            call_id,
            next_attempt,
            lm_options,
            output_retries_left - 1,
            max_output_attempts,
            retry_request,
            base_request,
            base_prompt
          )
        end

      true ->
        Logger.debug(
          "dspy.adapter_exhausted kind=output call_id=#{inspect(call_id)} attempts_used=#{max_output_attempts} last_reason=#{Dspy.LogReason.format(reason)}"
        )

        {:error, output_parse_failure(reason, response_text, choice_index)}
    end
  end

  defp output_parse_failure(reason, response_text, choice_index) when is_binary(response_text) do
    {:output_parse_failed, reason, with_choice_index(%{raw_output: response_text}, choice_index)}
  end

  defp meta(call_id, attempt, adapter, %Signature{} = signature)
       when is_integer(attempt) and attempt >= 1 do
    %{
      call_id: call_id,
      attempt: attempt,
      adapter: adapter,
      signature_name: signature.name
    }
  end

  defp signature_has_typed_outputs?(%Signature{} = signature) do
    Enum.any?(signature.output_fields, &Map.has_key?(&1, :schema))
  end

  defp output_retryable_reason?({:output_decode_failed, _reason}), do: true
  defp output_retryable_reason?({:output_validation_failed, _details}), do: true
  defp output_retryable_reason?({:missing_required_outputs, _missing}), do: true
  defp output_retryable_reason?({:invalid_output_value, _field, _reason}), do: true
  defp output_retryable_reason?({:invalid_outputs, _other}), do: true
  defp output_retryable_reason?(_other), do: false

  defp json_output_retry_mode?(%Signature{} = signature, adapter) when is_atom(adapter) do
    adapter == Dspy.Signature.Adapters.JSONAdapter or signature_has_typed_outputs?(signature)
  end

  defp build_output_retry_prompt(base_prompt, %Signature{} = signature, adapter, reason)
       when is_binary(base_prompt) and is_atom(adapter) do
    if json_output_retry_mode?(signature, adapter) do
      build_json_output_retry_prompt(base_prompt, signature, reason)
    else
      build_label_output_retry_prompt(base_prompt, signature, reason)
    end
  end

  defp build_json_output_retry_prompt(base_prompt, %Signature{} = signature, reason)
       when is_binary(base_prompt) do
    keys = signature.output_fields |> Enum.map(&Atom.to_string(&1.name)) |> Enum.join(", ")

    schema_hint =
      if signature_has_typed_outputs?(signature) do
        "Use the required output contract above."
      else
        "Do not include any extra text."
      end

    base_prompt <>
      "\n\n" <>
      "Your previous output did not match the required JSON output contract.\n" <>
      "Errors:\n" <>
      format_output_retry_errors(reason) <>
      "\n\n" <>
      "Return JSON only (no markdown fences, no labels, no extra text).\n" <>
      "The top-level JSON object must contain the following keys: #{keys}.\n" <>
      schema_hint
  end

  defp build_label_output_retry_prompt(base_prompt, %Signature{} = signature, reason)
       when is_binary(base_prompt) do
    required =
      signature.output_fields
      |> Enum.filter(& &1.required)

    format_lines =
      required
      |> Enum.map(fn field ->
        label = String.capitalize(Atom.to_string(field.name))
        "#{label}: <value>"
      end)
      |> Enum.join("\n")

    base_prompt <>
      "\n\n" <>
      "Your previous output did not match the required output format.\n" <>
      "Errors:\n" <>
      format_output_retry_errors(reason) <>
      "\n\n" <>
      "Return ONLY the required labeled fields (no markdown fences, no extra text).\n" <>
      "Use this exact format:\n" <>
      format_lines
  end

  defp format_output_retry_errors({:output_decode_failed, decode_reason}) do
    "- output_decode_failed: #{inspect(decode_reason)}"
  end

  defp format_output_retry_errors({:missing_required_outputs, missing}) when is_list(missing) do
    "- missing required output keys: #{Enum.map_join(missing, ", ", &inspect/1)}"
  end

  defp format_output_retry_errors({:invalid_output_value, field, reason}) do
    "- #{inspect(field)}: #{inspect(reason)}"
  end

  defp format_output_retry_errors({:invalid_outputs, other}) do
    "- invalid outputs: #{inspect(other)}"
  end

  defp format_output_retry_errors({:output_validation_failed, %{field: field, errors: errors}})
       when is_list(errors) do
    errors
    |> Enum.take(10)
    |> Enum.map(fn err ->
      path = Map.get(err, :path, "#")
      msg = Map.get(err, :message, inspect(err))
      "- #{field} #{path}: #{msg}"
    end)
    |> Enum.join("\n")
  end

  defp format_output_retry_errors({:output_validation_failed, other}) do
    "- output_validation_failed: #{inspect(other)}"
  end

  defp format_output_retry_errors(other) do
    "- #{inspect(other)}"
  end

  defp drop_tool_call_outputs(%Signature{} = signature) do
    filtered = Enum.reject(signature.output_fields, &(&1.type == :tool_calls))
    %{signature | output_fields: filtered}
  end

  defp merge_tool_call_outputs(%Signature{} = signature, outputs, choice)
       when is_map(outputs) and is_map(choice) do
    tool_call_fields = Enum.filter(signature.output_fields, &(&1.type == :tool_calls))

    case tool_call_fields do
      [] ->
        {:ok, outputs}

      fields ->
        with {:ok, parsed_calls} <- parse_tool_calls(Map.get(choice, :tool_calls)) do
          enriched =
            Enum.reduce(fields, outputs, fn field, acc ->
              cond do
                Map.has_key?(acc, field.name) ->
                  acc

                parsed_calls == [] ->
                  acc

                true ->
                  Map.put(acc, field.name, parsed_calls)
              end
            end)

          missing_required =
            fields
            |> Enum.filter(& &1.required)
            |> Enum.map(& &1.name)
            |> Enum.reject(&Map.has_key?(enriched, &1))

          if missing_required == [] do
            {:ok, enriched}
          else
            {:error, {:missing_required_outputs, missing_required}}
          end
        end
    end
  end

  defp parse_tool_calls(nil), do: {:ok, []}
  defp parse_tool_calls([]), do: {:ok, []}

  defp parse_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn tool_call, {:ok, acc} ->
      case normalize_tool_call(tool_call) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      {:error, _} = error -> error
    end
  end

  defp parse_tool_calls(other), do: {:error, {:invalid_tool_calls, other}}

  defp normalize_tool_call(tool_call) when is_map(tool_call) do
    function = Map.get(tool_call, :function) || Map.get(tool_call, "function") || %{}

    name =
      Map.get(function, :name) || Map.get(function, "name") ||
        Map.get(tool_call, :name) || Map.get(tool_call, "name")

    raw_arguments =
      Map.get(function, :arguments) || Map.get(function, "arguments") ||
        Map.get(tool_call, :arguments) || Map.get(tool_call, "arguments")

    with true <- is_binary(name) and name != "",
         {:ok, args} <- decode_tool_call_arguments(name, raw_arguments) do
      {:ok, %{name: name, args: args}}
    else
      false -> {:error, {:invalid_tool_call, %{reason: :missing_name, tool_call: tool_call}}}
      {:error, _} = error -> error
    end
  end

  defp normalize_tool_call(other),
    do: {:error, {:invalid_tool_call, %{reason: :not_a_map, tool_call: other}}}

  defp decode_tool_call_arguments(_name, nil), do: {:ok, %{}}
  defp decode_tool_call_arguments(_name, args) when is_map(args), do: {:ok, args}
  defp decode_tool_call_arguments(_name, args) when is_list(args), do: {:ok, args}

  defp decode_tool_call_arguments(name, args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {:invalid_tool_call_arguments, %{name: name}}}
    end
  end

  defp decode_tool_call_arguments(name, _args),
    do: {:error, {:invalid_tool_call_arguments, %{name: name}}}

  defp call_with_retry_log(request, %{max_retries: max_retries} = lm_options, call_id)
       when is_map(request) and is_integer(max_retries) and max_retries >= 0 do
    max_attempts = max_retries + 1

    do_call_with_retry_log(request, lm_options, max_retries, max_attempts, call_id)
  end

  defp do_call_with_retry_log(request, lm_options, retries, max_attempts, call_id)
       when is_map(request) and is_integer(retries) and retries >= 0 do
    case Dspy.LM.generate_with_options(lm_options.lm, request, lm_options.cache_options) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} when retries > 0 ->
        Logger.debug(
          "dspy.adapter_retry kind=transport call_id=#{inspect(call_id)} attempt=#{retries + 1}/#{max_attempts} reason=#{Dspy.LogReason.format(reason)}"
        )

        Process.sleep(retry_sleep_ms())
        do_call_with_retry_log(request, lm_options, retries - 1, max_attempts, call_id)

      {:error, _reason} = err ->
        err
    end
  end

  defp retry_sleep_ms do
    Application.get_env(:dspy, :predict_retry_sleep_ms, 1000)
  end

  defp all_images?(list) when is_list(list),
    do: list != [] and Enum.all?(list, &match?(%Dspy.Image{}, &1))

  defp merge_media_parts(%Signature{} = signature, inputs, request)
       when is_map(inputs) and is_map(request) do
    {image_parts, attachment_parts} = extract_media_parts(signature, inputs)
    AdapterPipeline.merge_media(request, attachment_parts, image_parts)
  end

  defp extract_media_parts(%Signature{} = signature, inputs) when is_map(inputs) do
    Enum.reduce(signature.input_fields, {[], []}, fn %{name: name}, {images, attachments} ->
      case fetch_input(inputs, name) do
        {:ok, %Dspy.Attachments{} = a} ->
          {images, attachments ++ Dspy.Attachments.to_message_parts(a)}

        {:ok, %Dspy.Image{} = image} ->
          {images ++ Dspy.Image.format(image), attachments}

        {:ok, list} when is_list(list) ->
          if all_images?(list) do
            {images ++ Enum.flat_map(list, &Dspy.Image.format/1), attachments}
          else
            {images, attachments}
          end

        _ ->
          {images, attachments}
      end
    end)
  end

  defp fetch_input(inputs, name) when is_map(inputs) and is_atom(name) do
    case Map.fetch(inputs, name) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(inputs, Atom.to_string(name))
    end
  end

  defp extract_usage(%{usage: usage}), do: usage
  defp extract_usage(%{"usage" => usage}), do: usage
  defp extract_usage(_), do: nil

  # Normalize usage to the Python/DSPy-style summary map.
  defp normalize_usage(%{} = usage) do
    prompt_tokens =
      usage[:prompt_tokens] || usage["prompt_tokens"] || usage[:input_tokens] ||
        usage["input_tokens"]

    completion_tokens =
      usage[:completion_tokens] || usage["completion_tokens"] || usage[:output_tokens] ||
        usage["output_tokens"]

    total_tokens = usage[:total_tokens] || usage["total_tokens"]

    if is_integer(prompt_tokens) and is_integer(completion_tokens) and is_integer(total_tokens) do
      %{
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: total_tokens
      }
    else
      nil
    end
  end

  defp normalize_usage(_), do: nil

  defp request_summary(request, bound_lm) when is_map(request) do
    messages = Map.get(request, :messages) || Map.get(request, "messages")
    messages_count = if is_list(messages), do: length(messages), else: 0

    lm =
      case bound_lm do
        nil -> if Process.whereis(Dspy.Settings), do: Dspy.Settings.get(:lm), else: nil
        lm -> lm
      end

    model =
      cond do
        is_map(lm) and Map.has_key?(lm, :model) and is_binary(lm.model) -> lm.model
        is_map(lm) and Map.has_key?(lm, "model") and is_binary(lm["model"]) -> lm["model"]
        is_struct(lm) -> Atom.to_string(lm.__struct__)
        true -> nil
      end

    provider =
      if is_binary(model) and String.contains?(model, ":") do
        model |> String.split(":", parts: 2) |> hd()
      else
        nil
      end

    %{
      messages_count: messages_count,
      provider: provider,
      model: model
    }
  end
end
