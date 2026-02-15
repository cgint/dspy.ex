# Offline, deterministic demo of adapter selection.
#
# Shows:
# - global adapter config via `Dspy.configure(adapter: ...)`
# - per-predictor override via `Dspy.Predict.new(..., adapter: ...)`
#
# Run:
#   mix run examples/offline/adapter_selection_offline.exs


defmodule AdapterSelectionOfflineDemo do
  defmodule SimpleSignature do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule StaticLMLabels do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Answer: ok\n"},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule StaticLMJson do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: ~s({"answer":"ok"})},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  def run do
    predict = Dspy.Predict.new(SimpleSignature)

    IO.puts("== Default adapter (JSON fallback, then labels) ==")

    Dspy.configure(
      lm: %StaticLMLabels{},
      adapter: Dspy.Signature.Adapters.Default
    )

    {:ok, pred} = Dspy.call(predict, %{question: "Hello?"})
    IO.inspect(pred.attrs, label: "outputs")

    IO.puts("\n== JSON-only adapter (strict; no label fallback) ==")

    Dspy.configure(
      lm: %StaticLMLabels{},
      adapter: Dspy.Signature.Adapters.JSONAdapter
    )

    case Dspy.call(predict, %{question: "Hello?"}) do
      {:ok, pred2} ->
        IO.inspect(pred2.attrs, label: "outputs")

      {:error, reason} ->
        IO.inspect(reason, label: "expected error")
    end

    IO.puts("\n== JSON-only adapter with JSON-shaped LM output ==")

    Dspy.configure(
      lm: %StaticLMJson{},
      adapter: Dspy.Signature.Adapters.JSONAdapter
    )

    {:ok, pred3} = Dspy.call(predict, %{question: "Hello?"})
    IO.inspect(pred3.attrs, label: "outputs")

    IO.puts("\n== Predictor override beats global adapter ==")

    # Global is strict...
    Dspy.configure(
      lm: %StaticLMLabels{},
      adapter: Dspy.Signature.Adapters.JSONAdapter
    )

    # ...but this predictor forces the default behavior.
    predict_default =
      Dspy.Predict.new(SimpleSignature, adapter: Dspy.Signature.Adapters.Default)

    {:ok, pred4} = Dspy.call(predict_default, %{question: "Hello?"})
    IO.inspect(pred4.attrs, label: "outputs")

    :ok
  end
end

AdapterSelectionOfflineDemo.run()
