cases = Jason.decode!(File.read!(System.get_env("BAT")))
out = for [ans, ctx] <- cases do
  try do
    Dspy.Metrics.answer_passage_match(Dspy.Example.new(%{answer: ans}), Dspy.Prediction.new(%{context: ctx}))
  rescue e -> "RAISE " <> inspect(e.__struct__) end
end
File.write!(System.get_env("OUT"), Jason.encode!(out))
