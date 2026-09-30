defmodule DemoSig do
  use Dspy.Signature
  input_field(:question, :string, "q")
  output_field(:answer, :string, "a")
end
defmodule CapLM do
  @behaviour Dspy.LM
  defstruct [:pid]
  def generate(%{pid: pid}, req) do
    send(pid, {:req, req})
    {:ok, %{choices: [%{message: %{role: "assistant", content: "[[ ## answer ## ]]\nok"}, finish_reason: "stop"}], usage: nil}}
  end
  def supports?(_, _), do: true
end
Dspy.configure(lm: struct(CapLM, pid: self()))
text = fn demos ->
  p = Dspy.Predict.new(DemoSig, examples: demos)
  Dspy.Module.forward(p, %{question: "Q?"})
  receive do {:req, r} -> r.messages |> Enum.map(&(&1[:content] || &1["content"])) |> Enum.join("\n---\n") after 2000 -> "no request" end
end
atom = text.([Dspy.Example.new(%{question: "DEMO_Q", answer: "DEMO_A"})])
str  = text.([Dspy.Example.new(%{"question" => "DEMO_Q", "answer" => "DEMO_A"})])
IO.puts("atom-keyed demo in prompt: #{String.contains?(atom, "DEMO_Q") and String.contains?(atom, "DEMO_A")}")
IO.puts("string-keyed demo in prompt: #{String.contains?(str, "DEMO_Q") and String.contains?(str, "DEMO_A")}")
IO.puts("prompts identical: #{atom == str}"); IO.puts("string-keyed: has DEMO_Q=#{String.contains?(str, "DEMO_Q")} has DEMO_A=#{String.contains?(str, "DEMO_A")}")
