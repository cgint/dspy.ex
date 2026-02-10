defmodule Dspy.ExampleWithInputsTest do
  use ExUnit.Case, async: true

  alias Dspy.{Evaluate, Example, Prediction}

  defmodule StrictInputProgram do
    @behaviour Dspy.Module

    defstruct []

    @impl true
    def forward(_program, inputs) when is_map(inputs) do
      keys = Map.keys(inputs) |> Enum.sort()

      case keys do
        [:question] ->
          {:ok, Prediction.new(%{answer: "ok"})}

        ["question"] ->
          {:ok, Prediction.new(%{"answer" => "ok"})}

        _other ->
          {:error, {:unexpected_input_keys, keys}}
      end
    end

    @impl true
    def parameters(_program), do: []

    @impl true
    def update_parameters(program, _parameters), do: program
  end

  test "Example.with_inputs/2 filters Example.inputs/1" do
    ex = Example.new(%{question: "q", answer: "a"})
    ex = Example.with_inputs(ex, [:question])

    inputs = Example.inputs(ex)

    assert Map.get(inputs, :question) == "q"
    refute Map.has_key?(inputs, :answer)
    refute Map.has_key?(inputs, "answer")
  end

  test "Evaluate uses Example.inputs/1 when forwarding" do
    program = %StrictInputProgram{}

    ex_no_filter = Example.new(%{question: "q", answer: "a"})
    ex_filtered = Example.with_inputs(ex_no_filter, [:question])

    metric = fn _example, _pred -> 1.0 end

    r1 = Evaluate.evaluate(program, [ex_no_filter], metric, num_threads: 1, progress: false)
    assert r1.successes == 0
    assert r1.failures == 1

    r2 = Evaluate.evaluate(program, [ex_filtered], metric, num_threads: 1, progress: false)
    assert r2.successes == 1
    assert r2.failures == 0
    assert r2.mean == 1.0
  end

  test "Example input keys survive JSON parameter export/import" do
    ex = Example.new(%{question: "q", answer: "a"})
    ex = Example.with_inputs(ex, [:question])

    params = [Dspy.Parameter.new("predict.examples", :examples, [ex])]

    json = Dspy.Parameter.encode_json!(params)
    {:ok, [p2]} = Dspy.Parameter.decode_json(json)

    [ex2] = p2.value

    inputs = Example.inputs(ex2)

    assert Map.get(inputs, :question) == "q"
    refute Map.has_key?(inputs, :answer)
    refute Map.has_key?(inputs, "answer")
  end
end
