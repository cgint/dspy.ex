defmodule Dspy.Teleprompt.UtilTest do
  use ExUnit.Case, async: true

  alias Dspy.Teleprompt.Util

  test "set_parameter/4 updates an existing parameter (Predict examples)" do
    program = Dspy.Predict.new("question -> answer")

    demos = [Dspy.Example.new(%{question: "q", answer: "a"})]

    assert {:ok, updated} = Util.set_parameter(program, "predict.examples", :examples, demos)
    assert is_struct(updated, Dspy.Predict)
    assert updated.examples == demos
  end

  test "set_parameter/4 appends a new parameter, but errors if the program ignores it" do
    program = Dspy.Predict.new("question -> answer")

    assert {:error, {:parameter_not_applied, "unknown.param"}} =
             Util.set_parameter(program, "unknown.param", :prompt, "x")
  end

  test "set_parameter/4 returns a type mismatch error when a parameter exists with a different type" do
    program = Dspy.Predict.new("question -> answer")

    assert {:error, {:parameter_type_mismatch, "predict.examples", expected: :prompt, got: :examples}} =
             Util.set_parameter(program, "predict.examples", :prompt, "x")
  end

  test "set_parameter/4 rejects invalid parameter types" do
    program = Dspy.Predict.new("question -> answer")

    assert {:error, {:invalid_parameter_type, :bad}} =
             Util.set_parameter(program, "predict.examples", :bad, [])
  end

  defmodule NoUpdateProgram do
    @behaviour Dspy.Module

    defstruct []

    @impl true
    def forward(_program, _inputs), do: {:ok, Dspy.Prediction.new(%{})}

    # implements parameters/1 but NOT update_parameters/2
    @impl true
    def parameters(_program), do: []
  end

  test "set_parameter/4 returns unsupported_program when update_parameters/2 is missing" do
    program = %NoUpdateProgram{}

    assert {:error, {:unsupported_program, NoUpdateProgram}} =
             Util.set_parameter(program, "x", :prompt, "y")
  end

  defmodule BadParamsProgram do
    @behaviour Dspy.Module

    defstruct []

    @impl true
    def forward(_program, _inputs), do: {:ok, Dspy.Prediction.new(%{})}

    @impl true
    def parameters(_program), do: [:not_a_param]

    @impl true
    def update_parameters(program, _params), do: program
  end

  test "set_parameter/4 returns unsupported_program when parameters/1 is not a Parameter list" do
    program = %BadParamsProgram{}

    assert {:error, {:unsupported_program, BadParamsProgram}} =
             Util.set_parameter(program, "x", :prompt, "y")
  end

  test "set_predict_instructions/2 sets predict.instructions" do
    program = Dspy.Predict.new("question -> answer")

    assert {:ok, updated} = Util.set_predict_instructions(program, "do the thing")

    assert Enum.any?(Dspy.Module.parameters(updated), fn
             %Dspy.Parameter{name: "predict.instructions", value: "do the thing"} -> true
             _ -> false
           end)
  end
end
