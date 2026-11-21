defmodule Dspy.Teleprompt.BootstrapTraceDataTest do
  use ExUnit.Case, async: true

  alias Dspy.{ChainOfThought, Example, Predict, Prediction, Settings, Teleprompt}
  alias Dspy.Module.PredictorTrace
  alias Dspy.Signature.AdapterPipeline
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

  defmodule ParseLM do
    @behaviour Dspy.LM
    defstruct [:owner]

    @impl true
    def generate(lm, request) do
      {:ok, prompt} = AdapterPipeline.primary_prompt_text(request)
      send(lm.owner, {:parse_request, prompt})

      cond do
        String.contains?(prompt, "leaf-terminal") and
            String.contains?(prompt, "Your previous output") ->
          {:ok, "malformed terminal retry output"}

        String.contains?(prompt, "leaf-terminal") ->
          {:ok, "malformed terminal output"}

        String.contains?(prompt, "leaf-transport") ->
          {:error, :unavailable}

        String.contains?(prompt, "leaf-provider-error") ->
          {:error, {:output_parse_failed, :provider_error, %{raw_output: "lookalike"}}}

        String.contains?(prompt, "Your previous output") ->
          {:ok, ~s({"answer":"ok","reasoning":"recovered"})}

        String.contains?(prompt, "leaf-retry") ->
          {:ok, "malformed retry output"}

        true ->
          {:ok, ~s({"answer":"ok"})}
      end
    end
  end

  defmodule ParseProgram do
    @behaviour Dspy.Module
    defstruct [:slots]

    @impl true
    def forward(program, %{question: "unobserved"}) do
      with {:ok, _} <- Dspy.call(program.slots[1], %{question: "leaf-first"}) do
        {:error, {:output_parse_failed, :manual, %{raw_output: "unobserved"}}}
      end
    end

    def forward(program, %{question: "recovered"}) do
      with {:error, {:output_parse_failed, _, _}} <-
             Dspy.call(program.slots["1"], %{question: "leaf-terminal"}) do
        Dspy.call(program.slots[1], %{question: "leaf-first"})
      end
    end

    def forward(program, %{question: question}) do
      with {:ok, _} <- Dspy.call(program.slots[1], %{question: "leaf-first"}) do
        Dspy.call(program.slots["1"], %{question: "leaf-#{question}"})
      end
    end
  end

  defmodule NestedCaptureProgram do
    @behaviour Dspy.Module
    defstruct [:program, :owner]

    @impl true
    def forward(program, inputs) do
      {:ok, prediction, trace} = PredictorTrace.capture(program.program, inputs, 1)
      send(program.owner, {:inner_steps, trace})
      {:ok, prediction}
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

  test "opt-in keeps a terminal parse row and attributes its error to the exact predictor slot" do
    predictor = parse_predictor(Predict, 0)
    program = %ParseProgram{slots: %{1 => predictor, "1" => predictor}}
    [first, failed, last] = dataset = Enum.map(["first", "terminal", "last"], &row/1)
    owner = self()

    metric = fn example, %Prediction{}, _trace ->
      send(owner, {:parse_scored, example})
      0.5
    end

    Dspy.context([cache: false], fn ->
      assert {:error,
              {:output_parse_failed, _, %{raw_output: "malformed terminal output"}} = reason} =
               Dspy.call(program, %{question: "terminal"})

      assert [
               %{example_index: 0, example: ^first, score: 0.5},
               %{
                 example_index: 1,
                 example: ^failed,
                 prediction: nil,
                 error: ^reason,
                 trace: [first_step, failure_step],
                 score: -2.5
               },
               %{example_index: 2, example: ^last, score: 0.5}
             ] =
               Teleprompt.bootstrap_trace_data(program, dataset,
                 num_threads: 3,
                 metric: metric,
                 capture_failed_parses: true,
                 format_failure_score: -2.5
               )

      assert first_step == %{
               path: [{:field, :slots}, {:key, 1}],
               inputs: %{question: "leaf-first"},
               prediction: Prediction.new(answer: "ok")
             }

      assert failure_step == %{
               path: [{:field, :slots}, {:key, "1"}],
               inputs: %{question: "leaf-terminal"},
               error: reason
             }

      assert_received {:parse_scored, ^first}
      assert_received {:parse_scored, ^last}
      refute_received {:parse_scored, _}

      assert [unscored] =
               Teleprompt.bootstrap_trace_data(program, [failed], capture_failed_parses: true)

      refute Map.has_key?(unscored, :score)

      assert [%{score: -1}] =
               Teleprompt.bootstrap_trace_data(program, [failed],
                 capture_failed_parses: true,
                 metric: metric
               )

      refute_received {:parse_scored, _}

      error = assert_raise Error, fn -> Teleprompt.bootstrap_trace_data(program, dataset) end
      assert error.example_index == 1
      assert error.reason == reason

      assert [%{example_index: 0}, %{example_index: 2}] =
               Teleprompt.bootstrap_trace_data(program, dataset, raise_on_error: false)
    end)
  end

  test "only terminal parse failures observed by a predictor can recover a failed row" do
    predictor = parse_predictor(Predict, 0)
    program = %ParseProgram{slots: %{1 => predictor, "1" => predictor}}

    Dspy.context([cache: false], fn ->
      for {question, reason} <- [
            {"unobserved", {:output_parse_failed, :manual, %{raw_output: "unobserved"}}},
            {"transport", :unavailable},
            {"provider-error",
             {:output_parse_failed, :provider_error, %{raw_output: "lookalike"}}}
          ] do
        error =
          assert_raise Error, fn ->
            Teleprompt.bootstrap_trace_data(program, [row(question)], capture_failed_parses: true)
          end

        assert error.example_index == 0
        assert error.reason == reason
      end

      assert [%{example_index: 2}] =
               Teleprompt.bootstrap_trace_data(
                 program,
                 Enum.map(["transport", "provider-error", "first"], &row/1),
                 capture_failed_parses: true,
                 raise_on_error: false
               )
    end)
  end

  test "only the opt-in sink sees an observed parse failure when the program recovers" do
    predictor = parse_predictor(Predict, 0)

    program = %NestedCaptureProgram{
      program: %ParseProgram{slots: %{1 => predictor, "1" => predictor}},
      owner: self()
    }

    Dspy.context([cache: false], fn ->
      assert [
               %{
                 prediction: %Prediction{} = prediction,
                 trace: [
                   %{
                     path: [{:field, :program}, {:field, :slots}, {:key, "1"}],
                     inputs: %{question: "leaf-terminal"},
                     error: {:output_parse_failed, _, _}
                   },
                   %{
                     path: [{:field, :program}, {:field, :slots}, {:key, 1}],
                     inputs: %{question: "leaf-first"},
                     prediction: prediction
                   }
                 ]
               } = record
             ] =
               Teleprompt.bootstrap_trace_data(program, [row("recovered")],
                 capture_failed_parses: true
               )

      refute Map.has_key?(record, :error)

      assert_received {:inner_steps,
                       [
                         {_, [{:field, :slots}, {:key, 1}], %{question: "leaf-first"},
                          ^prediction}
                       ]}
    end)
  end

  test "ChainOfThought records a recovered retry as one success and an exhausted retry as an error" do
    cot = parse_predictor(ChainOfThought, 1)

    Dspy.context([cache: false], fn ->
      assert [%{prediction: %Prediction{} = prediction, trace: [step]}] =
               Teleprompt.bootstrap_trace_data(cot, [row("leaf-retry")],
                 capture_failed_parses: true
               )

      assert step == %{path: [], inputs: %{question: "leaf-retry"}, prediction: prediction}
      assert prediction[:answer] == "ok"
      assert prediction[:reasoning] == "recovered"
      assert_received {:parse_request, initial}
      refute initial =~ "Your previous output"
      assert_received {:parse_request, retried}
      assert retried =~ "Your previous output"

      assert [
               %{
                 prediction: nil,
                 error:
                   {:output_parse_failed, _, %{raw_output: "malformed terminal retry output"}} =
                     reason,
                 trace: [%{path: [], inputs: %{question: "leaf-terminal"}, error: other_reason}]
               }
             ] =
               Teleprompt.bootstrap_trace_data(cot, [row("leaf-terminal")],
                 capture_failed_parses: true
               )

      assert reason == other_reason
      assert_received {:parse_request, exhausted_first}
      refute exhausted_first =~ "Your previous output"
      assert_received {:parse_request, exhausted_second}
      assert exhausted_second =~ "Your previous output"
      refute_received {:parse_request, _}
    end)
  end

  test "metric errors preserve the first failed index and can be skipped" do
    program = %RecordingProgram{owner: self()}
    dataset = Enum.map(["first", "bad score", "raised", "last"], &row/1)

    metric = fn row, _prediction ->
      case row[:question] do
        "bad score" -> :invalid
        "raised" -> raise "metric failed"
        _ -> 0.5
      end
    end

    error =
      assert_raise Error, fn ->
        Teleprompt.bootstrap_trace_data(program, dataset, metric: metric)
      end

    assert error.example_index == 1
    assert error.reason == {:invalid_metric_result, :invalid}

    assert [%{example_index: 0, score: 0.5}, %{example_index: 3, score: 0.5}] =
             Teleprompt.bootstrap_trace_data(program, dataset,
               metric: metric,
               raise_on_error: false
             )
  end

  test "malformed selectors fail instead of coercing a label into an input" do
    program = %RecordingProgram{owner: self()}

    for selectors <- [[1], [~c"1"], ["1" | :improper], "1"] do
      example = Example.new(%{"1" => "private"}, %{"inputs" => selectors})

      error =
        assert_raise Error, fn ->
          Teleprompt.bootstrap_trace_data(program, [example])
        end

      assert error.example_index == 0
      assert error.reason == :invalid_input_keys
    end

    refute_received {:forwarded, _}
  end

  test "raw atom selectors use the same names as with_inputs" do
    program = %RecordingProgram{owner: self()}
    attrs = %{"" => "private", "nil" => "declared"}
    legacy = Example.new(attrs, %{"inputs" => [nil]})
    canonical = Example.new(attrs) |> Example.with_inputs(nil)

    assert [_, _] = Teleprompt.bootstrap_trace_data(program, [legacy, canonical])

    for _ <- 1..2 do
      assert_received {:forwarded, inputs}
      assert inputs == %{"nil" => "declared"}
    end
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

    assert_raise ArgumentError, ~r/capture_failed_parses must be a boolean/, fn ->
      Teleprompt.bootstrap_trace_data(program, [row("ok")], capture_failed_parses: :yes)
    end

    assert_raise ArgumentError, ~r/format_failure_score must be a number/, fn ->
      Teleprompt.bootstrap_trace_data(program, [row("ok")], format_failure_score: "-2")
    end

    refute_received {:forwarded, _}
  end

  defp row(question),
    do: Example.new(question: question, answer: "gold") |> Example.with_inputs(:question)

  defp parse_predictor(module, retries) do
    module.new("question -> answer",
      lm: %ParseLM{owner: self()},
      adapter: Dspy.Signature.Adapters.JSONAdapter,
      max_retries: 0,
      max_output_retries: retries
    )
  end
end
