defmodule Try do
  def run(f) do
    try do
      {:ok, f.()}
    rescue
      e -> {:raise, Exception.message(e)}
    end
  end
end

# A string-keyed map with NO field and NO single shared atom key:
# what does resolve_field do?
IO.inspect(Try.run(fn -> Dspy.majority([%{"answer" => "x"}, %{"other" => "y"}]) end), label: "two string-key maps, no field")
# Single shared string key:
IO.inspect(Try.run(fn -> Dspy.majority([%{"answer" => "x"}, %{"answer" => "y"}]) end), label: "shared string key, no field")
