defmodule Dspy.Teleprompt.LabeledFewShot do
  @moduledoc """
  LabeledFewShot teleprompt - Simple few-shot learning with labeled examples.

  Supports optimizing programs that expose the `"predict.examples"` parameter
  (e.g. `Dspy.Predict` and `Dspy.ChainOfThought`).

  This is the most basic teleprompt that simply adds labeled examples
  to the program's signature to enable few-shot learning.

  ## Usage

      teleprompt = Dspy.Teleprompt.LabeledFewShot.new(k: 3)
      {:ok, optimized_program} = Dspy.Teleprompt.LabeledFewShot.compile(teleprompt, program, trainset)

  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{Example, Trainset}

  defstruct [
    # Metric function (optional; stored for interface consistency)
    :metric,
    # Number of examples to include
    :k,
    # Random seed for example selection
    :seed,
    # How to select examples (:random, :diverse, etc.)
    :selection_strategy,
    # Whether to include reasoning in examples
    :include_reasoning
  ]

  @type t :: %__MODULE__{
          metric: function() | nil,
          k: pos_integer(),
          seed: integer(),
          selection_strategy: atom(),
          include_reasoning: boolean()
        }

  @doc """
  Create a new LabeledFewShot teleprompt.

  ## Options

  - `:metric` - Optional metric function (accepted for interface consistency; currently unused)
  - `:k` - Number of few-shot examples to include (default: 3)
  - `:seed` - Random seed for reproducible example selection
  - `:selection_strategy` - Strategy for selecting examples (:random, :diverse, :balanced)
  - `:include_reasoning` - Include reasoning traces in examples (default: false)

  ## Examples

      teleprompt = LabeledFewShot.new(k: 5, selection_strategy: :diverse)

  """
  @impl Dspy.Teleprompt
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      metric: Keyword.get(opts, :metric),
      k: Keyword.get(opts, :k, 3),
      seed: Keyword.get(opts, :seed, :os.system_time(:microsecond)),
      selection_strategy: Keyword.get(opts, :selection_strategy, :random),
      include_reasoning: Keyword.get(opts, :include_reasoning, false)
    }
  end

  @doc """
  Compile a program with labeled few-shot examples.

  ## Parameters

  - `teleprompt` - LabeledFewShot configuration
  - `program` - DSPy program to optimize
  - `trainset` - Training examples to select from

  ## Returns

  `{:ok, optimized_program}` with few-shot examples embedded

  """
  @impl Dspy.Teleprompt
  @spec compile(t(), Dspy.Teleprompt.program_t(), list(Example.t())) ::
          Dspy.Teleprompt.compile_result()
  def compile(%__MODULE__{} = teleprompt, program, trainset) do
    do_compile(teleprompt, program, trainset)
  end

  defp do_compile(%__MODULE__{} = teleprompt, program, trainset) do
    with {:ok, validated_trainset} <- validate_trainset(trainset),
         {:ok, selected_examples} <- select_examples(teleprompt, validated_trainset) do
      selected_examples =
        maybe_strip_reasoning(selected_examples, teleprompt.include_reasoning)

      # Apply examples to the program via optimizable parameters (no dynamic modules)
      with {:ok, optimized_program} <-
             Dspy.Teleprompt.Util.set_predict_examples(program, selected_examples) do
        {:ok, optimized_program}
      end
    end
  end

  # Private functions

  defp validate_trainset([]), do: {:error, :empty_trainset}

  defp validate_trainset(trainset) do
    case Trainset.validate(trainset) do
      {:ok, validated_trainset} -> {:ok, validated_trainset}
      {:error, reason} -> {:error, {:invalid_trainset, reason}}
    end
  end

  defp select_examples(%__MODULE__{k: k, selection_strategy: strategy, seed: seed}, trainset) do
    if length(trainset) == 0 do
      {:error, :empty_trainset}
    else
      selected = Trainset.sample(trainset, k, strategy: strategy, seed: seed)
      {:ok, selected}
    end
  end

  defp maybe_strip_reasoning(examples, true), do: examples

  defp maybe_strip_reasoning(examples, false) do
    Enum.map(examples, fn
      %Dspy.Example{attrs: attrs} = ex when is_map(attrs) ->
        %{ex | attrs: Map.delete(attrs, :reasoning)}

      other ->
        other
    end)
  end
end
