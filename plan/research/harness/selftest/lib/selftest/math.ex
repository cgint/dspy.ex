defmodule Selftest.Math do
  @doc "Add two numbers."
  def add(a, b), do: a + b

  @doc "Clamp a number to [0.0, 1.0]."
  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))

  @doc "Harmonic-style F1 of two scores, 0.0 when both are 0."
  def f1(a, b) do
    x = clamp01(a)
    y = clamp01(b)

    if x + y == 0.0 do
      0.0
    else
      2.0 * x * y / (x + y)
    end
  end

  @doc "Look up a key; raises ArgumentError on missing keys."
  def fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing #{key}"
    end
  end
end
