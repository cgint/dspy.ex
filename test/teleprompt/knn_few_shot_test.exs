defmodule Dspy.Teleprompt.KNNFewShotTest do
  use ExUnit.Case, async: true

  alias Dspy.{ChainOfThought, Embedder, Example, Predict, Prediction, Settings, Teleprompt}
  alias Dspy.Signature.Adapters.ChatAdapter
  alias Dspy.Teleprompt.KNNFewShot

  defmodule ExampleAttrs do
    defstruct [:question, :answer, :other]
  end

  defmodule RecordingLM do
    @behaviour Dspy.LM
    defstruct [:owner, :role, :content]

    @impl true
    def generate(lm, request) do
      send(lm.owner, {:generated, lm.role, Settings.get(:temperature), request})
      {:ok, lm.content}
    end
  end

  defmodule UnsupportedStudent do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_student, _inputs), do: {:ok, Prediction.new(answer: "unused")}
  end

  defmodule RecordingTeacher do
    @behaviour Dspy.Module
    defstruct [:owner]

    @impl true
    def forward(%__MODULE__{owner: owner}, inputs) do
      send(owner, {:knn_teacher_inputs, inputs})
      {:ok, Prediction.new(answer: "teacher answer")}
    end
  end

  test "the dispatcher builds one index and ChainOfThought uses only each query's demos" do
    embedder =
      embedding(%{
        "question: first neighbor" => [1, 0],
        "question: second neighbor" => [0, 1],
        "question: first query" => [1, 0],
        "question: second query" => [0, 1]
      })

    trainset = [row("first neighbor", "first gold"), row("second neighbor", "second gold")]
    initial_demo = row("stale demo", "stale answer")

    student =
      ChainOfThought.new("question -> answer",
        adapter: ChatAdapter,
        config: [max_tokens: 23],
        examples: [initial_demo],
        lm: lm(:student, "[[ ## reasoning ## ]]use the demo\n[[ ## answer ## ]]final answer")
      )

    teacher = ChainOfThought.new("question -> answer", adapter: ChatAdapter)

    optimizer =
      Teleprompt.new(:knn_few_shot,
        k: 1,
        vectorizer: embedder,
        teacher: teacher,
        metric_threshold: 2.0,
        max_labeled_demos: 0,
        num_threads: 1
      )

    assert {:ok, program} = Teleprompt.compile(optimizer, student, trainset)
    assert_received {:embedded, ["question: first neighbor", "question: second neighbor"]}
    refute_received {:generated, _, _, _}

    for {select, reject, temperature} <- [{"first", "second", 0.25}, {"second", "first", 0.75}] do
      query = "#{select} query"
      neighbor = "#{select} neighbor"
      query_embedding = "question: #{query}"

      teacher_lm =
        lm(:teacher, "[[ ## reasoning ## ]]neighbor reasoning\n[[ ## answer ## ]]teacher answer")

      Dspy.context(
        [lm: teacher_lm, temperature: temperature, cache: false],
        fn ->
          assert {:ok, %Prediction{attrs: %{answer: "final answer", reasoning: "use the demo"}}} =
                   Dspy.call(program, question: query)
        end
      )

      assert_received {:embedded, [^query_embedding]}
      assert_received {:generated, :teacher, ^temperature, teacher_request}
      teacher_prompt = user_prompt(teacher_request)
      assert teacher_prompt =~ "Inputs:\n[[ ## question ## ]]\n#{neighbor}"
      refute teacher_prompt =~ "#{select} gold"

      assert_received {:generated, :student, ^temperature, student_request}
      assert student_request.max_tokens == 23
      assert student_request.temperature == temperature
      student_prompt = user_prompt(student_request)
      assert student_prompt =~ "Example 1:\n[[ ## question ## ]]\n#{neighbor}"
      assert student_prompt =~ "[[ ## reasoning ## ]]\nneighbor reasoning"
      assert student_prompt =~ "[[ ## answer ## ]]\nteacher answer"
      assert student_prompt =~ "Inputs:\n[[ ## question ## ]]\n#{query}"
      refute student_prompt =~ "#{reject} neighbor"
      refute student_prompt =~ "stale demo"
      refute student_prompt =~ "#{select} gold"

      refute_received {:embedded, _}
      refute_received {:generated, _, _, _}
    end

    assert student.examples == [initial_demo]
  end

  test "an explicit metric sees gold and can reject the teacher before a Predict result" do
    expected = row("nearest", "  gold  ") |> Example.put(:other, nil)
    embedder = embedding(%{"question: nearest" => [1], "question: query" => [1]})
    teacher = Predict.new("question -> answer", lm: lm(:teacher, "wrong"), adapter: ChatAdapter)
    student = Predict.new("question -> answer", lm: lm(:student, "student"), adapter: ChatAdapter)
    owner = self()

    metric = fn example, prediction ->
      send(owner, {:metric, example, prediction})
      example[:answer] == prediction[:answer]
    end

    optimizer =
      KNNFewShot.new(
        k: 1,
        vectorizer: embedder,
        teacher: teacher,
        metric: metric,
        max_labeled_demos: 0
      )

    assert {:ok, program} = KNNFewShot.compile(optimizer, student, [expected])

    assert {:ok, %Prediction{attrs: %{answer: "student"}}} =
             Dspy.call(program, %{question: "query"})

    assert_received {:metric, ^expected, %Prediction{attrs: %{answer: "wrong"}}}
    assert_received {:generated, :teacher, _, _}
    assert_received {:generated, :student, _, request}
    refute user_prompt(request) =~ "Example 1:"
    refute_received {:metric, _, _}
    refute_received {:generated, _, _, _}
  end

  test "struct-backed neighbors contribute demos with their original attributes" do
    owner = self()

    neighbor =
      Example.new(%ExampleAttrs{question: "nearest", answer: "teacher answer"})
      |> Example.with_inputs(:question)

    optimizer =
      KNNFewShot.new(
        k: 1,
        vectorizer: embedding(%{"question: nearest" => [1], "question: query" => [1]}),
        teacher: %RecordingTeacher{owner: owner},
        metric: fn example, prediction, trace ->
          send(owner, {:metric, example, trace})
          example[:answer] == prediction[:answer]
        end,
        max_labeled_demos: 0
      )

    student = Predict.new("question -> answer", lm: lm(:student, "student"), adapter: ChatAdapter)
    assert {:ok, program} = KNNFewShot.compile(optimizer, student, [neighbor])
    assert {:ok, %Prediction{}} = Dspy.call(program, question: "query")
    assert_received {:metric, ^neighbor, []}
    assert_received {:generated, :student, _, request}
    assert user_prompt(request) =~ "Example 1:\n[[ ## question ## ]]\nnearest"
  end

  test "a trace-aware metric runs once per query with the exact neighbor and its teacher step" do
    owner = self()
    accepted = row("good neighbor", "teacher answer")
    rejected = row("bad neighbor", "  different answer  ") |> Example.put(:untouched, nil)

    embedder =
      embedding(%{
        "question: good neighbor" => [1, 0],
        "question: bad neighbor" => [0, 1],
        "question: first query" => [1, 0],
        "question: second query" => [0, 1]
      })

    teacher =
      Predict.new("question -> answer", lm: lm(:teacher, "teacher answer"), adapter: ChatAdapter)

    student = Predict.new("question -> answer", lm: lm(:student, "student"), adapter: ChatAdapter)

    optimizer =
      KNNFewShot.new(
        k: 1,
        vectorizer: embedder,
        teacher: teacher,
        metric: fn example, prediction, trace ->
          send(owner, {:metric, example, prediction, trace})
          Enum.any?(trace, &(&1.prediction[:answer] == example[:answer]))
        end,
        max_labeled_demos: 0
      )

    assert {:ok, program} = KNNFewShot.compile(optimizer, student, [accepted, rejected])
    refute_received {:metric, _, _, _}

    for {query, neighbor, demo?} <- [
          {"first query", accepted, true},
          {"second query", rejected, false}
        ] do
      assert {:ok, %Prediction{attrs: %{answer: "student"}}} = Dspy.call(program, question: query)
      expected_input = %{question: neighbor[:question]}
      expected_prediction = Prediction.new(answer: "teacher answer")

      assert_received {:metric, ^neighbor, ^expected_prediction,
                       [%{path: [], inputs: ^expected_input, prediction: ^expected_prediction}]}

      assert_received {:generated, :teacher, _, _}
      assert_received {:generated, :student, _, request}
      assert String.contains?(user_prompt(request), "Example 1:") == demo?
      refute_received {:generated, _, _, _}
      refute_received {:metric, _, _, _}
    end
  end

  test "the default includes up to sixteen labeled neighbors" do
    trainset = for id <- 1..18, do: row("row #{id}", "label #{id}")
    embedder = Embedder.new(fn texts -> Enum.map(texts, fn _ -> [1] end) end)
    student = Predict.new("question -> answer", lm: lm(:student, "student"), adapter: ChatAdapter)

    optimizer = KNNFewShot.new(k: 18, vectorizer: embedder, max_bootstrapped_demos: 0)

    assert {:ok, program} = KNNFewShot.compile(optimizer, student, trainset)
    assert {:ok, %Prediction{}} = Dspy.call(program, question: "query")
    assert_received {:generated, :student, _, request}
    assert length(Regex.scan(~r/^Example \d+:/m, user_prompt(request))) == 16
    refute_received {:generated, _, _, _}
  end

  test "a labeled demo cap uses the closest rows and preserves typed outputs" do
    trainset = for distance <- 1..3, do: row("row #{distance}", %{value: distance})

    embedder =
      embedding(%{
        "question: row 1" => [3],
        "question: row 2" => [2],
        "question: row 3" => [1],
        "question: query" => [1]
      })

    student = Predict.new("question -> answer", lm: lm(:student, "student"), adapter: ChatAdapter)

    optimizer =
      KNNFewShot.new(k: 3, vectorizer: embedder, max_labeled_demos: 2, max_bootstrapped_demos: 0)

    assert {:ok, program} = KNNFewShot.compile(optimizer, student, trainset)
    assert {:ok, %Prediction{}} = Dspy.call(program, question: "query")
    assert_received {:generated, :student, _, request}
    prompt = user_prompt(request)
    assert prompt =~ "Example 1:\n[[ ## question ## ]]\nrow 1"
    assert prompt =~ "Example 2:\n[[ ## question ## ]]\nrow 2"
    assert prompt =~ "[[ ## answer ## ]]\n%{value: 1}"
    assert prompt =~ "[[ ## answer ## ]]\n%{value: 2}"
    refute prompt =~ "row 3"
  end

  test "an explicit empty neighbor projection sends an empty map to the teacher" do
    embedder = embedding(%{"" => [1], "answer: private query label" => [1]})
    row = Example.new(answer: "gold label") |> Example.with_inputs([])

    signature =
      Dspy.Signature.new("No inputs",
        output_fields: [
          %{name: :answer, type: :string, required: true, description: "", default: nil}
        ]
      )

    student = Predict.new(signature, lm: lm(:student, "student"), adapter: ChatAdapter)

    optimizer =
      KNNFewShot.new(
        k: 1,
        vectorizer: embedder,
        teacher: %RecordingTeacher{owner: self()},
        max_labeled_demos: 0
      )

    assert {:ok, program} = KNNFewShot.compile(optimizer, student, [row])
    assert_received {:embedded, [""]}
    assert {:ok, %Prediction{attrs: %{answer: "student"}}} = Dspy.call(program, %{})
    assert_received {:embedded, [""]}
    assert_received {:knn_teacher_inputs, inputs}
    assert inputs == %{}

    query = Example.new(answer: "private query label")
    assert Dspy.call(program, query) == {:error, :missing_input_keys}
    refute_received {:embedded, _}

    assert {:ok, %Prediction{}} = Dspy.call(program, Example.with_inputs(query, []))
    assert_received {:embedded, [""]}
    refute_received {:embedded, _}
  end

  test "default bootstrap sampling follows nearest-first order with the student as teacher" do
    trainset = [row("far", "label"), row("nearest", "label"), row("second nearest", "label")]

    embedder =
      embedding(%{
        "question: far" => [1],
        "question: nearest" => [3],
        "question: second nearest" => [2],
        "question: query" => [1]
      })

    student =
      Predict.new("question -> answer",
        lm: lm(:student, "student"),
        adapter: ChatAdapter,
        examples: [row("stale demo", "label")]
      )

    optimizer =
      KNNFewShot.new(
        k: 3,
        vectorizer: embedder,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        num_threads: 1
      )

    assert {:ok, program} = KNNFewShot.compile(optimizer, student, trainset)
    assert {:ok, %Prediction{}} = Dspy.call(program, question: "query")

    for question <- ["nearest", "second nearest"] do
      assert_receive {:generated, :student, _, request}
      assert user_prompt(request) == "Inputs:\n[[ ## question ## ]]\n#{question}"
    end

    assert_received {:generated, :student, _, request}
    assert user_prompt(request) =~ "Example 1:\n[[ ## question ## ]]\nnearest"
    refute user_prompt(request) =~ "second nearest"
    refute_received {:generated, _, _, _}
  end

  test "student preflight precedes training embeddings and query failures stop before the LM" do
    error = {:error, {:embedding_unavailable, make_ref()}}
    owner = self()

    embedder =
      Embedder.new(fn texts ->
        send(owner, {:embedded, texts})

        case texts do
          ["question: query"] -> error
          ["question: nearest"] -> [[1]]
        end
      end)

    trainset = [row("nearest", "gold")]
    optimizer = KNNFewShot.new(k: 1, vectorizer: embedder, metric: nil)

    assert KNNFewShot.compile(optimizer, %UnsupportedStudent{}, trainset) ==
             {:error, {:unsupported_program, UnsupportedStudent}}

    refute_received {:embedded, _}

    student = Predict.new("question -> answer", lm: lm(:student, "unused"), adapter: ChatAdapter)
    assert {:ok, program} = KNNFewShot.compile(optimizer, student, trainset)
    assert_received {:embedded, ["question: nearest"]}
    assert Dspy.call(program, question: "query") == error
    assert_received {:embedded, ["question: query"]}
    refute_received {:embedded, _}
    refute_received {:generated, _, _, _}
  end

  test "invalid metrics and candidate-search options are rejected at construction" do
    opts = [k: 1, vectorizer: embedding(%{})]

    assert_raise ArgumentError, ~r/Metric must be a function/, fn ->
      KNNFewShot.new(Keyword.put(opts, :metric, false))
    end

    assert_raise ArgumentError, ~r/num_candidate_programs/, fn ->
      KNNFewShot.new(Keyword.put(opts, :num_candidate_programs, 4))
    end

    refute_received {:embedded, _}
  end

  defp lm(role, text) do
    content = if String.starts_with?(text, "[["), do: text, else: "[[ ## answer ## ]]" <> text
    %RecordingLM{owner: self(), role: role, content: content}
  end

  defp row(question, answer) do
    Example.new(%{question: question, answer: answer}, %{from_dataset: true})
    |> Example.with_inputs(:question)
  end

  defp embedding(vectors) do
    owner = self()

    Embedder.new(fn texts ->
      send(owner, {:embedded, texts})
      Enum.map(texts, &Map.fetch!(vectors, &1))
    end)
  end

  defp user_prompt(request), do: List.last(request.messages).content
end
