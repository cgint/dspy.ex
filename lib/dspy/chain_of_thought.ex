defmodule Dspy.ChainOfThought do
  @moduledoc """
  Chain of Thought reasoning module.

  Extends basic prediction with step-by-step reasoning by adding a reasoning field
  to the signature and encouraging the model to show its work before generating
  the final answer.

  This module is intentionally Predict-like:
  - accepts module-based signatures and arrow-string signatures
  - supports few-shot examples
  - supports multimodal attachments (request-map parts)

  Note: many models increasingly hide internal chain-of-thought. This module keeps
  the *field* (`:reasoning`) and parsing mechanics, but model behavior depends on
  the provider/model.
  """

  use Dspy.Module

  alias Dspy.Parameter

  defstruct [:signature, :examples, :max_retries, :reasoning_field]

  @type t :: %__MODULE__{
          signature: Dspy.Signature.t(),
          examples: [Dspy.Example.t()],
          max_retries: non_neg_integer(),
          reasoning_field: atom()
        }

  @doc """
  Create a new ChainOfThought module.

  Accepts:
  - a signature module (`use Dspy.Signature`)
  - a `%Dspy.Signature{}`
  - an arrow signature string (e.g. `"question -> answer"`)
  """
  def new(signature, opts \\ []) do
    base_signature = get_signature(signature)
    reasoning_field = Keyword.get(opts, :reasoning_field, :reasoning)

    augmented_signature = add_reasoning_field(base_signature, reasoning_field)

    %__MODULE__{
      signature: augmented_signature,
      examples: Keyword.get(opts, :examples, []),
      max_retries: Keyword.get(opts, :max_retries, 3),
      reasoning_field: reasoning_field
    }
  end

  @impl true
  def parameters(%__MODULE__{} = cot) do
    base = [Parameter.new("predict.examples", :examples, cot.examples)]

    case cot.signature.instructions do
      nil ->
        base

      instructions when is_binary(instructions) ->
        base ++ [Parameter.new("predict.instructions", :prompt, instructions)]
    end
  end

  @impl true
  def update_parameters(%__MODULE__{} = cot, parameters) when is_list(parameters) do
    Enum.reduce(parameters, cot, fn
      %Parameter{name: "predict.examples", value: examples}, acc when is_list(examples) ->
        %{acc | examples: examples}

      %Parameter{name: "predict.instructions", value: instructions}, acc
      when is_binary(instructions) ->
        %{acc | signature: %{acc.signature | instructions: instructions}}

      _other, acc ->
        acc
    end)
  end

  @impl true
  def forward(%__MODULE__{} = cot, inputs) do
    with :ok <- Dspy.Signature.validate_inputs(cot.signature, inputs),
         {:ok, prompt} <- build_prompt(cot, inputs),
         {:ok, response_text} <-
           generate_with_retries(prompt, cot.signature, inputs, cot.max_retries),
         {:ok, outputs} <- parse_response(cot, response_text) do
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

  defp fetch_input(inputs, name) when is_map(inputs) and is_atom(name) do
    case Map.fetch(inputs, name) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(inputs, Atom.to_string(name))
    end
  end

  defp add_reasoning_field(signature, reasoning_field) do
    reasoning_field_def = %{
      name: reasoning_field,
      type: :string,
      description: "Think step by step to solve this problem",
      required: true,
      default: nil
    }

    # Insert reasoning field before other output fields
    new_output_fields = [reasoning_field_def | signature.output_fields]

    %{signature | output_fields: new_output_fields}
  end

  defp build_prompt(%__MODULE__{} = cot, inputs) do
    # Add chain-of-thought instructions
    enhanced_signature = add_cot_instructions(cot.signature)

    prompt_template = Dspy.Signature.to_prompt(enhanced_signature, cot.examples)

    filled_prompt =
      Enum.reduce(enhanced_signature.input_fields, prompt_template, fn %{name: name}, acc ->
        case fetch_input(inputs, name) do
          :error ->
            acc

          {:ok, %Dspy.Attachments{}} ->
            placeholder = "[input]"
            field_name = String.capitalize(Atom.to_string(name))

            String.replace(
              acc,
              "#{field_name}: #{placeholder}",
              "#{field_name}: <attachments>"
            )

          {:ok, value} ->
            placeholder = "[input]"
            field_name = String.capitalize(Atom.to_string(name))
            formatted = format_input_value(value)

            String.replace(
              acc,
              "#{field_name}: #{placeholder}",
              "#{field_name}: #{formatted}"
            )
        end
      end)

    {:ok, filled_prompt}
  end

  defp format_input_value(value) when is_binary(value), do: value

  defp format_input_value(value) do
    inspect(value, pretty: false, limit: 100, sort_maps: true)
  end

  defp add_cot_instructions(signature) do
    cot_instructions = """
    Think step by step and show your reasoning before providing the final answer.
    Break down the problem and explain your thought process clearly.
    """

    existing_instructions = signature.instructions || ""

    combined_instructions =
      [existing_instructions, cot_instructions]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    %{signature | instructions: combined_instructions}
  end

  defp generate_with_retries(prompt, signature, inputs, retries) do
    case generate_once(prompt, signature, inputs) do
      {:ok, response_text} ->
        {:ok, response_text}

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

  defp parse_response(%__MODULE__{} = cot, response_text) do
    case Dspy.Signature.parse_outputs(cot.signature, response_text) do
      {:error, _reason} = error -> error
      outputs when is_map(outputs) -> {:ok, outputs}
    end
  end
end
