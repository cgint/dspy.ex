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

  alias Dspy.Signature
  alias Dspy.Signature.Adapter.Callbacks
  alias Dspy.Signature.AdapterPipeline

  @type opts :: [
          adapter: module() | nil,
          callbacks: Callbacks.callbacks(),
          max_retries: non_neg_integer(),
          max_output_retries: non_neg_integer()
        ]

  @spec run(Signature.t(), map(), [Dspy.Example.t()], opts()) :: {:ok, map()} | {:error, term()}
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

    max_retries = Keyword.get(opts, :max_retries, 3)
    max_output_retries = Keyword.get(opts, :max_output_retries, 0)

    call_id = make_ref()

    do_run_attempt(
      signature,
      inputs,
      demos,
      adapter,
      callbacks,
      call_id,
      1,
      max_retries,
      max_output_retries
    )
  end

  defp do_run_attempt(
         %Signature{} = signature,
         inputs,
         demos,
         adapter,
         callbacks,
         call_id,
         attempt,
         max_retries,
         output_retries_left
       )
       when is_map(inputs) and is_list(demos) and is_atom(adapter) and is_list(callbacks) and
              is_integer(attempt) and attempt >= 1 and is_integer(max_retries) and
              max_retries >= 0 and
              is_integer(output_retries_left) and output_retries_left >= 0 do
    meta = meta(call_id, attempt, adapter, signature)

    callbacks = Callbacks.emit(callbacks, :format_start, meta, %{inputs_keys: Map.keys(inputs)})

    with {:ok, request0} <-
           AdapterPipeline.format_request(signature, inputs, demos, adapter: adapter),
         {:ok, request} <- merge_attachments(signature, inputs, request0),
         {:ok, base_prompt} <- AdapterPipeline.primary_prompt_text(request) do
      callbacks =
        Callbacks.emit(callbacks, :format_end, meta, %{request: request_summary(request)})

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
        max_retries,
        output_retries_left,
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
         max_retries,
         output_retries_left,
         request,
         base_request,
         base_prompt
       )
       when is_map(request) and is_map(base_request) and is_binary(base_prompt) do
    meta = meta(call_id, attempt, adapter, signature)

    callbacks = Callbacks.emit(callbacks, :call_start, meta, %{request: request_summary(request)})

    case generate_with_retries(request, max_retries) do
      {:ok, response} ->
        usage_raw = extract_usage(response)

        callbacks =
          Callbacks.emit(callbacks, :call_end, meta, %{
            request: request_summary(request),
            usage: normalize_usage(usage_raw)
          })

        with {:ok, choice} <- Dspy.LM.choice_from_response(response),
             {:ok, response_text} <- Dspy.LM.text_from_response(response) do
          callbacks =
            Callbacks.emit(callbacks, :parse_start, meta, %{
              response_chars: String.length(response_text)
            })

          parse_signature = drop_tool_call_outputs(signature)
          result = adapter.parse_outputs(parse_signature, response_text, choice: choice)

          case result do
            outputs when is_map(outputs) ->
              case merge_tool_call_outputs(signature, outputs, choice) do
                {:ok, merged_outputs} ->
                  _callbacks =
                    Callbacks.emit(callbacks, :parse_end, meta, %{
                      outputs_keys: Map.keys(merged_outputs)
                    })

                  {:ok, merged_outputs}

                {:error, reason} ->
                  _callbacks = Callbacks.emit(callbacks, :parse_end, meta, %{error: reason})

                  maybe_retry_output(
                    signature,
                    inputs,
                    demos,
                    adapter,
                    callbacks,
                    call_id,
                    attempt,
                    max_retries,
                    output_retries_left,
                    base_request,
                    base_prompt,
                    reason
                  )
              end

            {:error, reason} ->
              _callbacks = Callbacks.emit(callbacks, :parse_end, meta, %{error: reason})

              maybe_retry_output(
                signature,
                inputs,
                demos,
                adapter,
                callbacks,
                call_id,
                attempt,
                max_retries,
                output_retries_left,
                base_request,
                base_prompt,
                reason
              )

            other ->
              _callbacks =
                Callbacks.emit(callbacks, :parse_end, meta, %{error: {:parse_failed, other}})

              maybe_retry_output(
                signature,
                inputs,
                demos,
                adapter,
                callbacks,
                call_id,
                attempt,
                max_retries,
                output_retries_left,
                base_request,
                base_prompt,
                {:parse_failed, other}
              )
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_retry_output(
         signature,
         inputs,
         demos,
         adapter,
         callbacks,
         call_id,
         attempt,
         max_retries,
         output_retries_left,
         base_request,
         base_prompt,
         reason
       )
       when is_map(base_request) and is_binary(base_prompt) do
    cond do
      output_retries_left > 0 and typed_output_retry_enabled?(signature) and
          output_retryable_reason?(reason) ->
        retry_prompt = build_output_retry_prompt(base_prompt, signature, reason)

        with {:ok, retry_request} <-
               AdapterPipeline.replace_primary_prompt_text(base_request, retry_prompt) do
          # Treat prompt replacement as the "format" phase for the next attempt.
          next_attempt = attempt + 1
          meta = meta(call_id, next_attempt, adapter, signature)

          callbacks =
            Callbacks.emit(callbacks, :format_start, meta, %{inputs_keys: Map.keys(inputs)})

          callbacks =
            Callbacks.emit(callbacks, :format_end, meta, %{
              request: request_summary(retry_request)
            })

          do_call_and_parse(
            signature,
            inputs,
            demos,
            adapter,
            callbacks,
            call_id,
            next_attempt,
            max_retries,
            output_retries_left - 1,
            retry_request,
            base_request,
            base_prompt
          )
        end

      true ->
        {:error, reason}
    end
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

  defp typed_output_retry_enabled?(%Signature{} = signature) do
    Enum.any?(signature.output_fields, &Map.has_key?(&1, :schema))
  end

  defp output_retryable_reason?({:output_decode_failed, _reason}), do: true
  defp output_retryable_reason?({:output_validation_failed, _details}), do: true
  defp output_retryable_reason?({:missing_required_outputs, _missing}), do: true
  defp output_retryable_reason?({:invalid_output_value, _field, _reason}), do: true
  defp output_retryable_reason?({:invalid_outputs, _other}), do: true
  defp output_retryable_reason?(_other), do: false

  defp build_output_retry_prompt(base_prompt, %Signature{} = signature, reason)
       when is_binary(base_prompt) do
    keys = signature.output_fields |> Enum.map(&Atom.to_string(&1.name)) |> Enum.join(", ")

    base_prompt <>
      "\n\n" <>
      "Your previous output did not match the required JSON schema.\n" <>
      "Errors:\n" <>
      format_output_retry_errors(reason) <>
      "\n\n" <>
      "Return JSON only (no markdown fences, no labels, no extra text).\n" <>
      "The top-level JSON object must contain the following keys: #{keys}.\n" <>
      "Use the JSON Schema shown above."
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

  defp generate_with_retries(request, retries) when is_map(request) and is_integer(retries) do
    case Dspy.LM.generate(request) do
      {:ok, response} ->
        {:ok, response}

      {:error, _reason} when retries > 0 ->
        Process.sleep(retry_sleep_ms())
        generate_with_retries(request, retries - 1)

      {:error, _reason} = err ->
        err
    end
  end

  defp retry_sleep_ms do
    Application.get_env(:dspy, :predict_retry_sleep_ms, 1000)
  end

  defp merge_attachments(%Signature{} = signature, inputs, request)
       when is_map(inputs) and is_map(request) do
    attachments = extract_attachments(signature, inputs)
    AdapterPipeline.merge_attachments(request, attachments)
  end

  defp extract_attachments(%Signature{} = signature, inputs) when is_map(inputs) do
    Enum.flat_map(signature.input_fields, fn %{name: name} ->
      case fetch_input(inputs, name) do
        {:ok, %Dspy.Attachments{} = a} -> Dspy.Attachments.to_message_parts(a)
        _ -> []
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

  defp request_summary(request) when is_map(request) do
    messages = Map.get(request, :messages) || Map.get(request, "messages")
    messages_count = if is_list(messages), do: length(messages), else: 0

    lm = if Process.whereis(Dspy.Settings), do: Dspy.Settings.get(:lm), else: nil

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
