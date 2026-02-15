defmodule Dspy.Signature.Adapter do
  @moduledoc """
  Signature-aware adapter behaviour.

  This is intentionally distinct from `Dspy.Adapters.Adapter` (which is a generic
  format adapter). A Signature adapter is responsible for turning an LM completion
  into a signature-shaped output map (or a tagged error).

  This mirrors the conceptual role of adapters in Python DSPy.
  """

  @callback format_instructions(Dspy.Signature.t(), keyword()) :: String.t() | nil

  @callback parse_outputs(Dspy.Signature.t(), String.t(), keyword()) ::
              map() | {:error, term()}
end
