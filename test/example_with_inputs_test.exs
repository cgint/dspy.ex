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

  test "Example.labels/1 returns the fields outside the selected inputs" do
    example =
      Example.new(%{"question" => "q", context: "hint", answer: nil}, %{origin: :fixture})
      |> Example.with_inputs([:question, "context", "missing"])

    labels = Example.labels(example)

    assert labels == Example.new(answer: nil)
    assert Example.input_keys(labels) == nil
    assert Example.inputs(example) == %{"question" => "q", context: "hint"}
  end

  test "Example.labels/1 distinguishes empty input selection from missing input selection" do
    example = Example.new(answer: "a")

    assert_raise ArgumentError, ~r/with_inputs/, fn -> Example.labels(example) end
    assert Example.labels(Example.with_inputs(example, [])) == example
  end

  test "Example.without/2 returns a copy preserving input selection and metadata" do
    example =
      Example.new(%{"source" => "web", question: "q", answer: nil}, %{origin: :fixture})
      |> Example.with_inputs(:question)

    updated = Example.without(example, [:source, :answer])

    assert updated.attrs == %{question: "q"}
    assert updated.metadata == example.metadata
    assert Example.labels(updated) == Example.new()
    assert Example.without(example, :question).attrs == %{"source" => "web", answer: nil}
    assert example.attrs == %{"source" => "web", question: "q", answer: nil}
  end

  test "Example.without/2 removes exact keys first and rejects missing keys" do
    example = Example.new(%{"question" => "string", question: "atom"})

    assert Example.without(example, :question).attrs == %{"question" => "string"}
    assert Example.without(example, "question").attrs == %{question: "atom"}
    assert Example.without(example, []).attrs == example.attrs
    assert_raise KeyError, fn -> Example.without(example, [:question, :missing]) end
    assert_raise KeyError, fn -> Example.without(example, [:question, :question]) end
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
