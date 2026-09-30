defmodule RtProg do
  @behaviour Dspy.Module
  defstruct []
  def forward(_, inputs) do
    q = inputs["question"] || inputs[:question]
    if q == "boom", do: raise("fail"), else: {:ok, Dspy.Prediction.new(%{pred: "P, \"x\"\ny"})}
  end
end
dir = Path.join(System.tmp_dir!(), "rt_#{System.unique_integer([:positive])}"); File.mkdir_p!(dir)
ex = [Dspy.Example.new(%{"question" => "q1, with \"quotes\"\nand newline", "gold" => "2", "note" => nil}),
      Dspy.Example.new(%{"question" => "boom", "gold" => "3", "note" => ""})]
csv = Path.join(dir, "r.csv"); json = Path.join(dir, "r.json")
Dspy.Evaluate.evaluate(struct(RtProg), ex, fn _, _ -> 1.0 end, num_threads: 1, save_as_csv: csv)
Dspy.Evaluate.evaluate(struct(RtProg), ex, fn _, _ -> 1.0 end, num_threads: 1, save_as_json: json)
[header | rows] = NimbleCSV.RFC4180.parse_string(File.read!(csv), skip_headers: false)
loaded = Enum.map(rows, fn r -> Map.new(Enum.zip(header, r), fn {k, v} -> {k, if(v == "", do: nil, else: v)} end) end)
IO.puts("CSV header: " <> inspect(header))
Enum.each(loaded, &IO.puts("CSV row (M1-e load rule \"\"->nil): " <> inspect(&1)))
IO.puts("JSON: " <> File.read!(json))
