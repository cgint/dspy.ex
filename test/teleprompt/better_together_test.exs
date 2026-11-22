defmodule Dspy.Teleprompt.BetterTogetherTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Module, Predict, Prediction, Teleprompt}
  alias Dspy.Signature.Adapters.ChatAdapter
  alias Dspy.Teleprompt.{BetterTogether, BootstrapFinetune, GEPA}
  alias Dspy.Teleprompt.BootstrapFewShotWithRandomSearch, as: BootstrapRS

  defmodule TrainingLM do
    @behaviour Dspy.LM
    defstruct [:owner, :identity, trained: false]

    @impl true
    def generate(lm, request) do
      prompt = Enum.map_join(request.messages, "\n", & &1.content)

      answer =
        cond do
          lm.trained -> "trained"
          prompt =~ "Use induced rules." and prompt =~ "held out" -> "regressed"
          prompt =~ "Use induced rules." -> "teacher evidence"
          true -> "baseline"
        end

      {:ok, "[[ ## answer ## ]]\n#{answer}"}
    end

    @impl true
    def finetune(lm, rows, _opts) do
      send(lm.owner, {:finetune_rows, rows})
      {:ok, %{lm | trained: true}}
    end
  end

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:slots, :version]

    @impl true
    def forward(program, _inputs), do: {:ok, Prediction.new(version: program.version)}
  end

  defmodule Stage do
    defstruct [:owner, :name, :apply]

    def compile(stage, student, trainset, opts) do
      send(stage.owner, {:stage, stage.name, student, Enum.map(trainset, & &1[:question]), opts})
      stage.apply.(student)
    end
  end

  test "passes a regressed prompt to real fine-tuning and selects the trained candidate" do
    student = Predict.new("question -> answer", lm: lm(), adapter: ChatAdapter)

    prompt =
      GEPA.new(
        candidates: ["Use induced rules."],
        metric: fn _, prediction -> prediction[:answer] == "teacher evidence" end
      )

    optimizer =
      Teleprompt.new(:better_together,
        metric: fn _, prediction ->
          %{"baseline" => 0.5, "regressed" => 0, "trained" => 1}[prediction[:answer]]
        end,
        optimizers: %{p: prompt, w: BootstrapFinetune.new(num_threads: 1)}
      )

    assert {:ok, %{program: best, candidates: candidates, error: nil}} =
             BetterTogether.compile_with_candidates(optimizer, student, [row("training")],
               valset: [row("held out")],
               strategy: "p -> w",
               num_threads: 1
             )

    assert Enum.map(candidates, &{&1.strategy, &1.score}) ==
             [{"p -> w", 100.0}, {"", 50.0}, {"p", 0.0}]

    assert best.lm.trained
    refute student.lm.trained
    assert {:ok, prediction} = Module.forward(best, %{question: "held out"})
    assert prediction[:answer] == "trained"

    assert_received {:finetune_rows, [%{messages: messages}]}
    assert hd(messages).content =~ "Use induced rules."
    assert List.last(messages).content =~ "teacher evidence"
    refute inspect(messages) =~ "held out"
  end

  test "restores only cleared exact slot bindings and returns the earlier tied candidate on failure" do
    program = put_in(program().slots["1"].lm.identity, :right)
    left = program.slots[1].lm
    replacement = %{left | trained: true}
    added = %{program.slots[1] | lm: %{left | identity: :added}}

    p =
      stage(:p, fn student ->
        slots = student.slots |> Map.update!(1, &%{&1 | lm: nil})
        slots = Map.update!(slots, "1", &%{&1 | lm: replacement})
        slots = Map.put(slots, 0, added)
        {:ok, %{student | slots: slots, version: :tied}}
      end)

    w = stage(:w, fn _ -> {:error, :stopped} end)

    optimizer = BetterTogether.new(metric: fn _, _ -> 1 end, optimizers: %{p: p, w: w})

    assert {:ok, %{program: ^program, candidates: candidates, error: error}} =
             BetterTogether.compile_with_candidates(optimizer, program, [row("train")],
               valset: [row("validation")]
             )

    assert Enum.map(candidates, & &1.strategy) == ["", "p"]
    assert error == %{stage: "w", index: 1, reason: :stopped}
    assert_received {:stage, :p, ^program, ["train"], []}
    assert_received {:stage, :w, restored, ["train"], []}
    assert restored.slots[0] === added
    assert restored.slots[1].lm === left
    assert restored.slots["1"].lm === replacement
    refute_received {:stage, _, _, _, _}
  end

  test "keeps the held-out prefix separate and threads deterministic shuffles through stage overrides" do
    owner = self()

    metric = fn example, _ ->
      send(owner, {:evaluated, example[:question]})
      0
    end

    optimizer =
      BetterTogether.new(
        metric: metric,
        optimizers: %{p: stage(:p), w: stage(:w), end: stage(:end)}
      )

    assert {:ok, %{error: nil}} =
             BetterTogether.compile_with_candidates(
               optimizer,
               program(),
               Enum.map(["held", "a", "b", "c", "d"], &row/1),
               strategy: "p -> w -> end",
               valset_ratio: 0.2,
               seed: 0,
               optimizer_compile_args: %{w: [trainset: [row("override")], custom: 1]}
             )

    assert_received {:stage, :p, _, ["c", "a", "b", "d"], []}
    assert_received {:stage, :w, _, ["override"], [custom: 1]}
    assert_received {:stage, :end, _, ["c", "d", "a", "b"], []}
    for _ <- 1..4, do: assert_received({:evaluated, "held"})
    refute_received {:evaluated, _}
  end

  test "no validation returns the latest stage and the factory compile dispatch works" do
    optimizer =
      Teleprompt.new(:better_together,
        metric: fn _, _ -> flunk("the rounded-zero split must skip evaluation") end,
        optimizers: %{
          p: stage(:p, fn student -> {:ok, %{student | version: :prompted}} end),
          w: stage(:w, fn student -> {:ok, %{student | version: :trained}} end)
        }
      )

    assert {:ok, %Program{version: :prompted}} =
             Teleprompt.compile(optimizer, program(), [row("train")])

    assert_receive {:stage, :p, %Program{version: :baseline}, ["train"], []}
    assert_receive {:stage, :w, %Program{version: :prompted}, ["train"], []}
    assert_receive {:stage, :p, %Program{version: :trained}, ["train"], []}
    refute_received {:stage, _, _, _, _}
  end

  test "validates every step, compile argument and initial binding before evaluation" do
    optimizer =
      BetterTogether.new(
        metric: fn _, _ -> flunk("invalid configuration must not reach evaluation") end,
        optimizers: %{p: stage(:p)}
      )

    for opts <- [
          [strategy: "p -> unknown"],
          [strategy: "p", optimizer_compile_args: %{p: [student: :other]}],
          [strategy: "p", optimizer_compile_args: %{p: [trainset: [nil]]}],
          [strategy: "p", optimizer_compile_args: %{unknown: []}],
          [strategy: "p", teacher: ~D[2026-11-22]],
          [strategy: "p", num_threads: false]
        ] do
      assert_raise ArgumentError, fn ->
        BetterTogether.compile(
          optimizer,
          program(),
          [row("train")],
          Keyword.put(opts, :valset, [row("validation")])
        )
      end
    end

    unbound = put_in(program().slots["1"].lm, nil)

    assert {:error, {:missing_lm, [{:field, :slots}, {:key, "1"}]}} =
             BetterTogether.compile(optimizer, unbound, [row("train")], strategy: "p")

    refute_received {:stage, _, _, _, _}
  end

  test "a per-stage teacher override preserves the shared list for multi-teacher training" do
    metric = fn _, _ -> 1 end
    student = Predict.new("question -> answer", lm: lm(), adapter: ChatAdapter)

    optimizer =
      BetterTogether.new(
        metric: metric,
        optimizers: %{
          p: BootstrapRS.new(metric: metric),
          w: BootstrapFinetune.new(num_threads: 1)
        }
      )

    opts = [teacher: [student, student], strategy: "p -> w", valset_ratio: 0]

    assert_raise ArgumentError, ~r/single program/, fn ->
      BetterTogether.compile(optimizer, student, [row("training")], opts)
    end

    assert {:ok, %{program: trained, error: nil}} =
             BetterTogether.compile_with_candidates(
               optimizer,
               student,
               [row("training")],
               Keyword.put(opts, :optimizer_compile_args, %{p: [teacher: student, restrict: [-3]]})
             )

    assert trained.lm.trained
    assert_received {:finetune_rows, [_first, _second]}
    refute_received {:finetune_rows, _}
  end

  defp lm, do: %TrainingLM{owner: self()}

  defp program do
    predictor = Predict.new("question -> answer", lm: lm(), adapter: ChatAdapter)
    %Program{slots: %{1 => predictor, "1" => predictor}, version: :baseline}
  end

  defp row(question), do: Example.new(question: question) |> Example.with_inputs(:question)

  defp stage(name, fun \\ &{:ok, &1}), do: %Stage{owner: self(), name: name, apply: fun}
end
