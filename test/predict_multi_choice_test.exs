defmodule Dspy.PredictMultiChoiceTest do
  use ExUnit.Case, async: true

  alias Dspy.{ChainOfThought, Completions, Predict, Prediction}
  alias Dspy.Signature.Adapters.{Default, JSONAdapter, TwoStep}

  defmodule Answer do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule AnswerWithNote do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
    output_field(:note, :string, "Optional note", required: false)
  end

  defmodule ToolAnswer do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:calls, :tool_calls, "Tool calls")
  end

  defmodule ScriptedLM do
    defstruct [:observer, :script]

    def generate(lm, request) do
      send(lm.observer, {:lm_request, request})
      Agent.get_and_update(lm.script, fn [response | rest] -> {{:ok, response}, rest} end)
    end
  end

  defmodule ObserveParsing do
    @behaviour Dspy.Signature.Adapter.Callback

    @impl true
    def on_adapter_format_start(_meta, _payload, observer), do: observer

    @impl true
    def on_adapter_format_end(_meta, _payload, observer), do: observer

    @impl true
    def on_adapter_call_start(_meta, _payload, observer), do: observer

    @impl true
    def on_adapter_call_end(_meta, _payload, observer), do: observer

    @impl true
    def on_adapter_parse_start(meta, payload, observer) do
      send(observer, {:parse_start, meta.attempt, payload})
      observer
    end

    @impl true
    def on_adapter_parse_end(meta, payload, observer) do
      send(observer, {:parse_end, meta.attempt, payload})
      observer
    end
  end

  test "one native request returns ordered rows and fills absent optional fields" do
    response = %{
      choices: [
        %{message: %{content: "Answer: first\nNote: extra"}},
        %{"message" => %{"content" => "Answer: second"}}
      ]
    }

    predictor =
      Predict.new(AnswerWithNote,
        lm: scripted_lm([response]),
        config: [n: 2, temperature: 0.0],
        callbacks: [{ObserveParsing, self()}]
      )

    assert {:ok, prediction} = Dspy.call(predictor, %{question: "What happened?"})
    assert_receive {:lm_request, %{n: 2, temperature: temperature}}
    assert temperature === 0.0
    refute_received {:lm_request, _}
    assert_receive {:parse_start, 1, %{choices_count: 2}}
    assert_receive {:parse_end, 1, %{choices_count: 2}}
    refute_received {:parse_start, _, _}
    refute_received {:parse_end, _, _}
    assert prediction[:answer] == "first"
    assert Prediction.completions(prediction) == []

    parsed = Prediction.parsed_completions(prediction)
    assert Completions.size(parsed) == 2
    assert Completions.fetch(parsed, :answer) == {:ok, ["first", "second"]}
    assert Completions.fetch(parsed, :note) == {:ok, ["extra", nil]}
    assert Completions.signature(parsed) == predictor.signature
  end

  test "an explicit count of one gives ChainOfThought a collection and nil clears the option" do
    response = response(["Reasoning: because\nAnswer: yes"])
    predictor = ChainOfThought.new(Answer, lm: scripted_lm([response, response, response]))

    assert {:ok, ordinary} = Dspy.call(predictor, %{question: "Why?"})
    assert_receive {:lm_request, request}
    refute Map.has_key?(request, :n)
    assert Prediction.parsed_completions(ordinary) == nil

    assert {:ok, prediction} = Dspy.call(predictor, %{question: "Why?"}, config: [n: 1])
    assert_receive {:lm_request, %{n: 1}}

    parsed = Prediction.parsed_completions(prediction)
    assert Completions.size(parsed) == 1
    assert Completions.fetch(parsed, :reasoning) == {:ok, ["because"]}
    assert Completions.signature(parsed) == predictor.signature

    configured = ChainOfThought.update_config(predictor, n: 2)
    assert {:ok, cleared} = Dspy.call(configured, %{question: "Why?"}, config: [n: nil])
    assert_receive {:lm_request, request}
    refute Map.has_key?(request, :n)
    assert Prediction.parsed_completions(cleared) == nil
  end

  test "a later parse error retries the entire request without retaining earlier rows" do
    first = response([~s({"answer":"discarded"}), "invalid JSON"])
    retry = response([~s({"answer":"new first"}), ~s({"answer":"new second"})])

    predictor =
      Predict.new(Answer,
        adapter: JSONAdapter,
        lm: scripted_lm([first, retry]),
        max_output_retries: 1,
        config: [n: 2]
      )

    assert {:ok, prediction} = Dspy.call(predictor, %{question: "Pick one"})
    assert_receive {:lm_request, %{n: 2} = request}
    assert_receive {:lm_request, %{n: 2} = retry_request}
    assert retry_request.messages != request.messages
    refute_received {:lm_request, _}

    assert Completions.fetch(Prediction.parsed_completions(prediction), :answer) ==
             {:ok, ["new first", "new second"]}
  end

  test "a missing choice is a non-retryable count mismatch" do
    predictor =
      Predict.new(Answer,
        lm: scripted_lm([response(["Answer: just one"])]),
        max_output_retries: 2,
        config: [n: 2]
      )

    assert Dspy.call(predictor, %{question: "Pick one"}) ==
             {:error, {:unexpected_choice_count, %{expected: 2, actual: 1}}}

    assert_receive {:lm_request, %{n: 2}}
    refute_received {:lm_request, _}
  end

  test "a terminal parse error carries the later choice and its raw output" do
    predictor =
      Predict.new(Answer,
        adapter: JSONAdapter,
        lm: scripted_lm([response([~s({"answer":"one"}), "invalid JSON"])]),
        max_output_retries: 0,
        config: [n: 2]
      )

    assert {:error,
            {:output_parse_failed, {:output_decode_failed, _},
             %{raw_output: "invalid JSON", choice_index: 1}}} =
             Dspy.call(predictor, %{question: "Pick one"})

    assert_receive {:lm_request, %{n: 2}}
    refute_received {:lm_request, _}
  end

  test "unsupported providers and adapter paths fail before contacting a model" do
    req_llm =
      Dspy.LM.ReqLLM.new(
        model: "openai:gpt-4o-mini",
        client_module: ScriptedLM,
        generation_module: ScriptedLM
      )

    guarded_model = scripted_lm([])

    for {signature, adapter, lm, reason} <- [
          {Answer, Default, req_llm, {:lm, Dspy.LM.ReqLLM}},
          {Answer, Default, %Dspy.LM.Bumblebee{}, {:lm, Dspy.LM.Bumblebee}},
          {Answer, TwoStep, guarded_model, {:adapter, TwoStep}},
          {ToolAnswer, Default, guarded_model, :tool_calls}
        ] do
      predictor = Predict.new(signature, adapter: adapter, lm: lm, config: [n: 2])

      assert Dspy.call(predictor, %{question: "Pick one"}) ==
               {:error, {:multiple_choices_unsupported, reason}}
    end

    refute_received {:lm_request, _}
  end

  test "invalid counts are rejected before a request" do
    predictor = Predict.new(Answer, lm: scripted_lm([]))

    for count <- [0, -1, 1.5, "2", true] do
      assert_raise ArgumentError, ~r/invalid predictor config/, fn ->
        Dspy.call(predictor, %{question: "Pick one"}, config: [n: count])
      end
    end

    refute_received {:lm_request, _}
  end

  test "the request count partitions cached responses" do
    model =
      scripted_lm([
        response(["Answer: ordinary"]),
        response(["Answer: first", "Answer: second"])
      ])

    predictor = Predict.new(Answer, lm: model)
    input = %{question: "Pick one"}

    Dspy.context([cache: true], fn ->
      assert {:ok, ordinary} = Dspy.call(predictor, input)
      assert ordinary[:answer] == "ordinary"
      assert_receive {:lm_request, request}
      refute Map.has_key?(request, :n)

      assert {:ok, multiple} = Dspy.call(predictor, input, config: [n: 2])
      assert multiple[:answer] == "first"
      assert_receive {:lm_request, %{n: 2}}

      assert {:ok, ^multiple} = Dspy.call(predictor, input, config: [n: 2])
      refute_received {:lm_request, _}
    end)
  end

  defp scripted_lm(responses) do
    script = start_supervised!({Agent, fn -> responses end})
    %ScriptedLM{observer: self(), script: script}
  end

  defp response(texts), do: %{choices: Enum.map(texts, &%{message: %{content: &1}})}
end
