defmodule Dspy.ModuleNamedSubModulesTest do
  use ExUnit.Case, async: true

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:branch, :items, :mapping, :right]
    def forward(_, _), do: {:error, :unused}
  end

  defmodule Data do
    defstruct [:child]
  end

  test "includes the root and traverses module descendants breadth first through nested containers" do
    leaf = %Program{}
    branch = %Program{branch: leaf}

    program = %Program{
      branch: branch,
      items: [[{leaf}], [leaf | :improper]],
      mapping: %{z: %{nested: leaf}, a: {leaf}},
      right: %Data{child: leaf}
    }

    assert Dspy.Module.named_sub_modules(program) == [
             {"self", program},
             {"self.branch", branch},
             {"self.branch.branch", leaf},
             {"self.mapping[:a][0]", leaf},
             {"self.mapping[:z][:nested]", leaf},
             {"self.items[0][0][0]", leaf}
           ]
  end

  test "validates the root as named_predictors does" do
    for value <- [nil, [], %{}, %Data{}] do
      assert_raise ArgumentError, ~r/module struct implementing forward\/2/, fn ->
        Dspy.Module.named_sub_modules(value)
      end
    end

    root = %Program{}
    assert Dspy.Module.named_sub_modules(root) == [{"self", root}]
  end
end
