defmodule Dspy.Predict do
  @moduledoc """
  Basic prediction module for DSPy.

  The Predict module takes a signature and generates predictions
  by constructing prompts and calling the language model.
  """

  use Dspy.Module

  alias Dspy.PredictorConfig

  defstruct [
    :signature,
    :examples,
    :lm,
    :max_retries,
    :max_output_retries,
    :adapter,
    :callbacks,
    :forced_tool,
    config: %{}
  ]

  @type t :: %__MODULE__{
          signature: Dspy.Signature.t(),
          examples: [Dspy.Example.t()],
          lm: Dspy.LM.t() | nil,
          config: PredictorConfig.t(),
          max_retries: non_neg_integer(),
          max_output_retries: non_neg_integer(),
          adapter: module() | nil,
          forced_tool: String.t() | nil,
          callbacks: list()
        }

  @doc """
  Create a new Predict module.

  Options:
  - `:examples` (default: [])
  - `:lm` — a `Dspy.LM` struct for this predictor. Defaults to the configured LM at call time.
  - `:config` — stored generation options as a map or keyword list. Set `:n`
    to a positive integer to return parsed choices from a compatible LM.
  - `:max_retries` (default: 3) — retry LM call on provider errors
  - `:max_output_retries` (default: `Dspy.Settings.max_output_retries` or `0`) — retry when adapter outputs fail to parse/validate (e.g. inner reason `{:missing_required_outputs, ...}`); terminal pipeline failures return `{:output_parse_failed, reason, %{raw_output: response_text}}`
  - `:adapter` — optional signature adapter override
  - `:callbacks` — signature-adapter lifecycle callbacks (`[{module, state}]`)
  """
  def new(signature, opts \\ []) do
    %__MODULE__{
      signature: get_signature(signature),
      examples: Keyword.get(opts, :examples, []),
      lm: Dspy.LM.validate_binding!(Keyword.get(opts, :lm)),
      config: PredictorConfig.new!(Keyword.get(opts, :config, %{})),
      max_retries: Keyword.get(opts, :max_retries, 3),
      max_output_retries: Keyword.get(opts, :max_output_retries, default_max_output_retries()),
      adapter: Keyword.get(opts, :adapter),
      callbacks: Keyword.get(opts, :callbacks, [])
    }
  end

  @doc "Return the stored generation options."
  @spec get_config(t()) :: PredictorConfig.t()
  def get_config(%__MODULE__{} = predict), do: PredictorConfig.get(predict)

  @doc "Return a predictor with the supplied generation options merged into its config."
  @spec update_config(t(), PredictorConfig.t() | keyword()) :: t()
  def update_config(%__MODULE__{} = predict, config), do: PredictorConfig.update(predict, config)

  @doc "Return a predictor with its demos and stored LM binding cleared."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = predict), do: Dspy.Module.reset_copy(predict)

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
  def forward(%__MODULE__{} = predict, inputs), do: forward(predict, inputs, nil)

  @doc false
  def forward(%__MODULE__{} = predict, inputs, on_delta) do
    adapter = Dspy.Signature.AdapterPipeline.active_adapter(adapter: predict.adapter)

    with :ok <- Dspy.Signature.validate_inputs(predict.signature, inputs),
         {:ok, prediction} <-
           Dspy.Signature.Adapter.Pipeline.run_prediction(
             predict.signature,
             normalize_inputs(inputs),
             predict.examples,
             on_delta,
             adapter: adapter,
             lm: Map.get(predict, :lm),
             forced_tool: Map.get(predict, :forced_tool),
             config: get_config(predict),
             prompt_advice: Dspy.Refine.Advice.binding(predict),
             callbacks: predict.callbacks,
             max_retries: predict.max_retries,
             max_output_retries: predict.max_output_retries
           ) do
      Dspy.Module.PredictorTrace.record(predict, inputs, prediction)
      {:ok, prediction}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_inputs(inputs) when is_map(inputs), do: inputs

  defp get_signature(signature) when is_atom(signature), do: signature.signature()
  defp get_signature(signature) when is_binary(signature), do: Dspy.Signature.define(signature)
  defp get_signature(signature), do: signature

  defp default_max_output_retries do
    if Process.whereis(Dspy.Settings) do
      value = Dspy.Settings.get(:max_output_retries)
      if is_integer(value) and value >= 0, do: value, else: 0
    else
      0
    end
  end
end
