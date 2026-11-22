defmodule Dspy.StreamResponse do
  @moduledoc """
  An incremental text chunk for a selected output field in `Dspy.streamify/2`.

  The last chunk marks the end of the field. It can be empty when all text has
  already been emitted. The terminal `Dspy.Prediction` contains the validated result.

  Chunks from a managed `Dspy.Parallel` worker share an `:invocation_id` for
  each predictor call. Sequential chunks have a `nil` invocation ID.
  """

  @enforce_keys [:predict_name, :signature_field_name, :chunk, :is_last_chunk]
  defstruct [:predict_name, :signature_field_name, :chunk, :is_last_chunk, :invocation_id]

  @type t :: %__MODULE__{
          predict_name: String.t(),
          signature_field_name: atom(),
          chunk: String.t(),
          is_last_chunk: boolean(),
          invocation_id: reference() | nil
        }
end
