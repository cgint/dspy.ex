# Run with: mix run examples/raw_output_on_parse_failure.exs
#
# Demonstrates that a pipeline-backed structured-output failure preserves the
# original parse reason and the model's complete response text.

defmodule RawOutputOnParseFailureDemo.Signature do
  use Dspy.Signature

  input_field(:question, :string, "Question for the model")
  output_field(:result, :string, "Required answer")
end

defmodule RawOutputOnParseFailureDemo.MockLM do
  @behaviour Dspy.LM

  defstruct []

  @impl true
  def generate(_lm, _request) do
    {:ok,
     %{
       choices: [
         %{
           message: %{
             role: "assistant",
             content: ~s({"explanation":"I returned valid JSON, but omitted result."})
           },
           finish_reason: "stop"
         }
       ],
       usage: nil
     }}
  end

  @impl true
  def supports?(_lm, _feature), do: true
end

Dspy.configure(lm: struct(RawOutputOnParseFailureDemo.MockLM))

predictor =
  Dspy.Predict.new(RawOutputOnParseFailureDemo.Signature,
    max_retries: 0,
    max_output_retries: 0
  )

IO.inspect(
  Dspy.Module.forward(predictor, %{question: "Show the parse failure"}),
  label: "Pipeline result"
)
