defmodule Dspy.Teleprompt.KNNFewShot.Program do
  @moduledoc false

  use Dspy.Module

  alias Dspy.KNN
  alias Dspy.Teleprompt.BootstrapFewShot

  @enforce_keys [:index, :student, :bootstrap]
  defstruct [:index, :student, :bootstrap]

  @impl true
  def forward(%__MODULE__{} = program, inputs) do
    with {:ok, neighbors} <- KNN.query(program.index, inputs),
         {:ok, child} <-
           BootstrapFewShot.compile_single(program.bootstrap, program.student, neighbors) do
      Dspy.Module.forward(child, inputs)
    end
  end
end

defmodule Dspy.Teleprompt.KNNFewShot do
  @moduledoc """
  Optimize a student with a fresh set of nearby examples for each prediction.

  Compilation builds one `Dspy.KNN` index. Each call retrieves neighbors,
  prepares one set of demos with `Dspy.Teleprompt.BootstrapFewShot`, and runs
  the student with those demos. The caller's student keeps its original demos.
  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{Embedder, Example, KNN, Teleprompt}
  alias Dspy.Teleprompt.{BootstrapFewShot, Util}
  alias __MODULE__.Program

  @options [
    :k,
    :vectorizer,
    :metric,
    :teacher,
    :max_bootstrapped_demos,
    :max_labeled_demos,
    :max_rounds,
    :max_errors,
    :num_threads,
    :seed,
    :metric_threshold,
    :verbose
  ]

  @enforce_keys [:k, :vectorizer, :bootstrap]
  defstruct [:k, :vectorizer, :bootstrap]

  @type t :: %__MODULE__{
          k: pos_integer(),
          vectorizer: Embedder.t(),
          bootstrap: BootstrapFewShot.t()
        }

  @doc """
  Configure the optimizer with a positive `:k` and a `:vectorizer` embedder.

  Bootstrap options include `:teacher`, `:metric`, `:metric_threshold`,
  `:max_bootstrapped_demos`, `:max_labeled_demos`, `:max_rounds`, `:max_errors`,
  `:num_threads`, `:seed`, and `:verbose`. A missing or `nil` metric accepts all
  successful teacher predictions. Defaults are 16 labeled demos and `seed: -1`
  to keep neighbor order during bootstrap sampling.
  """
  @impl true
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, @options)
    k = Keyword.get(opts, :k)
    vectorizer = Keyword.get(opts, :vectorizer)

    unless is_integer(k) and k > 0, do: raise(ArgumentError, "k must be a positive integer")

    unless is_struct(vectorizer, Embedder),
      do: raise(ArgumentError, "vectorizer must be a Dspy.Embedder")

    bootstrap_opts =
      opts
      |> Keyword.drop([:k, :vectorizer])
      |> Keyword.put_new(:max_labeled_demos, 16)
      |> Keyword.put_new(:seed, -1)
      |> default_metric()

    %__MODULE__{k: k, vectorizer: vectorizer, bootstrap: BootstrapFewShot.new(bootstrap_opts)}
  end

  @doc """
  Build a callable program. The student must support the `predict.examples` parameter.
  """
  @impl true
  @spec compile(t(), Teleprompt.program_t(), [Example.t()]) :: Teleprompt.compile_result()
  def compile(%__MODULE__{} = optimizer, student, trainset) do
    with {:ok, template} <- Util.set_predict_examples(student, []),
         {:ok, index} <- KNN.new(optimizer.k, trainset, optimizer.vectorizer) do
      {:ok, %Program{index: index, student: template, bootstrap: optimizer.bootstrap}}
    end
  end

  defp default_metric(opts) do
    case Keyword.get(opts, :metric) do
      nil ->
        opts |> Keyword.put(:metric, fn _example -> 1.0 end) |> Keyword.put(:metric_threshold, 0)

      _metric ->
        opts
    end
  end
end
