n = %{"identity" => nil, "default" => &Dspy.Majority.default_normalize/1,
  "nil_for_x" => fn v -> if v == "x", do: nil, else: v end,
  "false_for_x" => fn v -> if v == "x", do: false, else: v end,
  "num" => fn v -> %{"1" => 1, "1.0" => 1.0, "2" => 2}[v] end,
  "bool_num" => fn v -> %{"t" => true, "one" => 1, "z" => "z"}[v] end,
  "all_nil" => fn _ -> nil end}
out = for c <- Jason.decode!(File.read!(System.get_env("BAT"))) do
  comps = Enum.map(c["vals"], &%{answer: &1})
  try do
    r = Dspy.majority(comps, normalize: n[c["norm"]], field: :answer)
    r[:answer]
  rescue e -> "RAISE " <> inspect(e.__struct__) end
end
File.write!(System.get_env("OUT"), Jason.encode!(out))
