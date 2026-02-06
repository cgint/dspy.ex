defmodule Dspy.Teleprompt.GEPA do
  @moduledoc """
  GEPA teleprompter (roadmap-first).

  This module is a **stub** to lock in the public interface and enable
  contract tests while the full optimizer is implemented.

  Spec anchor: `plan/GEPA.md`.
  """

  @behaviour Dspy.Teleprompt

  alias Dspy.Example

  defstruct [:metric, :seed]

  @type t :: %__MODULE__{
          metric: Dspy.Teleprompt.metric_fun(),
          seed: integer()
        }

  @impl Dspy.Teleprompt
  def new(opts \\ []) do
    case Dspy.Teleprompt.validate_config(opts) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, reason
    end

    seed = Keyword.get(opts, :seed, 0)

    unless is_integer(seed) do
      raise ArgumentError, ":seed must be an integer"
    end

    %__MODULE__{
      metric: Keyword.fetch!(opts, :metric),
      seed: seed
    }
  end

  @impl Dspy.Teleprompt
  @spec compile(t(), Dspy.Teleprompt.program_t(), list(Example.t())) :: Dspy.Teleprompt.compile_result()
  def compile(%__MODULE__{}, _program, _trainset) do
    {:error, :not_implemented}
  end
end
