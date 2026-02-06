defmodule Dspy.Teleprompt.GEPATest do
  use ExUnit.Case

  alias Dspy.Teleprompt.GEPA

  test "new/1 requires a :metric" do
    assert_raise ArgumentError, fn ->
      GEPA.new([])
    end
  end

  test "compile/3 is a stub until implementation lands" do
    tp = GEPA.new(metric: fn _ex, _pred -> 0.0 end, seed: 123)

    program = Dspy.Predict.new("q -> a")

    assert {:error, :not_implemented} =
             GEPA.compile(tp, program, [Dspy.Example.new(%{q: "x"})])
  end
end
