defmodule ProbeSig do
  use Dspy.Signature
  input_field(:q, :string, "q")
  output_field(:score, :number, "a score")
  output_field(:count, :integer, "a count")
end
sig = ProbeSig.signature()
chat = "[[ ## score ## ]]\n80%\n\n[[ ## count ## ]]\n3 apples\n"
json = ~s({"score": "80%", "count": "3 apples"})
IO.puts("chat: " <> inspect(Dspy.Signature.Adapters.ChatAdapter.parse_outputs(sig, chat, [])))
IO.puts("json: " <> inspect(Dspy.Signature.Adapters.JSONAdapter.parse_outputs(sig, json, [])))
