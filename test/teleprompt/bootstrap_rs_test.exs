defmodule Dspy.Teleprompt.BootstrapRSTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Parameter, Prediction, Teleprompt}
  alias Dspy.Teleprompt.BootstrapFewShotWithRandomSearch, as: BootstrapRS

  defmodule Student do
    @behaviour Dspy.Module
    defstruct [:observer, examples: []]

    @impl true
    def forward(student, %{id: id}) do
      send(student.observer, {:evaluated, id})
      {:ok, Prediction.new(answer: "ok", has_demos: student.examples != [])}
    end

    @impl true
    def parameters(student), do: [Parameter.new("predict.examples", :examples, student.examples)]

    @impl true
    def update_parameters(student, [%Parameter{name: "predict.examples", value: examples}]),
      do: %{student | examples: examples}
  end

  defmodule Teacher do
    @behaviour Dspy.Module
    defstruct [:observer, :attempts, :accept?]

    @impl true
    def forward(teacher, %{id: id}) do
      attempt =
        Agent.get_and_update(teacher.attempts, fn attempts ->
          next = Map.get(attempts, id, 0) + 1
          {next, Map.put(attempts, id, next)}
        end)

      send(teacher.observer, {:teacher, id, attempt})

      case teacher.accept?.(id, attempt) do
        {:error, _} = error -> error
        accepted? -> {:ok, Prediction.new(answer: if(accepted?, do: "ok", else: "nope"))}
      end
    end
  end

  defmodule OfflineLM do
    @behaviour Dspy.LM
    defstruct [:observer, content: ~s({"answer":"ok"})]

    @impl true
    def generate(lm, request) do
      if lm.observer do
        send(lm.observer, {:teacher_prompt, Enum.map_join(request.messages, "\n", & &1.content)})
      end

      {:ok, %{choices: [%{message: %{role: "assistant", content: lm.content}}]}}
    end
  end

  defmodule Pair do
    @behaviour Dspy.Module
    defstruct [:left, :right]

    @impl true
    def forward(pair, %{question: question}) do
      for index <- 0..3 do
        {:ok, %Prediction{}} =
          Dspy.Module.forward(pair.left, %{question: "#{question}/left/#{index}"})
      end

      task =
        Task.async(fn ->
          Dspy.Predict.forward(pair.right, %{question: "#{question}/right"})
        end)

      with {:ok, %Prediction{}} <- Task.await(task) do
        {:ok, Prediction.new(answer: "combined")}
      end
    end
  end

  defmodule PartialTeacher do
    @behaviour Dspy.Module
    defstruct [:left, :right, :observer, :fail_on]

    @impl true
    def forward(%{fail_on: question} = teacher, %{question: question}) do
      {:ok, %Prediction{}} = Dspy.Module.forward(teacher.left, %{question: question})
      send(teacher.observer, {:failed_teacher_slot, teacher.right})
      {:error, :partial_teacher_failure}
    end

    def forward(teacher, inputs), do: Pair.forward(teacher, inputs)
  end

  defmodule Branching do
    @behaviour Dspy.Module
    defstruct [:mapping, :skip_on]

    @impl true
    def forward(%{skip_on: question}, %{question: question}) do
      {:ok, Prediction.new(answer: "combined")}
    end

    def forward(program, %{question: question}) do
      tasks =
        for {key, suffix} <- [{1, "number"}, {"1", "text"}] do
          Task.async(fn ->
            Dspy.Module.forward(program.mapping[key], %{
              "question" => "#{question}/#{suffix}",
              "answer" => "shadowed by the prediction"
            })
          end)
        end

      for task <- tasks, do: {:ok, %Prediction{}} = Task.await(task)
      {:ok, Prediction.new(answer: "combined")}
    end
  end

  test "the normal optimizer entry point returns the best program" do
    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ -> 1.0 end,
        stop_at_score: 100.0,
        verbose: false
      )

    student = %Student{observer: self(), examples: rows([900])}
    assert {:ok, %Student{examples: []}} = Teleprompt.compile(optimizer, student, rows(0..1))
    assert_received {:evaluated, 0}
    assert_received {:evaluated, 1}
    refute_received {:evaluated, _}
  end

  test "zero shuffled candidates still compare all three baselines in stable tie order" do
    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ -> 1.0 end,
        num_candidate_programs: 0,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 3,
        verbose: false
      )

    student = %Student{observer: self(), examples: rows([900])}

    assert {:ok, %{program: %Student{examples: []}, candidates: candidates}} =
             BootstrapRS.compile_with_candidates(optimizer, student, rows(0..5),
               teacher: teacher(fn _, _ -> true end),
               valset: rows([100]),
               labeled_sample: false
             )

    assert Enum.map(candidates, & &1.seed) == [-3, -2, -1]
    assert Enum.map(candidates, & &1.score) == [100.0, 100.0, 100.0]
    assert Enum.map(candidates, & &1.subscores) == [[1.0], [1.0], [1.0]]
    assert demo_ids(Enum.at(candidates, 1).program) == [0, 1, 2]
    for _ <- 1..3, do: assert_received({:evaluated, 100})
    refute_received {:evaluated, _}
  end

  test "a restriction without eligible candidates fails before evaluations or teacher calls" do
    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ -> 1.0 end,
        num_candidate_programs: 0,
        verbose: false
      )

    assert {:error, _} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               %Student{observer: self()},
               rows(0..5),
               teacher: teacher(fn _, _ -> true end),
               restrict: [0, 99]
             )

    refute_received {:evaluated, _}
    refute_received {:teacher, _, _}
  end

  test "a score equal to the threshold stops before the bootstrap candidates" do
    metric = fn _, prediction -> if prediction.attrs.has_demos, do: 1.0, else: 0.0 end
    optimizer = Teleprompt.new(:bootstrap_rs, metric: metric, stop_at_score: 100, verbose: false)

    assert {:ok, %{program: %Student{examples: [_ | _]}, candidates: candidates}} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               %Student{observer: self()},
               rows(0..5),
               valset: rows([100]),
               teacher: teacher(fn _, _ -> true end)
             )

    assert Enum.map(candidates, &{&1.seed, &1.score}) == [{-2, 100.0}, {-3, 0.0}]
    for _ <- 1..2, do: assert_received({:evaluated, 100})
    refute_received {:evaluated, _}
    refute_received {:teacher, _, _}
  end

  test "ordered bootstrap retries each row and keeps a late successful trace" do
    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn example, pred -> example.attrs.answer == pred.attrs.answer end,
        num_candidate_programs: 0,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 3,
        max_rounds: 2,
        verbose: false
      )

    assert {:ok, %{program: best, candidates: [%{seed: -1}]}} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               %Student{observer: self()},
               rows(0..5),
               teacher: teacher(fn id, attempt -> id == 4 and attempt == 2 end),
               restrict: [-1],
               valset: rows([100])
             )

    # Unmodified upstream _bootstrap/_train with the same scripted teacher.
    assert demo_ids(best) == [4, 5, 3]

    attempts =
      for _ <- 1..10 do
        assert_received {:teacher, id, attempt}
        {id, attempt}
      end

    assert attempts == for(id <- 0..4, attempt <- 1..2, do: {id, attempt})
    refute_received {:teacher, _, _}
  end

  test "shuffled candidates use independent CPython shuffle and demo-limit streams" do
    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ -> 1.0 end,
        num_candidate_programs: 4,
        max_bootstrapped_demos: 4,
        max_labeled_demos: 0,
        verbose: false
      )

    assert {:ok, %{candidates: candidates}} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               %Student{observer: self()},
               rows(0..5),
               teacher: teacher(fn _, _ -> true end),
               restrict: [0, 1, 2, 3],
               valset: []
             )

    assert Enum.map(candidates, &{&1.seed, demo_ids(&1.program)}) ==
             [{0, [4, 2, 1, 0]}, {1, [2, 3]}, {2, [2]}, {3, [0, 2]}]

    evaluated =
      for _ <- 1..24 do
        assert_received {:evaluated, id}
        id
      end

    assert Enum.frequencies(evaluated) == Map.new(0..5, &{&1, 4})
  end

  test "teacher retries use a fresh rollout and the error budget spans training rows" do
    optimizer =
      Teleprompt.new(:bootstrap_few_shot_with_random_search,
        metric: fn _, _ -> 1.0 end,
        max_errors: 3,
        max_rounds: 2,
        teacher_settings: [temperature: 0.2, rollout_id: :teacher],
        verbose: false
      )

    observer = self()

    teacher =
      teacher(fn id, attempt ->
        send(
          observer,
          {:teacher_context, id, attempt, Dspy.Settings.get(:temperature),
           Dspy.Settings.get(:rollout_id)}
        )

        {:error, :teacher_failed}
      end)

    Dspy.context([temperature: 0.6, rollout_id: :caller], fn ->
      assert {:error, :teacher_failed} =
               BootstrapRS.compile_with_candidates(
                 optimizer,
                 %Student{observer: observer},
                 rows(0..5),
                 restrict: [-1],
                 teacher: teacher
               )

      assert Dspy.Settings.get(:temperature) == 0.6
      assert Dspy.Settings.get(:rollout_id) == :caller
    end)

    assert_received {:teacher_context, 0, 1, 0.2, :teacher}
    assert_received {:teacher_context, 0, 2, 1.0, 1}
    assert_received {:teacher_context, 1, 1, 0.2, :teacher}
    refute_received {:teacher_context, _, _, _, _}
    refute_received {:evaluated, _}
  end

  test "the winning Predict program retains its bound LM and can run with its demos" do
    lm = %OfflineLM{}
    student = Dspy.predict("id -> answer", lm: lm, adapter: Dspy.Signature.Adapters.JSONAdapter)
    optimizer = Teleprompt.new(:bootstrap_rs, metric: &Dspy.Metrics.exact_match/2, verbose: false)

    assert {:ok,
            %{program: %Dspy.Predict{lm: ^lm} = best, candidates: [%{seed: 2, score: 100.0}]}} =
             BootstrapRS.compile_with_candidates(optimizer, student, rows(0..5),
               teacher: teacher(fn _, _ -> true end),
               restrict: [2],
               valset: rows([100])
             )

    assert hd(demo_ids(best)) == 2
    assert {:ok, %Prediction{attrs: %{answer: "ok"}}} = Dspy.Module.forward(best, id: 200)
  end

  test "each candidate seeds an uncompiled teacher from its own ordering" do
    adapter = Dspy.Signature.Adapters.JSONAdapter
    student = Dspy.predict("question -> answer", lm: %OfflineLM{}, adapter: adapter)
    stale = question_row(900)

    teacher =
      Dspy.predict("question -> answer",
        lm: %OfflineLM{observer: self()},
        adapter: adapter,
        examples: [stale]
      )

    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: &Dspy.Metrics.exact_match/2,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 3,
        verbose: false
      )

    trainset = Enum.map(0..5, &question_row/1)
    options = [teacher: teacher, restrict: [-1, 0], valset: [question_row(100)]]

    assert {:ok, _} = BootstrapRS.compile_with_candidates(optimizer, student, trainset, options)
    assert_received {:teacher_prompt, natural}
    assert_received {:teacher_prompt, shuffled}
    refute_received {:teacher_prompt, _}

    # Random(0) draws indices [3, 5, 0]. The teacher omits the current input from demos.
    for {prompt, current, demos} <- [{natural, 0, [3, 5]}, {shuffled, 4, [0, 3]}] do
      for id <- demos, do: assert(String.contains?(prompt, question(id)))
      assert length(:binary.matches(prompt, question(current))) == 1
      refute String.contains?(prompt, question(900))
    end

    assert teacher.examples == [stale]

    assert {:ok, _} =
             BootstrapRS.compile_with_candidates(optimizer, student, trainset,
               teacher: teacher,
               teacher_compiled: true,
               restrict: [-1],
               valset: [question_row(100)]
             )

    assert_received {:teacher_prompt, compiled}
    assert String.contains?(compiled, question(900))
    refute String.contains?(compiled, question(3))
  end

  test "a missing teacher score is a rejection without a threshold" do
    metric = fn example, _ -> if example.attrs.id == 0, do: nil, else: 1.0 end

    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: metric,
        max_errors: 1,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        verbose: false
      )

    student = %Student{observer: self()}
    trainset = rows(0..5)
    opts = [teacher: teacher(fn _, _ -> true end), restrict: [-1], valset: rows([100])]

    assert {:ok, %{program: best}} =
             BootstrapRS.compile_with_candidates(optimizer, student, trainset, opts)

    assert demo_ids(best) == [1]

    assert {:error, :invalid_bootstrap_metric} =
             BootstrapRS.compile_with_candidates(
               %{optimizer | metric_threshold: 0.5},
               student,
               trainset,
               opts
             )
  end

  test "unknown compile options fail before evaluation" do
    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ -> 1.0 end,
        stop_at_score: 100,
        verbose: false
      )

    assert_raise ArgumentError, ~r/val_set/, fn ->
      BootstrapRS.compile_with_candidates(optimizer, %Student{observer: self()}, rows(0..2),
        val_set: rows([100])
      )
    end

    refute_received {:evaluated, _}
  end

  test "composite bootstrap keeps accepted traces with the slots that produced them" do
    student = predictor_pair([])
    assert student.left == student.right

    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn example, _ -> example.attrs.question != question(99) end,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 0,
        verbose: false
      )

    assert {:ok, %{program: %Pair{} = best, candidates: [%{seed: -1, score: 100.0}]}} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               student,
               Enum.map([99, 0, 1], &question_row/1),
               restrict: [-1],
               valset: [question_row(100)]
             )

    assert Enum.map(best.left.examples, & &1.attrs) == [
             %{question: "#{question(0)}/left/1", answer: "ok"},
             %{question: "#{question(1)}/left/3", answer: "ok"}
           ]

    assert Enum.map(best.right.examples, & &1.attrs) == [
             %{question: "#{question(0)}/right", answer: "ok"},
             %{question: "#{question(1)}/right", answer: "ok"}
           ]

    assert student.left.examples == []
    assert student.right.examples == []
    assert Map.keys(best.left) == Map.keys(student.left)
    assert Map.keys(best.right) == Map.keys(student.right)
    assert best.left.lm == student.left.lm
    assert best.right.lm == student.right.lm
  end

  test "composite baselines clear old demos and share one labeled sampling stream" do
    student = predictor_pair([question_row(900)])
    optimizer = Teleprompt.new(:bootstrap_rs, metric: fn _, _ -> 1 end, max_labeled_demos: 3)

    assert {:ok, %{candidates: [%{seed: -3, program: zero}, %{seed: -2, program: labeled}]}} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               student,
               Enum.map(0..7, &question_row/1),
               restrict: [-3, -2],
               valset: [question_row(100)]
             )

    assert zero.left.examples == []
    assert zero.right.examples == []
    assert labeled.left.examples == Enum.map([6, 7, 3], &question_row/1)
    assert labeled.right.examples == Enum.map([0, 2, 4], &question_row/1)
    assert student.left.examples == [question_row(900)]
    assert student.right.examples == [question_row(900)]
  end

  test "the metric sees only the current attempt's ordered steps and receives nil in evaluation" do
    student = predictor_pair([])
    owner = self()
    [rejected, accepted, validation] = Enum.map([99, 0, 100], &question_row/1)
    accept_question = accepted[:question]

    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn row, prediction, trace ->
          send(owner, {:scored, row, prediction, trace})
          is_nil(trace) or row[:question] == accept_question
        end,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        verbose: false
      )

    assert {:ok, %{program: best, candidates: [%{score: 100.0}]}} =
             BootstrapRS.compile_with_candidates(optimizer, student, [rejected, accepted],
               restrict: [-1],
               valset: [validation]
             )

    for row <- [rejected, accepted] do
      assert_received {:scored, ^row, %Prediction{attrs: %{answer: "combined"}}, trace}

      expected =
        for index <- 0..3 do
          %{path: [field: :left], inputs: %{question: "#{row[:question]}/left/#{index}"}}
        end

      assert Enum.map(trace, &Map.delete(&1, :prediction)) ==
               expected ++
                 [%{path: [field: :right], inputs: %{question: "#{row[:question]}/right"}}]

      assert Enum.all?(trace, &match?(%Prediction{attrs: %{answer: "ok"}}, &1.prediction))
    end

    assert_received {:scored, ^validation, %Prediction{}, nil}
    refute_received {:scored, _, _, _}
    assert Enum.map(best.left.examples, & &1[:question]) == ["#{accept_question}/left/1"]
    assert Enum.map(best.right.examples, & &1[:question]) == ["#{accept_question}/right"]
  end

  test "trace-aware parameter mode keeps one demo with or without a discovered predictor" do
    owner = self()
    [train, validation] = Enum.map([0, 100], &question_row/1)

    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn row, prediction, trace ->
          send(owner, {:scored, row, prediction, trace})
          true
        end,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        verbose: false
      )

    native = predictor_pair([]).left

    assert {:ok, %{program: best, candidates: [%{score: 100.0}]}} =
             BootstrapRS.compile_with_candidates(optimizer, native, [train],
               restrict: [-1],
               valset: [validation]
             )

    question = train[:question]

    assert [%Example{attrs: %{question: ^question, answer: "ok"}}] = best.examples

    assert_received {:scored, ^train, prediction,
                     [%{path: [], inputs: %{question: ^question}, prediction: step_prediction}]}

    assert prediction == step_prediction
    assert_received {:scored, ^validation, %Prediction{}, nil}

    [train, validation] = rows([0, 100])

    assert {:ok, %{program: best, candidates: [%{score: 100.0}]}} =
             BootstrapRS.compile_with_candidates(optimizer, %Student{observer: owner}, [train],
               teacher: teacher(fn _, _ -> true end),
               restrict: [-1],
               valset: [validation]
             )

    assert demo_ids(best) == [0]
    assert_received {:scored, ^train, %Prediction{}, []}
    assert_received {:scored, ^validation, %Prediction{}, nil}
    refute_received {:scored, _, _, _}
  end

  test "composite teachers sample labels per slot and omit the row being bootstrapped" do
    student = predictor_pair([])
    teacher = predictor_pair([question_row(900)], %OfflineLM{observer: self()})
    teacher = put_in(teacher.right.signature.name, "Equivalent teacher signature")

    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ -> 1 end,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 3,
        verbose: false
      )

    assert {:ok, _} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               student,
               Enum.map(0..7, &question_row/1),
               teacher: teacher,
               restrict: [-1],
               valset: [question_row(100)]
             )

    for index <- 0..3 do
      assert_received {:teacher_prompt, prompt}
      assert String.contains?(prompt, "#{question(0)}/left/#{index}")
      for id <- [6, 7, 3], do: assert(String.contains?(prompt, question(id)))
      refute String.contains?(prompt, question(900))
    end

    assert_received {:teacher_prompt, prompt}
    assert String.contains?(prompt, "#{question(0)}/right")
    assert length(:binary.matches(prompt, question(0))) == 1
    for id <- [2, 4], do: assert(String.contains?(prompt, question(id)))
    refute String.contains?(prompt, question(900))
    refute_received {:teacher_prompt, _}

    assert teacher.left.examples == [question_row(900)]
    assert teacher.right.examples == [question_row(900)]
  end

  test "a failed composite attempt drops partial traces and escaped slots can still run" do
    student = predictor_pair([])

    teacher =
      struct!(PartialTeacher,
        left: student.left,
        right: student.right,
        observer: self(),
        fail_on: question(99)
      )

    owner = self()

    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ ->
          assert trace_tables(owner) == []
          1
        end,
        max_errors: 2,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        verbose: false
      )

    assert {:ok, %{program: best}} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               student,
               Enum.map([99, 0], &question_row/1),
               teacher: teacher,
               restrict: [-1],
               valset: [question_row(100)]
             )

    assert Enum.map(best.left.examples, & &1.attrs.question) == ["#{question(0)}/left/1"]
    assert Enum.map(best.right.examples, & &1.attrs.question) == ["#{question(0)}/right"]
    assert trace_tables(owner) == []
    assert_received {:failed_teacher_slot, escaped}
    task = Task.async(fn -> Dspy.Predict.forward(escaped, %{question: "late call"}) end)
    assert {:ok, %Prediction{}} = Task.await(task)
    assert trace_tables(owner) == []
  end

  test "composite teacher slot and signature mismatches fail before scoring any candidate" do
    student = predictor_pair([], %OfflineLM{observer: self()})
    mismatched_signature = put_in(student.right.signature.instructions, "Different task")
    missing_slot = %{student | right: nil}
    cot = Dspy.chain_of_thought(student.right.signature)
    mismatched_kind = %{student | right: %{cot | signature: student.right.signature}}
    keyed = %Branching{mapping: %{1 => student.left, "1" => student.right}}
    mismatched_path = %{keyed | mapping: %{1.0 => student.left, "1" => student.right}}
    optimizer = Teleprompt.new(:bootstrap_rs, metric: fn _, _ -> 1 end, verbose: false)

    for {student, teacher} <- [
          {student, mismatched_signature},
          {student, missing_slot},
          {student, mismatched_kind},
          {keyed, mismatched_path}
        ] do
      assert {:error, :teacher_predictor_mismatch} =
               BootstrapRS.compile_with_candidates(optimizer, student, [question_row(0)],
                 teacher: teacher,
                 restrict: [-3, -1]
               )
    end

    refute_received {:teacher_prompt, _}
  end

  test "composite row limits count skipped calls and labels fill each slot in order" do
    predict = predictor_pair([]).left

    cot =
      Dspy.chain_of_thought("question -> answer",
        lm: %OfflineLM{content: ~s({"reasoning":"proof","answer":"ok"})},
        adapter: Dspy.Signature.Adapters.JSONAdapter
      )

    student = %Branching{
      mapping: %{1 => predict, "1" => cot, "unused" => predict},
      skip_on: question(0)
    }

    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ -> 1 end,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 3,
        verbose: false
      )

    assert {:ok, %{program: best}} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               student,
               Enum.map(0..5, &question_row/1),
               restrict: [-1],
               valset: [question_row(100)]
             )

    assert [number_demo | number_labels] = best.mapping[1].examples
    assert number_demo.attrs == %{"question" => "#{question(1)}/number", :answer => "ok"}
    assert number_labels == Enum.map([5, 2], &question_row/1)
    assert [text_demo | text_labels] = best.mapping["1"].examples

    assert text_demo.attrs == %{
             "question" => "#{question(1)}/text",
             :reasoning => "proof",
             :answer => "ok"
           }

    assert text_labels == Enum.map([4, 2], &question_row/1)
    assert best.mapping["unused"].examples == Enum.map([5, 2, 3], &question_row/1)
  end

  defp trace_tables(owner) do
    Enum.filter(:ets.all(), fn table ->
      :ets.info(table, :name) == :dspy_bootstrap_trace and :ets.info(table, :owner) == owner
    end)
  end

  defp predictor_pair(examples, lm \\ %OfflineLM{}) do
    predictor =
      Dspy.predict("question -> answer",
        lm: lm,
        adapter: Dspy.Signature.Adapters.JSONAdapter,
        examples: examples
      )

    %Pair{left: predictor, right: predictor}
  end

  defp rows(ids), do: Enum.map(ids, &Example.new(%{id: &1, answer: "ok"}))
  defp demo_ids(program), do: Enum.map(program.examples, & &1.attrs.id)
  defp question(id), do: "probe-question-#{id}-end"

  defp question_row(id),
    do: Example.new(question: question(id), answer: "ok") |> Example.with_inputs(:question)

  defp teacher(accept?) do
    attempts = start_supervised!({Agent, fn -> %{} end})
    %Teacher{observer: self(), attempts: attempts, accept?: accept?}
  end
end
