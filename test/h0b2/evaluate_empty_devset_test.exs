Code.require_file("h0b2_support.ex", __DIR__)

defmodule DspyEvaluateH0b2EmptyDevsetTest do
  @moduledoc """
  H0b-2 SS4 (Q3): `Dspy.Evaluate.evaluate/4` raises `ArgumentError`
  "devset must contain at least one example" when the testset is `[]`.
  """
  use ExUnit.Case

  alias Dspy.Evaluate

  test "evaluate/4 with [] raises ArgumentError" do
    program = %H0b2.Support.ForwardError{}
    metric = fn _example, _prediction -> 1.0 end
    # Q3 (H0b-2): `evaluate/4` raises on an empty testset. The @spec is
    # `list(Example.t())` (which semantically includes `[]`), but the Elixir
    # type checker narrows the empty-list literal to `-empty_list()-` and
    # warns "incompatible types" here. The `[]` input is intentional (it is the
    # Q3 guard); assigning it to a variable is the minimal way to keep the call
    # readable without a global `@compile`/`@dialyzer` suppression.
    empty = []

    assert_raise ArgumentError, "devset must contain at least one example", fn ->
      Evaluate.evaluate(program, empty, metric, num_threads: 1, progress: false)
    end
  end
end
