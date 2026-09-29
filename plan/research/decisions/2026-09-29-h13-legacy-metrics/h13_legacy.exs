pairs = Jason.decode!(File.read!(System.get_env("PAIRS")))
for [pred, gold] <- pairs do
  ex = Dspy.Example.new(%{answer: gold}); pr = Dspy.Prediction.new(%{answer: pred})
  em = Dspy.Metrics.exact_match(ex, pr); f1 = Dspy.Metrics.f1_score(ex, pr)
  IO.puts("LEGACY\t#{inspect(pred)}\t#{inspect(gold)}\tEM=#{em}\tF1=#{Float.round(f1 * 1.0, 3)}")
end
