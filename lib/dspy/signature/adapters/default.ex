defmodule Dspy.Signature.Adapters.Default do
  @moduledoc """
  Default signature adapter.

  This adapter intentionally preserves the existing parsing behavior implemented
  by `Dspy.Signature.parse_outputs/2`.

  It exists so the core Predict pipeline can be adapter-driven without changing
  the semantics of existing users/tests.
  """

  @behaviour Dspy.Signature.Adapter

  @impl true
  def format_instructions(%Dspy.Signature{} = signature, _opts \\ []) do
    output_format =
      signature.output_fields
      |> Enum.map(fn field ->
        "#{String.capitalize(Atom.to_string(field.name))}: [your #{field.description}]"
      end)
      |> Enum.join("\n")

    "Follow this exact format for your response:\n#{output_format}"
  end

  @impl true
  def parse_outputs(%Dspy.Signature{} = signature, text, _opts \\ []) when is_binary(text) do
    Dspy.Signature.parse_outputs(signature, text)
  end
end
