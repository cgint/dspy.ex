xs = Jason.decode!(File.read!(System.get_env("BAT")))
f = fn {:ok, v} -> v; _ -> :reject end
out = %{
  "float" => Enum.map(xs, fn s -> case f.(Dspy.Signature.NumberParser.parse_number(s)) do :reject -> "REJECT"; v -> v * 1.0 end end),
  "int" => Enum.map(xs, fn s -> case f.(Dspy.Signature.NumberParser.parse_integer(s)) do :reject -> "REJECT"; v -> v end end)
}
File.write!(System.get_env("OUT"), Jason.encode!(out))
