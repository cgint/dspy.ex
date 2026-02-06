defmodule Dspy.Teleprompt.GEPATest do
  use ExUnit.Case

  alias Dspy.Teleprompt.GEPA

  test "new/1 requires a :metric" do
    assert_raise ArgumentError, fn ->
      GEPA.new([])
    end
  end

  test "compile/3 returns the baseline program if no candidates are provided" do
    tp = GEPA.new(metric: fn _ex, _pred -> 0.0 end, seed: 123, candidates: [])

    program = Dspy.Predict.new("q -> a")

    assert {:ok, ^program} = GEPA.compile(tp, program, [Dspy.Example.new(%{q: "x"})])
  end
end
