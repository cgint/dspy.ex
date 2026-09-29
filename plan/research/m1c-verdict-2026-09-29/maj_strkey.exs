p = fn attrs -> Dspy.Prediction.new(attrs) end
cases = [
  {"string-keyed Prediction, field: :answer", [p.(%{"answer" => "a"}), p.(%{"answer" => "a"}), p.(%{"answer" => "b"})], [field: :answer]},
  {"string-keyed Prediction, present nil + identity", [p.(%{"answer" => nil}), p.(%{"answer" => "a"})], [field: :answer, normalize: nil]},
  {"atom-keyed Prediction, present nil + identity", [p.(%{answer: nil}), p.(%{answer: "a"})], [field: :answer, normalize: nil]},
  {"map, present nil + identity", [%{answer: nil}, %{answer: "a"}], [field: :answer, normalize: nil]},
  {"map, present nil + default normaliser", [%{answer: nil}, %{answer: "a"}], [field: :answer]},
  {"map, absent key", [%{other: "x"}, %{answer: "a"}], [field: :answer]},
  {"string :field", [%{answer: "a"}], [field: "answer"]}
]
for {label, comps, opts} <- cases do
  r = try do
    w = Dspy.majority(comps, opts); "OK -> #{inspect(w[:answer] || w["answer"])}"
  rescue e -> "RAISE #{inspect(e.__struct__)}: #{Exception.message(e) |> String.slice(0, 70)}" end
  IO.puts("#{label}: #{r}")
end
