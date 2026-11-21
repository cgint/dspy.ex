defmodule Dspy.Teleprompt.BootstrapTraceDataTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Predict, Prediction, Settings, Teleprompt}
  alias Dspy.Teleprompt.BootstrapTrace.Error

  defmodule OfflineLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request), do: {:ok, ~s({"answer":"ok"})}
  end

  defmodule GatedProgram do
    @behaviour Dspy.Module
    defstruct [:predict, :owner]

    @impl true
    def forward(program, %{question: question} = inputs) do
      send(program.owner, {:started, question, self(), inputs})

      receive do
        :continue ->
          with {:ok, prediction} <- Predict.forward(program.predict, inputs) do
            if question == "failed", do: {:error, :failed_row}, else: {:ok, prediction}
          end
      end
    end
  end

  defmodule RecordingProgram do
    @behaviour Dspy.Module
    defstruct [:owner]

    @impl true
    def forward(program, inputs) do
      send(program.owner, {:forwarded, inputs})
      {:ok, Prediction.new(answer: "ok")}
    end
  end

  test "concurrent traces carry original indices across a partial failure" do
    owner = self()
    [first, failed, last] = dataset = Enum.map(["first", "failed", "last"], &row/1)

    predict =
      Predict.new("question -> answer",
        lm: %OfflineLM{},
        adapter: Dspy.Signature.Adapters.JSONAdapter
      )

    program = %GatedProgram{predict: predict, owner: owner}

    metric = fn example, prediction, trace ->
      send(owner, {:scored, example, prediction, trace, self(), Settings.get(:temperature)})
      example[:question] == "last"
    end

    task =
      Task.async(fn ->
        Dspy.context([temperature: 0.25, cache: false], fn ->
          Teleprompt.bootstrap_trace_data(program, dataset,
            metric: metric,
            num_threads: 3,
            raise_on_error: false
          )
        end)
      end)

    assert_receive {:started, "first", first_worker, %{question: "first"} = first_inputs}, 2_000

    assert_receive {:started, "failed", failed_worker, %{question: "failed"} = failed_inputs},
                   2_000

    assert_receive {:started, "last", last_worker, %{question: "last"} = last_inputs}, 2_000
    assert first_inputs == %{question: "first"}
    assert failed_inputs == %{question: "failed"}
    assert last_inputs == %{question: "last"}

    send(last_worker, :continue)
    assert_receive {:scored, ^last, last_prediction, last_trace, ^last_worker, 0.25}, 2_000
    send(failed_worker, :continue)
    send(first_worker, :continue)
    assert_receive {:scored, ^first, first_prediction, first_trace, ^first_worker, 0.25}, 2_000

    assert [%{path: [field: :predict], inputs: ^first_inputs, prediction: ^first_prediction}] =
             first_trace

    assert [%{path: [field: :predict], inputs: ^last_inputs, prediction: ^last_prediction}] =
             last_trace

    assert [
             %{
               example_index: 0,
               example: ^first,
               prediction: ^first_prediction,
               trace: ^first_trace,
               score: +0.0
             },
             %{
               example_index: 2,
               example: ^last,
               prediction: ^last_prediction,
               trace: ^last_trace,
               score: 1.0
             }
           ] = Task.await(task)

    refute_received {:scored, ^failed, _, _, _, _}
    refute_received {:scored, _, _, _, _, _}
  end

  test "missing input declarations are row failures and an empty selection sends no fields" do
    program = %RecordingProgram{owner: self()}
    missing = Example.new(answer: "private")
    empty = Example.with_inputs(missing, [])

    error =
      assert_raise Error, fn ->
        Teleprompt.bootstrap_trace_data(program, [missing])
      end

    assert error.example_index == 0
    assert error.reason == :missing_input_keys
    refute_received {:forwarded, _}

    assert [record] =
             Teleprompt.bootstrap_trace_data(program, [missing, empty], raise_on_error: false)

    assert record == %{
             example_index: 1,
             example: empty,
             prediction: Prediction.new(answer: "ok"),
             trace: []
           }

    assert_received {:forwarded, inputs}
    assert inputs == %{}
    refute_received {:forwarded, _}
  end

  test "metric errors preserve the first failed index and can be skipped" do
    program = %RecordingProgram{owner: self()}
    dataset = Enum.map(["bad score", "raised", "good"], &row/1)

    metric = fn row, _prediction ->
      case row[:question] do
        "bad score" -> :invalid
        "raised" -> raise "metric failed"
        "good" -> 0.5
      end
    end

    error =
      assert_raise Error, fn ->
        Teleprompt.bootstrap_trace_data(program, dataset, metric: metric)
      end

    assert error.example_index == 0
    assert error.reason == {:invalid_metric_result, :invalid}

    assert [%{example_index: 2, score: 0.5}] =
             Teleprompt.bootstrap_trace_data(program, dataset,
               metric: metric,
               raise_on_error: false
             )
  end

  test "invalid arguments fail before any call to the program" do
    program = %RecordingProgram{owner: self()}

    for dataset <- [[], [row("ok"), %{}], [row("ok") | :invalid]] do
      assert_raise ArgumentError, ~r/dataset/, fn ->
        Teleprompt.bootstrap_trace_data(program, dataset)
      end
    end

    assert_raise ArgumentError, ~r/arity/, fn ->
      Teleprompt.bootstrap_trace_data(program, [row("ok")], metric: fn _, _, _, _ -> true end)
    end

    refute_received {:forwarded, _}
  end

  defp row(question),
    do: Example.new(question: question, answer: "gold") |> Example.with_inputs(:question)
end
