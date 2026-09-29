# Probe: Horst's broken model vs the mutate_m1c.py broken model, same data.
# Appended to tie-settle-real-code.log by the controller.

defmodule BrokenHorst do
  # Horst's stated model: Enum.frequencies |> Enum.max_by(fn {_k, v} -> v end) |> elem(0)
  # — first maximal entry in MAP (sorted term) order, i.e. ties by SMALLEST key.
  def winner(values) do
    values
    |> Enum.frequencies()
    |> Enum.max_by(fn {_k, v} -> v end)
    |> elem(0)
  end
end

defmodule BrokenHarness do
  # mutate_m1c.py tie-trap pattern: max_by over {count, value}
  # — highest count, ties by LARGEST value.
  def winner(values) do
    values
    |> Enum.frequencies()
    |> Enum.max_by(fn {value, count} -> {count, value} end)
    |> elem(0)
  end
end

for ds <- ["b,a", "9,a", "x,y,y,x", "2,3,4"] do
  values = String.split(ds, ",")
  h = BrokenHorst.winner(values)
  m = BrokenHarness.winner(values)
  IO.puts("#{ds}  horst-model=#{inspect(h)}  harness-model=#{inspect(m)}")
end
