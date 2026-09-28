defmodule DspyContextS6PropagationTest do
  @moduledoc """
  S6 — per-site marker-LM propagation tests for the six teleprompt spawn sites that
  had no dedicated marker test (h0-process-context, spec R2 "Per-site propagation
  test (programs)").

  Six target sites, four public entry points:
    - simba.ex:171 (step_program candidate scoring)  → Dspy.Teleprompt.SIMBA.compile/3
    - mipro_v2.ex:301 (bootstrap forward)             → Dspy.Teleprompt.MIPROv2.compile/3
    - bootstrap_few_shot.ex:276 (bootstrap forward)   → Dspy.Teleprompt.BootstrapFewShot.compile/3
    - bootstrap_few_shot.ex:430 (nested-Evaluate)      (same entry as :276)
    - ensemble.ex:349 (train members)                  → Dspy.Teleprompt.Ensemble.compile/3
    - ensemble.ex:473 (performance-weights nested-Eval) (same entry as :349)

  Each test drives the PUBLIC compile entry inside Dspy.context([lm: marker], ...)
  and asserts a CONCRETE, NON-VACUOUS value that holds only when the site's
  Dspy.Context.with_context wrap propagated the marker into the spawned work.
  Every assertion was verified mutation-proof: replacing the site's with_context
  with the bare call makes the named test fail (per-site mutation log in
  plan/research/pi_handoffs/h0/benjamin-report.md, S6 section).

  Marker designs (both instruction-aware so MIPROv2's instruction-generation
  prompt gets a valid candidate, avoiding :no_instruction_candidates):
    - "ok-marker" (global answers "nope"): for bootstrap/member-training sites,
      where the spawned work's LM answer is stored in the optimized examples.
      Gold "ok" → the marker answer matches, the global's does not.
    - "nope-marker" (inverted; gold "nope"): for SIMBA, where the marker's 0.0
      score is what keeps the ORIGINAL program (no "Instruction hint" appended);
      the global's 1.0 score makes SIMBA select a candidate that HAS the hint.
  """
  use ExUnit.Case, async: false

  alias DspyContextS6PropagationTest.{GlobalLM, MarkerLM, TestQA}

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # Global LM: always answers "nope". Under the ok-marker (gold "ok") it scores
  # 0.0; under the inverted-marker (gold "nope") it scores 1.0.
  defmodule GlobalLM do
    @moduledoc false
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: nope"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  # Marker LM: answers "ok" for forward/evaluate/bootstrap calls, and returns a
  # VALID instruction (>15 chars, no TODO/FIXME/XXX) for instruction-generation
  # prompts (MIPROv2 needs this to avoid :no_instruction_candidates).
  #
  # The marker records (a) the calling process PID and (b) the raw prompt text
  # into persistent_term, keyed by :track_key. The caller (test) process installs
  # the marker via Dspy.context([lm: marker]); the spawned task processes have
  # DIFFERENT PIDs and their prompts carry the questions being evaluated. This
  # lets each test assert a concrete, per-site signal:
  #   - non-caller PID count (MIPROv2 bootstrap forward)
  #   - "saw a validation question" (Ensemble performance-weights nested-Evaluate)
  #   - "saw a few-shot Example section" (BootstrapFewShot candidate evaluates)
  defmodule MarkerLM do
    @moduledoc false
    @behaviour Dspy.LM
    defstruct [:track_key]

    def new(track_key \\ :default), do: %__MODULE__{track_key: track_key}

    @impl true
    def generate(%__MODULE__{track_key: track_key} = _lm, request) do
      key = {:marker_s6, track_key}
      # Record PID + prompt (read-modify-write; races are harmless, we dedupe on
      # read). persistent_term is node-wide, so all task processes write the same
      # keys the test reads.
      prev_pids = :persistent_term.get({:pids, key}, [])
      :persistent_term.put({:pids, key}, [self() | prev_pids])

      prompt = prompt_text(request)

      prev_prompts = :persistent_term.get({:prompts, key}, [])
      :persistent_term.put({:prompts, key}, [prompt | prev_prompts])

      content =
        if String.contains?(prompt, "Generate an effective instruction") do
          "Answer the question accurately using the provided context and examples."
        else
          "Answer: ok"
        end

      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: content}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    defp prompt_text(request) do
      prompt = request.messages |> List.first() |> Map.fetch!(:content)

      case prompt do
        parts when is_list(parts) ->
          parts
          |> Enum.map(fn
            %{"text" => t} -> t
            _ -> ""
          end)
          |> Enum.join(" || ")

        text when is_binary(text) ->
          text
      end
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  # Helpers to read the marker's recorded state.
  defp marker_pids(track_key) do
    :persistent_term.get({:pids, {:marker_s6, track_key}}, []) |> Enum.uniq()
  end

  defp marker_prompts(track_key) do
    :persistent_term.get({:prompts, {:marker_s6, track_key}}, [])
  end

  defmodule TestQA do
    use Dspy.Signature
    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %GlobalLM{})
    :ok
  end

  # ---------------------------------------------------------------------------
  # SIMBA.compile/3 → simba.ex:171 (step_program candidate scoring)
  #
  # Inverted marker (gold "nope"): the caller-side `current_score` evaluate
  # (wired via evaluate.ex) uses the marker → scores 0.0. The step_program
  # candidate scoring (simba.ex:171) scores 0.0 only if the marker reaches the
  # spawned candidate tasks. best_score (0.0) is NOT > current_score (0.0), so
  # SIMBA keeps the ORIGINAL program (no "Instruction hint" appended). If the
  # :171 wrap were removed, the candidate tasks would use the global (1.0 > 0.0)
  # and SIMBA would select a candidate whose instructions HAVE the hint.
  # ---------------------------------------------------------------------------

  test "SIMBA.compile/3: marker keeps the original program (simba.ex:171 candidate scoring)" do
    track_key = :simba_s6

    student = Dspy.Predict.new(TestQA)

    # Gold "nope": the global answers "nope" (matches), the marker answers "ok"
    # (fails). This inverts the usual setup so the marker's 0.0 score is what
    # keeps the original program.
    trainset =
      for i <- 1..5 do
        Dspy.Example.new(%{question: "q#{i}", answer: "nope"})
      end

    metric = &Dspy.Metrics.exact_match/2
    marker = MarkerLM.new(track_key)

    tp =
      Dspy.Teleprompt.SIMBA.new(
        metric: metric,
        seed: 123,
        max_steps: 1,
        num_candidates: 3,
        bsize: 5,
        num_threads: 1,
        candidate_strategies: [:modify_instructions],
        verbose: false
      )

    Dspy.context([lm: marker], fn ->
      assert {:ok, optimized} = Dspy.Teleprompt.SIMBA.compile(tp, student, trainset)

      # The optimized program's instructions must be UNCHANGED (no "Instruction
      # hint" appended). This holds only if the :171 wrap carried the marker into
      # the candidate-scoring tasks (scores 0.0, tying the caller-side 0.0) so
      # SIMBA keeps the original. If the wrap were removed, the candidates would
      # score 1.0 (global) and SIMBA would select one that HAS the hint appended.
      instructions = optimized.signature.instructions || ""

      refute String.contains?(instructions, "Instruction hint"),
             "simba.ex:171 candidate scoring did not carry the marker into the spawned " <>
               "tasks (a modified candidate was selected; instructions: " <>
               "#{inspect(String.slice(instructions, 0, 80))})"
    end)
  end

  # ---------------------------------------------------------------------------
  # MIPROv2.compile/3 → mipro_v2.ex:301 (bootstrap forward in spawned tasks)
  #
  # Inverted marker (gold "nope"): the bootstrap forward at :301 runs in spawned
  # tasks. If the :301 wrap carried the marker, those tasks call the marker. The
  # caller-side / baseline evaluates do NOT reach the :301 task PIDs. So the
  # count of DISTINCT non-caller PIDs that called the marker is higher with the
  # :301 wrap (≈6) than without (≈3). Threshold >= 4 separates them.
  # ---------------------------------------------------------------------------

  test "MIPROv2.compile/3: marker ran in the bootstrap-forward tasks (mipro_v2.ex:301)" do
    track_key = :mipro_s6

    student = Dspy.Predict.new("question -> answer")

    trainset =
      for i <- 1..5 do
        Dspy.Example.new(%{question: "q#{i}", answer: "nope"})
      end

    metric = &Dspy.Metrics.exact_match/2
    marker = MarkerLM.new(track_key)

    tp =
      Dspy.Teleprompt.MIPROv2.new(
        metric: metric,
        auto: "light",
        num_trials: 3,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 2,
        minibatch_size: 5,
        max_instruction_candidates: 2,
        instruction_generation_rounds: 1,
        num_threads: 1,
        seed: 123,
        prompt_model: marker,
        verbose: false
      )

    Dspy.context([lm: marker], fn ->
      assert {:ok, _optimized} = Dspy.Teleprompt.MIPROv2.compile(tp, student, trainset)
    end)

    pids = marker_pids(track_key)
    non_caller_pids = pids |> Enum.reject(&(&1 == self()))

    assert length(non_caller_pids) >= 4,
           "mipro_v2.ex:301 bootstrap forward did not carry the marker into the spawned " <>
             "forward tasks (non-caller marker PIDs: #{inspect(length(non_caller_pids))}, " <>
             "caller: #{inspect(self())})"
  end

  # ---------------------------------------------------------------------------
  # BootstrapFewShot.compile/3 → bootstrap_few_shot.ex:276 (bootstrap forward)
  # AND bootstrap_few_shot.ex:430 (nested-Evaluate select_best_program)
  #
  # ONE compile exercises BOTH wraps. ok-marker (gold "ok"), LM-based teacher:
  #   - :276 bootstrap forward: the bootstrapped examples carry the LM answer.
  #     With the :276 wrap the marker answers "ok" (kept, score 1.0); without it
  #     the global answers "nope" (dropped, score 0.0). So the optimized
  #     examples carry "ok" ONLY if :276 carried the marker.
  #   - :430 nested-Evaluate: the candidate evaluates include each candidate's
  #     few-shot examples, so the marker's prompts for those calls contain the
  #     "Example" section. The :276 teacher forwards have NO examples, so a
  #     prompt containing "Example" can only come from the :430 candidate
  #     evaluates.
  # ---------------------------------------------------------------------------

  test "BootstrapFewShot.compile/3: marker carried in bootstrap forward (line 276) AND nested-Evaluate (line 430)" do
    track_key = :bootstrap_s6

    student = Dspy.Predict.new(TestQA)

    trainset =
      for i <- 1..4 do
        Dspy.Example.new(%{question: "q#{i}", answer: "ok"})
      end

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    marker = MarkerLM.new(track_key)

    # LM-based teacher: its forward uses the installed LM, so the bootstrapped
    # examples carry the marker's answer ("ok") when the :276 wrap propagated the
    # marker into the bootstrap tasks, and the global's answer ("nope") when it
    # did not. (A deterministic module teacher would make the examples vacuous.)
    teacher = Dspy.Predict.new("question -> answer")

    teleprompt =
      Dspy.Teleprompt.BootstrapFewShot.new(
        metric: metric,
        teacher: teacher,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 0,
        max_rounds: 1,
        num_candidate_programs: 4,
        num_threads: 1,
        seed: 123
      )

    Dspy.context([lm: marker], fn ->
      # :276 — bootstrap forward: the optimized examples must carry the marker
      # answer "ok" (not the global "nope"). This is a CONCRETE value only the
      # marker produces inside the spawned bootstrap tasks.
      assert {:ok, optimized} =
               Dspy.Teleprompt.BootstrapFewShot.compile(teleprompt, student, trainset)

      example_answers =
        optimized.examples
        |> Enum.map(fn ex -> ex.attrs[:answer] end)

      assert example_answers != [],
             "BootstrapFewShot produced no examples (line 276 bootstrap forward)"

      assert Enum.all?(example_answers, fn ans -> ans == "ok" end),
             "bootstrap_few_shot.ex line 276 bootstrap forward did not carry the marker " <>
               "into the bootstrap tasks (example answers: #{inspect(example_answers)})"

      # :430 — nested-Evaluate: the candidate evaluates include the candidates'
      # few-shot examples, so the marker's prompts for those calls contain the
      # "Example" section marker. The :276 teacher forwards have NO examples, so
      # a prompt containing "Example" can only come from the :430 candidate
      # evaluates. Assert the marker saw such a prompt.
      prompts = marker_prompts(track_key)
      saw_example_section = Enum.any?(prompts, fn p -> String.contains?(p, "Example 1:") end)

      assert saw_example_section,
             "bootstrap_few_shot.ex line 430 nested-Evaluate did not carry the marker into " <>
               "the candidate-evaluate tasks (no candidate prompt with a few-shot Example " <>
               "section was seen by the marker)"
    end)
  end

  # ---------------------------------------------------------------------------
  # Ensemble.compile/3 → ensemble.ex:349 (train members) AND ensemble.ex:473
  # (nested-Evaluate calculate_performance_weights)
  #
  # ONE compile exercises BOTH wraps. ok-marker (gold "ok"), LM-based teacher,
  # :weighted_average (so the :473 performance-weights nested-Evaluate runs),
  # validation_split: 0.5 (so there IS validation data for :473):
  #   - :349 train members: the members are trained via bootstrap_few_shot with an
  #     LM teacher. With the :349 wrap the members' bootstrapped examples carry
  #     "ok"; without it they carry "nope".
  #   - :473 nested-Evaluate: the performance-weights evaluate asks each member
  #     the VALIDATION questions. With the :473 wrap the marker sees those val
  #     questions (SAW_VAL=true); without it the global answers them and the
  #     marker never sees a val question (SAW_VAL=false). The train/val question
  #     sets are disjoint (seeded split), and the member examples are train
  #     questions, so a val question in a marker prompt can ONLY come from the
  #     :473 validation evaluate.
  # ---------------------------------------------------------------------------

  test "Ensemble.compile/3: marker carried in train members (line 349) AND performance-weights nested-Evaluate (line 473)" do
    track_key = :ensemble_s6

    student = Dspy.Predict.new(TestQA)

    # The split (seed 123, validation_split 0.5) puts these in training and these
    # in validation (verified via Dspy.Trainset.split). They are disjoint and
    # non-colliding (no word is a substring of another).
    words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    trainset = for w <- words, do: Dspy.Example.new(%{question: w, answer: "ok"})

    train_qs = ["four", "seven", "one", "nine", "two"]
    val_qs = ["three", "five", "six", "eight", "ten"]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    marker = MarkerLM.new(track_key)
    teacher = Dspy.Predict.new("question -> answer")

    tp =
      Dspy.Teleprompt.Ensemble.new(
        size: 2,
        combination_strategy: :weighted_average,
        base_teleprompt: :bootstrap_few_shot,
        base_teleprompt_config: [
          max_bootstrapped_demos: 2,
          max_labeled_demos: 0,
          max_rounds: 1,
          num_candidate_programs: 4,
          num_threads: 1,
          seed: 123,
          metric: metric,
          teacher: teacher
        ],
        diversity_strategy: :different_configs,
        validation_split: 0.5,
        num_threads: 1,
        seed: 123,
        verbose: false
      )

    Dspy.context([lm: marker], fn ->
      assert {:ok, ensemble_program} = Dspy.Teleprompt.Ensemble.compile(tp, student, trainset)
      assert is_struct(ensemble_program, Dspy.Teleprompt.Ensemble.Program)

      # :349 — train members: the members' bootstrapped examples must carry the
      # marker answer "ok" (not the global "nope").
      member_answers =
        ensemble_program.members
        |> Enum.map(fn m -> (m.examples || []) |> Enum.map(fn ex -> ex.attrs[:answer] end) end)

      all_member_answers = member_answers |> List.flatten()

      assert all_member_answers != [],
             "Ensemble members produced no examples (line 349 train members)"

      assert Enum.all?(all_member_answers, fn ans -> ans == "ok" end),
             "ensemble.ex line 349 train members did not carry the marker into the " <>
               "member-training tasks (member example answers: #{inspect(all_member_answers)})"

      # :473 — performance-weights nested-Evaluate: the marker must have seen a
      # VALIDATION question. A val question can only reach the marker via the
      # :473 validation evaluate (train questions appear in the :349 training and
      # as member examples, but val questions are disjoint and only evaluated at
      # :473).
      prompts = marker_prompts(track_key)

      saw_val_question =
        Enum.any?(prompts, fn p ->
          Enum.any?(val_qs, fn q -> String.contains?(p, q) end)
        end)

      assert saw_val_question,
             "ensemble.ex line 473 performance-weights nested-Evaluate did not carry the " <>
               "marker into the validation-evaluate tasks (no validation question was seen " <>
               "by the marker)"

      # Also assert the marker saw a TRAIN question (proves the :349 training ran
      # the marker in spawned work, complementing the member-examples check).
      saw_train_question =
        Enum.any?(prompts, fn p ->
          Enum.any?(train_qs, fn q -> String.contains?(p, q) end)
        end)

      assert saw_train_question,
             "ensemble.ex line 349 train members did not run the marker in a spawned task " <>
               "(no training question was seen by the marker)"
    end)
  end
end
