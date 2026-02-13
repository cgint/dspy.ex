defmodule Dspy.Predict do
  @moduledoc """
  Basic prediction module for DSPy.

  The Predict module takes a signature and generates predictions
  by constructing prompts and calling the language model.
  """

  use Dspy.Module

  defstruct [:signature, :examples, :max_retries, :max_output_retries]

  @type t :: %__MODULE__{
          signature: Dspy.Signature.t(),
          examples: [Dspy.Example.t()],
          max_retries: non_neg_integer(),
          max_output_retries: non_neg_integer()
        }

  @doc """
  Create a new Predict module.
  """
  def new(signature, opts \\ []) do
    %__MODULE__{
      signature: get_signature(signature),
      examples: Keyword.get(opts, :examples, []),
      max_retries: Keyword.get(opts, :max_retries, 3),
      # Opt-in: retry when typed structured outputs fail to parse/validate.
      max_output_retries: Keyword.get(opts, :max_output_retries, 0)
    }
  end

  @impl true
  def parameters(%__MODULE__{} = predict) do
    base = [
      Dspy.Parameter.new("predict.examples", :examples, predict.examples)
    ]

    case predict.signature.instructions do
      nil ->
        base

      instructions when is_binary(instructions) ->
        base ++ [Dspy.Parameter.new("predict.instructions", :prompt, instructions)]
    end
  end

  @impl true
  def update_parameters(%__MODULE__{} = predict, parameters) when is_list(parameters) do
    Enum.reduce(parameters, predict, fn
      %Dspy.Parameter{name: "predict.examples", value: examples}, acc when is_list(examples) ->
        %{acc | examples: examples}

      %Dspy.Parameter{name: "predict.instructions", value: instructions}, acc
      when is_binary(instructions) ->
        %{acc | signature: %{acc.signature | instructions: instructions}}

      _other, acc ->
        acc
    end)
  end

  @impl true
  def forward(%__MODULE__{} = predict, inputs) do
    with :ok <- Dspy.Signature.validate_inputs(predict.signature, inputs),
         {:ok, prompt} <- build_prompt(predict, inputs),
         {:ok, outputs} <- generate_and_parse_with_output_retries(predict, prompt, inputs) do
      prediction = Dspy.Prediction.new(outputs)
      {:ok, prediction}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_and_parse_with_output_retries(%__MODULE__{} = predict, base_prompt, inputs)
       when is_binary(base_prompt) do
    do_generate_and_parse_with_output_retries(
      predict,
      base_prompt,
      base_prompt,
      inputs,
      predict.max_output_retries
    )
  end

  defp do_generate_and_parse_with_output_retries(
         %__MODULE__{} = predict,
         base_prompt,
         prompt,
         inputs,
         output_retries_left
       )
       when is_binary(base_prompt) and is_binary(prompt) and is_integer(output_retries_left) do
    with {:ok, response_text} <-
           generate_with_retries(prompt, predict.signature, inputs, predict.max_retries) do
      case parse_response(predict, response_text) do
        {:ok, outputs} ->
          {:ok, outputs}

        {:error, reason} ->
          if output_retries_left > 0 and typed_output_retry_enabled?(predict) and
               output_retryable_reason?(reason) do
            retry_prompt = build_output_retry_prompt(base_prompt, predict.signature, reason)

            do_generate_and_parse_with_output_retries(
              predict,
              base_prompt,
              retry_prompt,
              inputs,
              output_retries_left - 1
            )
          else
            {:error, reason}
          end
      end
    end
  end

  defp typed_output_retry_enabled?(%__MODULE__{} = predict) do
    predict.max_output_retries > 0 and signature_has_typed_outputs?(predict.signature)
  end

  defp signature_has_typed_outputs?(%Dspy.Signature{} = signature) do
    Enum.any?(signature.output_fields, &Map.has_key?(&1, :schema))
  end

  defp output_retryable_reason?({:output_decode_failed, _reason}), do: true
  defp output_retryable_reason?({:output_validation_failed, _details}), do: true
  defp output_retryable_reason?({:missing_required_outputs, _missing}), do: true
  defp output_retryable_reason?({:invalid_output_value, _field, _reason}), do: true
  defp output_retryable_reason?({:invalid_outputs, _other}), do: true
  defp output_retryable_reason?(_other), do: false

  defp build_output_retry_prompt(base_prompt, %Dspy.Signature{} = signature, reason)
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

  defp get_signature(signature) when is_atom(signature) do
    signature.signature()
  end

  defp get_signature(signature) when is_binary(signature) do
    Dspy.Signature.define(signature)
  end

  defp get_signature(signature), do: signature

  defp fetch_input(inputs, name) when is_map(inputs) and is_atom(name) do
    case Map.fetch(inputs, name) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(inputs, Atom.to_string(name))
    end
  end

  defp build_prompt(predict, inputs) do
    prompt_template = Dspy.Signature.to_prompt(predict.signature, predict.examples)

    filled_prompt =
      Enum.reduce(predict.signature.input_fields, prompt_template, fn %{name: name}, acc ->
        case fetch_input(inputs, name) do
          :error ->
            acc

          {:ok, %Dspy.Attachments{}} ->
            placeholder = "[input]"
            field_name = String.capitalize(Atom.to_string(name))
            String.replace(acc, "#{field_name}: #{placeholder}", "#{field_name}: <attachments>")

          {:ok, value} ->
            placeholder = "[input]"
            field_name = String.capitalize(Atom.to_string(name))
            formatted = format_input_value(value)
            String.replace(acc, "#{field_name}: #{placeholder}", "#{field_name}: #{formatted}")
        end
      end)

    {:ok, filled_prompt}
  end

  defp format_input_value(value) when is_binary(value), do: value

  defp format_input_value(value) do
    inspect(value, pretty: false, limit: 100, sort_maps: true)
  end

  defp generate_with_retries(prompt, signature, inputs, retries) do
    case generate_once(prompt, signature, inputs) do
      {:ok, response} ->
        {:ok, response}

      {:error, _reason} when retries > 0 ->
        Process.sleep(retry_sleep_ms())
        generate_with_retries(prompt, signature, inputs, retries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_sleep_ms do
    Application.get_env(:dspy, :predict_retry_sleep_ms, 1000)
  end

  defp generate_once(prompt, signature, inputs) do
    attachments = extract_attachments(signature, inputs)

    content =
      if attachments == [] do
        prompt
      else
        [%{"type" => "text", "text" => prompt}] ++ attachments
      end

    request = %{
      messages: [
        %{
          role: "user",
          content: content
        }
      ]
    }

    with {:ok, response} <- Dspy.LM.generate(request),
         {:ok, text} <- Dspy.LM.text_from_response(response) do
      {:ok, text}
    end
  end

  defp extract_attachments(%Dspy.Signature{} = signature, inputs) when is_map(inputs) do
    Enum.flat_map(signature.input_fields, fn %{name: name} ->
      case fetch_input(inputs, name) do
        {:ok, %Dspy.Attachments{} = a} -> Dspy.Attachments.to_message_parts(a)
        _ -> []
      end
    end)
  end

  defp parse_response(predict, response_text) do
    case Dspy.Signature.parse_outputs(predict.signature, response_text) do
      {:error, reason} -> {:error, reason}
      outputs when is_map(outputs) -> {:ok, outputs}
      other -> {:error, {:parse_failed, other}}
    end
  end
end
