defmodule Dspy.Predict do
  @moduledoc """
  Basic prediction module for DSPy.

  The Predict module takes a signature and generates predictions
  by constructing prompts and calling the language model.
  """

  use Dspy.Module

  defstruct [:signature, :examples, :max_retries]

  @type t :: %__MODULE__{
          signature: Dspy.Signature.t(),
          examples: [Dspy.Example.t()],
          max_retries: non_neg_integer()
        }

  @doc """
  Create a new Predict module.
  """
  def new(signature, opts \\ []) do
    %__MODULE__{
      signature: get_signature(signature),
      examples: Keyword.get(opts, :examples, []),
      max_retries: Keyword.get(opts, :max_retries, 3)
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
  def forward(predict, inputs) do
    with :ok <- Dspy.Signature.validate_inputs(predict.signature, inputs),
         {:ok, prompt} <- build_prompt(predict, inputs),
         {:ok, response} <-
           generate_with_retries(prompt, predict.signature, inputs, predict.max_retries),
         {:ok, outputs} <- parse_response(predict, response) do
      prediction = Dspy.Prediction.new(outputs)
      {:ok, prediction}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_signature(signature) when is_atom(signature) do
    signature.signature()
  end

  defp get_signature(signature) when is_binary(signature) do
    Dspy.Signature.define(signature)
  end

  defp get_signature(signature), do: signature

  defp build_prompt(predict, inputs) do
    prompt_template = Dspy.Signature.to_prompt(predict.signature, predict.examples)

    filled_prompt =
      Enum.reduce(predict.signature.input_fields, prompt_template, fn %{name: name}, acc ->
        case Map.fetch(inputs, name) do
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
      case Map.get(inputs, name) do
        %Dspy.Attachments{} = a -> Dspy.Attachments.to_message_parts(a)
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
