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
  def format_request(%Dspy.Signature{} = signature, inputs, demos, opts \\ [])
      when is_map(inputs) and is_list(demos) do
    with {:ok, %{inputs: filtered_inputs, messages: history_messages}} <-
           Dspy.History.extract_messages(signature, inputs) do
      filtered_signature = %{
        signature
        | input_fields: Enum.reject(signature.input_fields, &(&1.type == :history))
      }

      prompt =
        Dspy.Signature.AdapterPipeline.legacy_prompt(
          filtered_signature,
          filtered_inputs,
          demos,
          __MODULE__,
          opts
        )

      %{messages: history_messages ++ [%{role: "user", content: prompt}]}
    end
  end

  @impl true
  def parse_outputs(%Dspy.Signature{} = signature, text, _opts \\ []) when is_binary(text) do
    Dspy.Signature.parse_outputs(signature, text)
  end
end
