defmodule Dspy.Predict do
  @moduledoc """
  Basic prediction module for DSPy.

  The Predict module takes a signature and generates predictions
  by constructing prompts and calling the language model.
  """

  use Dspy.Module

  defstruct [:signature, :examples, :max_retries, :max_output_retries, :adapter, :callbacks]

  @type t :: %__MODULE__{
          signature: Dspy.Signature.t(),
          examples: [Dspy.Example.t()],
          max_retries: non_neg_integer(),
          max_output_retries: non_neg_integer(),
          adapter: module() | nil,
          callbacks: list()
        }

  @doc """
  Create a new Predict module.

  Options:
  - `:examples` (default: [])
  - `:max_retries` (default: 3) — retry LM call on provider errors
  - `:max_output_retries` (default: 0) — retry when typed structured outputs fail to parse/validate
  - `:adapter` — optional signature adapter override
  - `:callbacks` — signature-adapter lifecycle callbacks (`[{module, state}]`)
  """
  def new(signature, opts \\ []) do
    %__MODULE__{
      signature: get_signature(signature),
      examples: Keyword.get(opts, :examples, []),
      max_retries: Keyword.get(opts, :max_retries, 3),
      max_output_retries: Keyword.get(opts, :max_output_retries, 0),
      adapter: Keyword.get(opts, :adapter),
      callbacks: Keyword.get(opts, :callbacks, [])
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
    adapter = Dspy.Signature.AdapterPipeline.active_adapter(adapter: predict.adapter)

    with :ok <- Dspy.Signature.validate_inputs(predict.signature, inputs),
         {:ok, outputs} <-
           Dspy.Signature.Adapter.Pipeline.run(
             predict.signature,
             normalize_inputs(inputs),
             predict.examples,
             adapter: adapter,
             callbacks: predict.callbacks,
             max_retries: predict.max_retries,
             max_output_retries: predict.max_output_retries
           ) do
      prediction = Dspy.Prediction.new(outputs)
      {:ok, prediction}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_inputs(inputs) when is_map(inputs), do: inputs

  defp normalize_inputs(inputs) when is_list(inputs) do
    if Keyword.keyword?(inputs), do: Map.new(inputs), else: inputs
  end

  defp get_signature(signature) when is_atom(signature), do: signature.signature()
  defp get_signature(signature) when is_binary(signature), do: Dspy.Signature.define(signature)
  defp get_signature(signature), do: signature
end
