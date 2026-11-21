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

  alias Dspy.{Lifecycle, LM, Prediction, PredictorConfig, Settings, Signature, Telemetry}
  alias Dspy.Refine.Advice
  alias Dspy.Signature.Adapter.Callbacks
  alias Dspy.Signature.AdapterPipeline
  require Logger

  # Max characters of a non-exception retry/exhaustion reason rendered via
  # inspect/1 in a log line. Keeps deep validation errors from bloating logs.

  @type opts :: [
          adapter: module() | nil,
          lm: Dspy.LM.t() | nil,
          forced_tool: String.t() | nil,
          prompt_advice: Advice.binding(),
          on_terminal_parse_failure: (map(), term() -> :ok) | nil,
          config: PredictorConfig.t(),
          prediction_signature: Signature.t(),
          callbacks: Callbacks.callbacks(),
          max_retries: non_neg_integer(),
          max_output_retries: non_neg_integer()
        ]

  @doc false
  def run_prediction(signature, inputs, demos, opts),
    do: run_prediction(signature, inputs, demos, nil, opts)

  @doc false
  def run_prediction(signature, inputs, demos, on_delta, opts) do
    case run(signature, inputs, demos, on_delta, opts) do
      {:ok, {:parsed_choices, prediction}} -> {:ok, prediction}
      {:ok, outputs} -> {:ok, Prediction.new(outputs)}
      {:error, _} = error -> error
    end
  end

  @spec run(Signature.t(), map(), [Dspy.Example.t()], opts()) ::
          {:ok, map() | {:parsed_choices, Prediction.t()}} | {:error, term()}
  def run(%Signature{} = signature, inputs, demos, opts \\ [])
      when is_map(inputs) and is_list(demos) and is_list(opts),
      do: run(signature, inputs, demos, nil, opts)

  defp run(%Signature{} = signature, inputs, demos, on_delta, opts)
       when is_map(inputs) and is_list(demos) and is_list(opts) do
    adapter = AdapterPipeline.active_adapter(adapter: Keyword.get(opts, :adapter))

    {global_callbacks, telemetry?} = Settings.lifecycle_observability()

    program_callbacks = Keyword.get(opts, :callbacks, [])
    call_callbacks = Callbacks.current_call_callbacks()
    callbacks = Callbacks.merge(global_callbacks, program_callbacks, call_callbacks)

    {request_options, cache_options} =
      opts |> Keyword.get(:config, %{}) |> PredictorConfig.execution_options()

    count = Map.get(request_options, :n)
    lm = choice_lm(Keyword.get(opts, :lm), count)

    lm_options = %{
      lm: lm,
      on_delta: on_delta,
      count: count,
      prediction_signature: Keyword.get(opts, :prediction_signature, signature),
      max_retries: if(on_delta, do: 0, else: Keyword.get(opts, :max_retries, 3)),
      request_options: force_tool(request_options, Keyword.get(opts, :forced_tool)),
      prompt_advice: Keyword.get(opts, :prompt_advice),
      on_terminal_parse_failure: Keyword.get(opts, :on_terminal_parse_failure),
      telemetry?: telemetry?,
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

    max_output_retries = if on_delta, do: 0, else: max_output_retries
    call_id = make_ref()
    max_output_attempts = max_output_retries + 1

    meta = meta(call_id, adapter, signature)

    run = fn ->
      with :ok <- validate_streaming_adapter(adapter, on_delta),
           :ok <- validate_choice_request(count, lm, adapter, signature) do
        do_run_attempt(
          signature,
          inputs,
          demos,
          adapter,
          callbacks,
          meta,
          lm_options,
          max_output_retries,
          max_output_attempts
        )
      end
    end

    if telemetry? do
      Telemetry.span(:adapter, meta, fn ->
        Telemetry.record(:adapter, %{}, %{output_attempts: 0, transport_attempts: 0})
        Lifecycle.with_active_call_id(call_id, run)
      end)
    else
      run.()
    end
  end

  defp validate_streaming_adapter(Dspy.Signature.Adapters.TwoStep = adapter, on_delta)
       when is_function(on_delta, 1),
       do: {:error, {:unsupported_streaming_adapter, adapter}}

  defp validate_streaming_adapter(_adapter, _on_delta), do: :ok

  defp force_tool(options, nil), do: options

  defp force_tool(options, name) when is_binary(name) do
    Map.merge(options, %{
      tool_choice: %{type: "function", function: %{name: name}},
      reasoning_effort: nil
    })
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

  defp complete_phase(callbacks, end_event, meta, work) do
    {result, payload} =
      try do
        work.()
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          status = if kind == :error, do: :raise, else: kind
          Callbacks.emit(callbacks, end_event, meta, %{status: status})
          :erlang.raise(kind, reason, stacktrace)
      end

    {result, Callbacks.emit(callbacks, end_event, meta, payload)}
  end

  defp do_run_attempt(
         %Signature{} = signature,
         inputs,
         demos,
         adapter,
         callbacks,
         meta,
         %{lm: lm, max_retries: max_retries} = lm_options,
         output_retries_left,
         max_output_attempts
       )
       when is_map(inputs) and is_list(demos) and is_atom(adapter) and is_list(callbacks) and
              is_integer(max_retries) and
              max_retries >= 0 and
              is_integer(output_retries_left) and output_retries_left >= 0 and
              is_integer(max_output_attempts) and max_output_attempts >= 1 do
    if lm_options.telemetry?, do: Telemetry.record(:adapter, %{}, %{output_attempts: 1})
    callbacks = Callbacks.emit(callbacks, :format_start, meta, %{inputs_keys: Map.keys(inputs)})

    {formatted, callbacks} =
      complete_phase(callbacks, :format_end, meta, fn ->
        with {:ok, request0} <-
               AdapterPipeline.format_request(signature, inputs, demos, adapter: adapter),
             {:ok, request} <- AdapterPipeline.merge_input_media(signature, inputs, request0),
             {:ok, base_prompt} <- AdapterPipeline.primary_prompt_text(request) do
          request = Map.merge(request, lm_options.request_options)
          {{:ok, request, base_prompt}, %{request: request_summary(request, lm)}}
        else
          {:error, _reason} = error -> {error, %{status: :error}}
        end
      end)

    with {:ok, request, base_prompt} <- formatted do
      do_call_and_parse(
        signature,
        inputs,
        demos,
        adapter,
        callbacks,
        meta,
        lm_options,
        output_retries_left,
        max_output_attempts,
        request,
        request,
        base_prompt
      )
    end
  end

  defp append_advice(request, binding) do
    case Advice.text(binding) do
      nil ->
        {:ok, request}

      advice ->
        with {:ok, prompt} <- AdapterPipeline.primary_prompt_text(request) do
          advised = prompt <> "\n\n[Refine feedback]\n" <> advice <> "\n[/Refine feedback]"
          AdapterPipeline.replace_primary_prompt_text(request, advised)
        end
    end
  end

  defp do_call_and_parse(
         %Signature{} = signature,
         inputs,
         demos,
         adapter,
         callbacks,
         %{call_id: call_id} = meta,
         %{lm: lm, count: count} = lm_options,
         output_retries_left,
         max_output_attempts,
         request,
         base_request,
         base_prompt
       )
       when is_map(request) and is_map(base_request) and is_binary(base_prompt) and
              is_integer(max_output_attempts) and max_output_attempts >= 1 do
    callbacks =
      Callbacks.emit(callbacks, :call_start, meta, %{request: request_summary(request, lm)})

    {called, callbacks} =
      complete_phase(callbacks, :call_end, meta, fn ->
        case call_with_retry_log(request, lm_options, call_id) do
          {:ok, response} = success ->
            {success,
             %{
               request: request_summary(request, lm),
               usage: response |> extract_usage() |> normalize_usage()
             }}

          {:error, reason, attempts_used} ->
            Logger.debug(
              "dspy.adapter_exhausted kind=transport call_id=#{inspect(call_id)} attempts_used=#{attempts_used} last_reason=#{Dspy.LogReason.format(reason)}"
            )

            {{:error, reason}, %{status: :error}}
        end
      end)

    with {:ok, response} <- called,
         {:ok, choices} <- response_choices(response, count, signature) do
      response_chars = Enum.sum(Enum.map(choices, &String.length(&1.text)))

      callbacks =
        Callbacks.emit(
          callbacks,
          :parse_start,
          meta,
          with_choice_count(%{response_chars: response_chars}, count)
        )

      # An output retry keeps the state carried into parse_end.
      {parsed, _callbacks} =
        complete_phase(callbacks, :parse_end, meta, fn ->
          case parse_choices(signature, adapter, choices, lm_options) do
            {:ok, result, keys} ->
              {{:ok, result}, with_choice_count(%{outputs_keys: keys}, count)}

            {:error, reason, response_text, index} ->
              choice_index = if is_integer(count) and count > 1, do: index
              payload = with_choice_index(%{error: reason}, choice_index)
              {{:error, reason, response_text, choice_index}, payload}
          end
        end)

      case parsed do
        {:ok, _result} = success ->
          success

        {:error, reason, response_text, choice_index} ->
          maybe_retry_output(
            signature,
            inputs,
            demos,
            adapter,
            callbacks,
            meta,
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
  end

  defp response_choices(response, nil, signature) do
    with {:ok, choice} <- LM.choice_from_response(response) do
      cond do
        is_binary(choice.text) ->
          {:ok, [choice]}

        structured_tool_calls?(signature) and is_nil(tool_value(choice.raw, :content)) ->
          {:ok, [%{choice | text: ""}]}

        true ->
          {:error, {:missing_content, nil}}
      end
    end
  end

  defp response_choices(response, count, _signature),
    do: LM.choices_from_response(response, count)

  defp parse_choices(signature, adapter, choices, %{count: count} = lm_options) do
    choices
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {choice, index}, {:ok, rows} ->
      with {:ok, parsed} <- parse_choice(adapter, signature, choice),
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

  defp parse_choice(adapter, signature, choice) do
    parse_signature = tool_parse_signature(signature, choice)

    case parse_text_outputs(adapter, parse_signature, choice, structured_tool_calls?(signature)) do
      outputs when is_map(outputs) -> merge_tool_call_outputs(signature, outputs, choice)
      {:error, _} = error -> error
      other -> {:error, {:parse_failed, other}}
    end
  end

  defp parse_text_outputs(adapter, signature, choice, false),
    do: adapter.parse_outputs(signature, choice.text, choice: choice)

  defp parse_text_outputs(adapter, signature, choice, true) do
    if String.trim(choice.text) == "" and Enum.all?(signature.output_fields, &(not &1.required)) do
      %{}
    else
      case adapter.parse_outputs(signature, choice.text,
             choice: choice,
             structured_tool_calls: true
           ) do
        {:error, {:missing_required_outputs, []}} ->
          if has_native_tool_calls?(choice),
            do: %{},
            else: {:error, {:missing_required_outputs, []}}

        result ->
          result
      end
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
         %{call_id: call_id, attempt: attempt} = meta,
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
          meta = %{meta | attempt: next_attempt}

          if lm_options.telemetry? do
            Telemetry.record(:adapter, %{}, %{output_attempts: next_attempt})
          end

          Logger.debug(
            "dspy.adapter_retry kind=output call_id=#{inspect(call_id)} attempt=#{next_attempt}/#{max_output_attempts} reason=#{Dspy.LogReason.format(reason)}"
          )

          callbacks =
            Callbacks.emit(callbacks, :format_start, meta, %{inputs_keys: Map.keys(inputs)})

          {:ok, callbacks} =
            complete_phase(callbacks, :format_end, meta, fn ->
              {:ok, %{request: request_summary(retry_request, lm)}}
            end)

          do_call_and_parse(
            signature,
            inputs,
            demos,
            adapter,
            callbacks,
            meta,
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

        reason = output_parse_failure(reason, response_text, choice_index)

        if is_function(lm_options.on_terminal_parse_failure, 2) do
          lm_options.on_terminal_parse_failure.(inputs, reason)
        end

        {:error, reason}
    end
  end

  defp output_parse_failure(reason, response_text, choice_index) when is_binary(response_text) do
    {:output_parse_failed, reason, with_choice_index(%{raw_output: response_text}, choice_index)}
  end

  defp meta(call_id, adapter, %Signature{} = signature) do
    meta = %{call_id: call_id, attempt: 1, adapter: adapter, signature_name: signature.name}

    case Lifecycle.active_call_id() do
      parent when is_reference(parent) -> Map.put(meta, :parent_call_id, parent)
      _ -> meta
    end
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

  defp build_output_retry_prompt(
         base_prompt,
         signature,
         Dspy.Signature.Adapters.XMLAdapter,
         reason
       ) do
    base_prompt <>
      "\n\nYour previous output did not match the required XML field format.\nErrors:\n" <>
      format_output_retry_errors(reason) <>
      "\n\n" <> Dspy.Signature.Adapters.XMLAdapter.format_instructions(signature)
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

  defp structured_tool_calls?(%Signature{} = signature),
    do: Enum.any?(signature.output_fields, &structured_tool_field?/1)

  # The internal ReAct signature opts into ID-preserving call records.
  defp structured_tool_field?(%{type: :tool_calls, tool_call_format: :structured}), do: true
  defp structured_tool_field?(_field), do: false

  defp tool_parse_signature(%Signature{} = signature, choice) do
    fields =
      Enum.flat_map(signature.output_fields, fn
        %{type: :tool_calls, tool_call_format: :structured} = field ->
          if has_native_tool_calls?(choice), do: [], else: [%{field | type: :string}]

        %{type: :tool_calls} ->
          []

        field ->
          [field]
      end)

    %{signature | output_fields: fields}
  end

  defp merge_tool_call_outputs(%Signature{} = signature, outputs, choice) do
    fields = Enum.filter(signature.output_fields, &(&1.type == :tool_calls))

    fields
    |> Enum.reduce_while({:ok, outputs}, fn field, {:ok, acc} ->
      case merge_tool_call_field(field, acc, choice) do
        {:ok, enriched} -> {:cont, {:ok, enriched}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, enriched} ->
        missing =
          for %{name: name, required: true} <- fields, not Map.has_key?(enriched, name), do: name

        if missing == [],
          do: {:ok, enriched},
          else: {:error, {:missing_required_outputs, missing}}

      {:error, _} = error ->
        error
    end
  end

  defp merge_tool_call_field(%{tool_call_format: :structured, name: name}, outputs, choice) do
    case {structured_native_calls(choice), Map.fetch(outputs, name)} do
      {native, _text} when native not in [nil, []] ->
        put_structured_tool_calls(outputs, name, native)

      {_native, {:ok, text}} ->
        with {:ok, calls} <- decode_tool_call_list(text) do
          put_structured_tool_calls(outputs, name, calls)
        end

      {_native, :error} ->
        {:ok, outputs}
    end
  end

  defp merge_tool_call_field(%{name: name}, outputs, choice) do
    with {:ok, parsed} <- parse_tool_calls(choice.tool_calls, &normalize_tool_call/1) do
      if parsed == [], do: {:ok, outputs}, else: {:ok, Map.put_new(outputs, name, parsed)}
    end
  end

  defp structured_native_calls(choice), do: tool_value(choice.raw, :tool_calls)
  defp has_native_tool_calls?(choice), do: structured_native_calls(choice) not in [nil, []]

  defp put_structured_tool_calls(outputs, name, calls) do
    with {:ok, parsed} <- parse_tool_calls(calls, &normalize_structured_tool_call/1) do
      {:ok, Map.put(outputs, name, parsed)}
    end
  end

  defp decode_tool_call_list(text) do
    case decode_tool_json(text) do
      {:ok, calls} when is_list(calls) -> {:ok, calls}
      {:ok, _} -> {:error, {:invalid_tool_calls, :expected_list}}
      {:error, reason} -> {:error, {:invalid_tool_calls, reason}}
    end
  end

  defp parse_tool_calls(nil, _normalize), do: {:ok, []}

  defp parse_tool_calls(tool_calls, normalize) when is_integer(length(tool_calls)) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn tool_call, {:ok, acc} ->
      case normalize.(tool_call) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      {:error, _} = error -> error
    end
  end

  defp parse_tool_calls(other, _normalize), do: {:error, {:invalid_tool_calls, other}}

  defp normalize_structured_tool_call(call) when is_map(call) do
    function = tool_value(call, :function, call)

    with :ok <- validate_tool_call_type(tool_value(call, :type, "function")),
         true <- is_map(function),
         name <- tool_value(function, :name),
         true <- nonblank_tool_string?(name),
         {:ok, id} <- structured_tool_id(name, tool_value(call, :id)),
         raw_args = tool_value(function, :arguments, tool_value(function, :args, %{})),
         {:ok, args} <- structured_tool_arguments(name, raw_args) do
      {:ok, %{id: id, name: name, args: args}}
    else
      false -> {:error, {:invalid_tool_call, %{reason: :missing_name}}}
      {:error, _} = error -> error
    end
  end

  defp normalize_structured_tool_call(_other),
    do: {:error, {:invalid_tool_call, %{reason: :not_a_map}}}

  defp validate_tool_call_type(type) when type in [:function, "function"], do: :ok

  defp validate_tool_call_type(_type),
    do: {:error, {:invalid_tool_call, %{reason: :unsupported_type}}}

  defp tool_value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp nonblank_tool_string?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp structured_tool_id(_name, nil), do: {:ok, nil}

  defp structured_tool_id(name, id) do
    if nonblank_tool_string?(id),
      do: {:ok, id},
      else: {:error, {:invalid_tool_call_id, %{name: name}}}
  end

  defp structured_tool_arguments(name, raw_args) do
    case tool_argument_object(raw_args) do
      {:ok, args} when is_map(args) and not is_struct(args) -> {:ok, args}
      _ -> {:error, {:invalid_tool_call_arguments, %{name: name}}}
    end
  end

  defp tool_argument_object(json) when is_binary(json), do: decode_tool_json(json)

  defp tool_argument_object(args) when is_map(args) do
    with {:ok, _} <- Dspy.History.encode_tool_value(args), do: {:ok, args}
  end

  defp tool_argument_object(_value), do: {:error, :expected_object}

  defp decode_tool_json(text) when is_binary(text) do
    with {:ok, ordered} <- Jason.decode(text, objects: :ordered_objects),
         {:ok, _} <- Dspy.History.encode_tool_value(ordered) do
      {:ok, tool_json_maps(ordered)}
    else
      {:error, %Jason.EncodeError{}} -> {:error, :duplicate_json_key}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp decode_tool_json(_text), do: {:error, :invalid_json}

  defp tool_json_maps(%Jason.OrderedObject{values: pairs}),
    do: Map.new(pairs, fn {key, value} -> {key, tool_json_maps(value)} end)

  defp tool_json_maps(values) when is_list(values), do: Enum.map(values, &tool_json_maps/1)
  defp tool_json_maps(value), do: value

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
    do_call_with_retry_log(request, lm_options, 1, max_retries + 1, call_id)
  end

  defp do_call_with_retry_log(request, lm_options, attempt, max_attempts, call_id) do
    result =
      with {:ok, advised_request} <- append_advice(request, lm_options.prompt_advice) do
        if lm_options.telemetry?, do: Telemetry.count_transport_attempt()
        invoke_lm(advised_request, lm_options)
      end

    case result do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        if attempt < max_attempts and Dspy.LM.RetryPolicy.retry?(reason) do
          next_attempt = attempt + 1

          Logger.debug(
            "dspy.adapter_retry kind=transport call_id=#{inspect(call_id)} attempt=#{next_attempt}/#{max_attempts} reason=#{Dspy.LogReason.format(reason)}"
          )

          Process.sleep(retry_sleep_ms())
          do_call_with_retry_log(request, lm_options, next_attempt, max_attempts, call_id)
        else
          {:error, reason, attempt}
        end
    end
  end

  defp invoke_lm(request, %{lm: bound_lm, on_delta: on_delta}) when is_function(on_delta, 1) do
    lm = if is_nil(bound_lm), do: Settings.get(:lm), else: bound_lm

    if is_nil(lm),
      do: {:error, :no_lm_configured},
      else: LM.stream_generate(lm, request, on_delta)
  end

  defp invoke_lm(request, %{lm: lm, cache_options: options}),
    do: LM.generate_with_options(lm, request, options)

  defp retry_sleep_ms do
    Application.get_env(:dspy, :predict_retry_sleep_ms, 1000)
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
