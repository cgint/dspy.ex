defmodule Dspy.Signature.Adapter do
  @moduledoc """
  Signature-aware adapter behaviour.

  This is intentionally distinct from `Dspy.Adapters.Adapter` (which is a generic
  format adapter).

  A signature adapter is responsible for:

  - emitting output-format instructions for prompt construction
  - (optionally) formatting the full LM request map (e.g. `%{messages: [...]}`)
  - parsing the LM completion into a signature-shaped output map (or tagged error)

  This mirrors the conceptual role of adapters in Python DSPy.
  """

  @callback format_instructions(Dspy.Signature.t(), keyword()) :: String.t() | nil

  @doc """
  Optional callback for adapter-owned request formatting.

  If implemented, adapter-aware predictors (e.g. `Dspy.Predict`, `Dspy.ChainOfThought`)
  will use the returned request map (at minimum `messages: [...]`) as the payload
  sent to `Dspy.LM.generate/2`.

  If not implemented, callers fall back to the legacy request construction:
  build prompt via `Dspy.Signature.to_prompt/3` and send it as a single user message.
  """
  @callback format_request(Dspy.Signature.t(), map(), [Dspy.Example.t()], keyword()) ::
              Dspy.LM.request()

  @callback parse_outputs(Dspy.Signature.t(), String.t(), keyword()) ::
              map() | {:error, term()}

  @optional_callbacks [format_request: 4]
end
