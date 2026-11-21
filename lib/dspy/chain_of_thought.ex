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

  alias Dspy.{Parameter, PredictorConfig}

  defstruct [
    :signature,
    :examples,
    :lm,
    :max_retries,
    :max_output_retries,
    :reasoning_field,
    :adapter,
    :callbacks,
    config: %{}
  ]

  @type t :: %__MODULE__{
          signature: Dspy.Signature.t(),
          examples: [Dspy.Example.t()],
          lm: Dspy.LM.t() | nil,
          config: PredictorConfig.t(),
          max_retries: non_neg_integer(),
          max_output_retries: non_neg_integer(),
          reasoning_field: atom(),
          adapter: module() | nil,
          callbacks: list()
        }

  @doc """
  Create a new ChainOfThought module.

  Accepts:
  - a signature module (`use Dspy.Signature`)
  - a `%Dspy.Signature{}`
  - an arrow signature string (e.g. `"question -> answer"`)

  Options:
  - `:examples` (default: [])
  - `:lm` — a `Dspy.LM` struct for this predictor. Defaults to the configured LM at call time.
  - `:config` — stored generation options as a map or keyword list
  - `:max_retries` (default: 3)
  - `:max_output_retries` (default: `Dspy.Settings.max_output_retries` or `0`) — retry when adapter outputs fail to parse/validate (e.g. inner reason `{:missing_required_outputs, ...}`); terminal pipeline failures return `{:output_parse_failed, reason, %{raw_output: response_text}}`
  - `:reasoning_field` (default: :reasoning)
  - `:adapter` — optional signature adapter override
  - `:callbacks` — signature-adapter lifecycle callbacks (`[{module, state}]`)
  """
  def new(signature, opts \\ []) do
    base_signature = get_signature(signature)
    reasoning_field = Keyword.get(opts, :reasoning_field, :reasoning)

    augmented_signature = add_reasoning_field(base_signature, reasoning_field)

    %__MODULE__{
      signature: augmented_signature,
      examples: Keyword.get(opts, :examples, []),
      lm: Dspy.LM.validate_binding!(Keyword.get(opts, :lm)),
      config: PredictorConfig.new!(Keyword.get(opts, :config, %{})),
      max_retries: Keyword.get(opts, :max_retries, 3),
      max_output_retries: Keyword.get(opts, :max_output_retries, default_max_output_retries()),
      reasoning_field: reasoning_field,
      adapter: Keyword.get(opts, :adapter),
      callbacks: Keyword.get(opts, :callbacks, [])
    }
  end

  @doc "Return the stored generation options."
  @spec get_config(t()) :: PredictorConfig.t()
  def get_config(%__MODULE__{} = cot), do: PredictorConfig.get(cot)

  @doc "Return a predictor with the supplied generation options merged into its config."
  @spec update_config(t(), PredictorConfig.t() | keyword()) :: t()
  def update_config(%__MODULE__{} = cot, config), do: PredictorConfig.update(cot, config)

  @doc "Return a predictor with its demos and stored LM binding cleared."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = cot), do: Dspy.Module.reset_copy(cot)

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
    signature_for_call = add_cot_instructions(cot.signature)
    adapter = Dspy.Signature.AdapterPipeline.active_adapter(adapter: cot.adapter)

    with :ok <- Dspy.Signature.validate_inputs(signature_for_call, inputs),
         {:ok, outputs} <-
           Dspy.Signature.Adapter.Pipeline.run(
             signature_for_call,
             normalize_inputs(inputs),
             cot.examples,
             adapter: adapter,
             lm: Map.get(cot, :lm),
             config: get_config(cot),
             callbacks: cot.callbacks,
             max_retries: cot.max_retries,
             max_output_retries: cot.max_output_retries
           ) do
      prediction = Dspy.Prediction.new(outputs)
      Dspy.Module.PredictorTrace.record(cot, inputs, prediction)
      {:ok, prediction}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_inputs(inputs) when is_map(inputs), do: inputs

  defp get_signature(signature) when is_atom(signature), do: signature.signature()
  defp get_signature(signature) when is_binary(signature), do: Dspy.Signature.define(signature)
  defp get_signature(%Dspy.Signature{} = signature), do: signature

  defp add_reasoning_field(signature, reasoning_field) do
    reasoning_field_def = %{
      name: reasoning_field,
      type: :string,
      description: "Think step by step to solve this problem",
      required: true,
      default: nil
    }

    new_output_fields = [reasoning_field_def | signature.output_fields]

    %{signature | output_fields: new_output_fields}
  end

  defp default_max_output_retries do
    if Process.whereis(Dspy.Settings) do
      value = Dspy.Settings.get(:max_output_retries)
      if is_integer(value) and value >= 0, do: value, else: 0
    else
      0
    end
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
end
