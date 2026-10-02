defmodule Dspy.StringKeysTest do
  @moduledoc """
  H15 acceptance rows: one canonical accessor for `attrs` (string-key audit).

  Contract: `openspec/changes/h15-string-key-audit/` (LOCKED, rulings R1–R5).
  Every row builds its data with STRING keys and goes through the PUBLIC entry
  unless the row says otherwise.
  """
  use ExUnit.Case, async: false

  alias Dspy.{Example, Prediction, Signature, Trainset}
  alias Dspy.Metrics
  alias Dspy.Signature.Adapters.{Default, JSONAdapter}

  # ---------------------------------------------------------------------------
  # Capturing LM for the demo-rendering rows (5, 6, 7, 14).
  # Emits a JSON-object completion (parsable by both Default and JSONAdapter)
  # and sends the raw request to the caller.
  # ---------------------------------------------------------------------------
  defmodule CapLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%{pid: pid}, req) do
      send(pid, {:req, req})

      {:ok,
       %{
         choices: [
           %{
             message: %{
               role: "assistant",
               content: Jason.encode!(%{answer: "ok", rationale: "ok"})
             },
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule CapSig do
    use Dspy.Signature
    input_field(:question, :string, "q")
    output_field(:answer, :string, "a")
  end

  defmodule AnswerSig do
    use Dspy.Signature
    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defp capture_prompt(demos, adapter, inputs) do
    lm = %CapLM{pid: self()}
    Dspy.configure(lm: lm)

    predict = Dspy.Predict.new(CapSig, examples: demos, adapter: adapter)
    _ = Dspy.Module.forward(predict, inputs)

    receive do
      {:req, req} ->
        req.messages
        |> Enum.map(&(&1[:content] || &1["content"]))
        |> Enum.map_join("", fn part ->
          if is_list(part) do
            Enum.map_join(part, "", fn
              %{"type" => "text", "text" => t} -> t
              _ -> ""
            end)
          else
            to_string(part)
          end
        end)
    after
      2_000 -> flunk("no LM request captured")
    end
  end

  # ---------------------------------------------------------------------------
  # P1 — Metrics (rows 1-4)
  # ---------------------------------------------------------------------------
  test "row 1: answer_exact_match string-keyed example and prediction → true" do
    example = Example.new(%{"answer" => "Paris"})
    prediction = Prediction.new(%{"answer" => "Paris"})

    assert Metrics.answer_exact_match(example, prediction)
    assert Enum.all?(Map.keys(example.attrs), &is_binary/1)
    assert Enum.all?(Map.keys(prediction.attrs), &is_binary/1)
  end

  test "row 2: answer_passage_match string-keyed context → true" do
    example = Example.new(%{"answer" => "Paris"})

    prediction =
      Prediction.new(%{"context" => ["The Eiffel Tower is in Paris, the capital of France."]})

    assert Metrics.answer_passage_match(example, prediction)
    assert Enum.all?(Map.keys(prediction.attrs), &is_binary/1)
  end

  test "row 3: answer missing in both forms → raises \"example[:answer] is missing\"" do
    example = Example.new(%{something: "else"})
    prediction = Prediction.new(%{"answer" => "Paris"})

    assert_raise ArgumentError, "example[:answer] is missing", fn ->
      Metrics.answer_exact_match(example, prediction)
    end
  end

  defmodule Row4LM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: Paris"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  test "row 4: Evaluate over a string-keyed devset scores 100.0, failures 0" do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %Row4LM{})

    program = Dspy.Predict.new(AnswerSig)

    devset =
      for q <- 1..3, do: Example.new(%{"question" => "q#{q}", "answer" => "Paris"})

    assert Enum.all?(devset, fn ex -> Enum.all?(Map.keys(ex.attrs), &is_binary/1) end)

    result =
      Dspy.Evaluate.evaluate(program, devset, &Metrics.answer_exact_match/2, progress: false)

    assert_in_delta result.mean, 1.0, 1.0e-9
    assert result.failures == 0
  end

  # ---------------------------------------------------------------------------
  # P2 — demo rendering (rows 5-7)
  # ---------------------------------------------------------------------------
  test "row 5: Default adapter renders string-keyed demo values" do
    demo = Example.new(%{"question" => "DEMO_Q", "answer" => "DEMO_A"})
    assert Enum.all?(Map.keys(demo.attrs), &is_binary/1)

    prompt = capture_prompt([demo], Default, %{question: "Q?"})

    assert String.contains?(prompt, "DEMO_Q")
    assert String.contains?(prompt, "DEMO_A")
  end

  test "row 6: JSON adapter renders string-keyed demo values" do
    demo = Example.new(%{"question" => "DEMO_Q", "answer" => "DEMO_A"})
    assert Enum.all?(Map.keys(demo.attrs), &is_binary/1)

    prompt = capture_prompt([demo], JSONAdapter, %{question: "Q?"})

    assert String.contains?(prompt, "DEMO_Q")
    assert String.contains?(prompt, "DEMO_A")
  end

  # Golden prompts captured from 3fcbea1 BEFORE any H15 edit
  # (plan/research/pi_handoffs/h15/golden_capture.exs).
  @default_golden "Follow this exact format for your response:\nAnswer: [your a]\n\n" <>
                    "Input Fields:\n- question: q\n\n" <>
                    "Output Fields:\n- answer: a\n\n" <>
                    "Examples:\n\n" <>
                    "Example 1:\nQuestion: DEMO_Q\nAnswer: DEMO_A\n\n" <>
                    "Example 2:\nQuestion: MISSING_Q\nAnswer: \n\n" <>
                    "Question: Q?\nAnswer:"

  @json_golden "Return JSON only. Return one valid JSON object conforming to this complete " <>
                 "output contract:\n" <>
                 ~s({"additionalProperties":true,"properties":{"answer":{"type":"string"}},"required":["answer"],"type":"object"}) <>
                 "\nExample: {\"answer\":\"\"}\nDo not include any other text.\n\n" <>
                 "Input Fields:\n- question: q\n\n" <>
                 "Output Fields:\n- answer: a\n\n" <>
                 "Examples:\n\n" <>
                 "Example 1:\nQuestion: DEMO_Q\nAnswer: DEMO_A\n\n" <>
                 "Example 2:\nQuestion: MISSING_Q\nAnswer: \n\n" <>
                 "Question: Q?\nAnswer:"

  test "row 7: atom-keyed demo prompts byte-identical to 3fcbea1" do
    demos = [
      Example.new(%{question: "DEMO_Q", answer: "DEMO_A"}),
      Example.new(%{question: "MISSING_Q"})
    ]

    assert capture_prompt(demos, Default, %{question: "Q?"}) == @default_golden
    assert capture_prompt(demos, JSONAdapter, %{question: "Q?"}) == @json_golden
  end

  # ---------------------------------------------------------------------------
  # S4 — metrics field helpers (row 8)
  # ---------------------------------------------------------------------------
  test "row 8: exact_match / f1_score / contains on string keys" do
    example = Example.new(%{"answer" => "Eiffel Tower"})
    prediction = Prediction.new(%{"answer" => "Eiffel Tower"})

    assert Enum.all?(Map.keys(example.attrs), &is_binary/1)
    assert Metrics.exact_match(example, prediction) == 1.0
    assert Metrics.f1_score(example, prediction) >= 0.99
    assert Metrics.contains(example, prediction)

    example2 = Example.new(%{"answer" => "Eiffel Tower"})
    prediction2 = Prediction.new(%{"answer" => "Eiffel Tower in Paris"})
    assert Metrics.contains(example2, prediction2) >= 1.0
    assert Metrics.exact_match(example2, prediction2) == 0.0
  end

  # ---------------------------------------------------------------------------
  # S5-S8 — Trainset (rows 9-12)
  # ---------------------------------------------------------------------------
  test "row 9: stratified_sample groups by a string-keyed field" do
    trainset =
      for cat <- [:cat, :cat, :dog, :dog, :dog] do
        Example.new(%{"label" => to_string(cat), "q" => "q"})
      end

    assert Enum.all?(trainset, fn ex -> Enum.all?(Map.keys(ex.attrs), &is_binary/1) end)

    # 2 cats, 3 dogs -> 3 samples = 2 cats + 1 dog. This composition is what
    # string-keyed groups produce (two groups, remainder to the first group);
    # with atom keys the labels would be nil and all examples would fall
    # into ONE group, giving 3 cats instead.
    sample = Trainset.stratified_sample(trainset, 3, :label)
    assert length(sample) == 3
    labels = sample |> Enum.map(&Example.get(&1, :label)) |> Enum.sort()
    assert labels == ["cat", "cat", "dog"]
  end

  test "row 10: filter_quality keyword criteria on string keys" do
    trainset = [
      Example.new(%{"question" => "keep me"}),
      Example.new(%{"question" => ""}),
      Example.new(%{"other" => "no question field"})
    ]

    sample = Trainset.filter_quality(trainset, required_fields: [:question])
    assert length(sample) == 1
    assert Example.get(hd(sample), :question) == "keep me"
  end

  test "row 11: hard strategy orders by string \"difficulty\"" do
    # Values chosen so the 0.5 default would give a different order.
    trainset = [
      Example.new(%{"q" => "low", "difficulty" => 0.1}),
      Example.new(%{"q" => "high", "difficulty" => 0.9}),
      Example.new(%{"q" => "mid", "difficulty" => 0.4})
    ]

    assert Enum.all?(trainset, fn ex -> Enum.all?(Map.keys(ex.attrs), &is_binary/1) end)

    [first, second] = Trainset.sample(trainset, 2, strategy: :hard, seed: 1)
    assert Example.get(first, :q) == "high"
    assert Example.get(second, :q) == "mid"
  end

  test "row 12: uncertainty strategy uses string \"uncertainty\"" do
    # Values chosen so the 0.5 default would give a different order.
    trainset = [
      Example.new(%{"q" => "sure", "uncertainty" => 0.1}),
      Example.new(%{"q" => "unsure", "uncertainty" => 0.9}),
      Example.new(%{"q" => "meh", "uncertainty" => 0.4})
    ]

    assert Enum.all?(trainset, fn ex -> Enum.all?(Map.keys(ex.attrs), &is_binary/1) end)

    [first, second] = Trainset.sample(trainset, 2, strategy: :uncertainty, seed: 1)
    assert Example.get(first, :q) == "unsure"
    assert Example.get(second, :q) == "meh"
  end

  # ---------------------------------------------------------------------------
  # S9 — Ensemble confidence-based (row 13)
  # ---------------------------------------------------------------------------
  defmodule FixedAnswerModule do
    @moduledoc false
    use Dspy.Module

    defstruct [:answer, :confidence]

    def new(answer, confidence) do
      %__MODULE__{answer: answer, confidence: confidence}
    end

    @impl true
    def forward(%__MODULE__{} = mod, _inputs) do
      {:ok,
       Prediction.new(%{
         "answer" => mod.answer,
         "confidence" => mod.confidence
       })}
    end
  end

  test "row 13: :confidence_based picks the member with the highest string \"confidence\"" do
    # Both values != 0.5 and ordering differs from the 0.5 default.
    ensemble = %Dspy.Teleprompt.Ensemble.Program{
      members: [
        FixedAnswerModule.new("a", 0.2),
        FixedAnswerModule.new("b", 0.8)
      ],
      weights: [1.0, 1.0],
      strategy: :confidence_based,
      num_threads: 1
    }

    assert {:ok, prediction} = Dspy.Module.forward(ensemble, %{question: "Q?"})
    assert Prediction.get(prediction, "answer") == "b"
  end

  # ---------------------------------------------------------------------------
  # S10 — MultiChainComparison (row 14)
  # ---------------------------------------------------------------------------
  test "row 14: MultiChainComparison renders a string-keyed Prediction's rationale and answer" do
    Dspy.configure(lm: %CapLM{pid: self()})

    mcc = Dspy.MultiChainComparison.new(AnswerSig, m: 2)

    completions = [
      Prediction.new(%{"rationale" => "R1 reason", "answer" => "A1"}),
      Prediction.new(%{"rationale" => "R2 reason", "answer" => "A2"})
    ]

    assert Enum.all?(completions, fn p -> Enum.all?(Map.keys(p.attrs), &is_binary/1) end)

    assert {:ok, _} = Dspy.Module.forward(mcc, %{question: "Q?", completions: completions})

    assert_receive {:req, req}

    prompt =
      req.messages
      |> Enum.map(&(&1[:content] || &1["content"]))
      |> Enum.map_join("", fn part ->
        if is_list(part) do
          Enum.map_join(part, "", fn
            %{"type" => "text", "text" => t} -> t
            _ -> ""
          end)
        else
          to_string(part)
        end
      end)

    assert String.contains?(prompt, "R1 reason")
    assert String.contains?(prompt, "A1")
    assert String.contains?(prompt, "R2 reason")
    assert String.contains?(prompt, "A2")
  end

  # ---------------------------------------------------------------------------
  # S11 — majority (rows 15-19)
  # ---------------------------------------------------------------------------
  test "row 15: majority over string-keyed maps with field: :answer" do
    result =
      Dspy.majority([%{"answer" => "2"}, %{"answer" => "2"}, %{"answer" => "3"}], field: :answer)

    assert result.attrs["answer"] == "2"
  end

  test "row 16: majority mixes atom- and string-keyed maps under field: :answer into one tally" do
    result =
      Dspy.majority([%{"answer" => "2"}, %{answer: "2"}, %{"answer" => "3"}], field: :answer)

    assert Dspy.Majority.default_normalize(result.attrs["answer"] || result.attrs[:answer]) == "2"
  end

  test "row 17: majority with only \"answer\" keys and no :field (passes today; pinned)" do
    result = Dspy.majority([%{"answer" => "2"}, %{"answer" => "2"}, %{"answer" => "3"}])
    assert result.attrs["answer"] == "2"
  end

  test "row 18: majority on a map with both :answer and \"answer\" raises naming both" do
    assert_raise ArgumentError, ~r/holds both :answer and "answer"/, fn ->
      Dspy.majority([Map.put(%{answer: "2"}, "answer", "x")], field: :answer)
    end
  end

  test "row 19: majority missing-field error no longer carries the atom-keys hint" do
    try do
      Dspy.majority([%{other: "2"}], field: :answer)
      flunk("expected ArgumentError")
    rescue
      e ->
        assert %ArgumentError{} = e
        # The missing-field error must NOT carry the old atom-keys hint.
        refute String.contains?(Exception.message(e), "maps must use atom keys")
        assert String.contains?(Exception.message(e), ":answer")
    end
  end

  test "row 19b: majority missing-field error names the completion and field" do
    # Pins the exact shape of the missing-field raise so MR11c (hint text
    # restored in the message) cannot survive: any hint appended to the
    # message fails this byte-exact assertion.
    try do
      Dspy.majority([%{other: "2"}], field: :answer)
      flunk("expected ArgumentError")
    rescue
      e ->
        assert %ArgumentError{message: msg} = e

        assert msg ==
                 ~s(Dspy.majority/2: completion %{other: "2"} is missing field :answer)
    end
  end

  # ---------------------------------------------------------------------------
  # A1 — accessor precedence (row 20)
  # ---------------------------------------------------------------------------
  test "row 20: Example.get / Prediction.get — atom wins when both forms exist" do
    dual = Map.put(%{answer: "atom"}, "answer", "string")
    example = %Example{attrs: dual}
    prediction = %Prediction{attrs: dual}

    # Atom key finds the atom value, not the string value.
    assert Example.get(example, :answer) == "atom"
    assert Prediction.get(prediction, :answer) == "atom"

    # String key finds only the string value (no atom is ever created).
    assert Example.get(example, "answer") == "string"
    assert Prediction.get(prediction, "answer") == "string"

    # An atom key that has NO atom form in the map but HAS a string form
    # must fall back to the string value. This is the path MS3 (plain
    # Map.get) cannot reproduce: Map.get(attrs, :answer) on a string-keyed
    # map returns nil, not the string value.
    string_only = Example.new(%{"answer" => "str-only"})
    atom_only = Prediction.new(%{answer: "atom-only"})
    assert Example.get(string_only, :answer) == "str-only"
    assert Prediction.get(atom_only, :answer) == "atom-only"
    # The reverse: string key on an atom-keyed map must NOT fall back.
    assert Example.get(atom_only_example(), "answer") == nil
  end

  defp atom_only_example(), do: Example.new(%{answer: "a"})
end
