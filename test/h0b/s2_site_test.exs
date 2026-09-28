# ---------------------------------------------------------------------------
# Test doubles (defined at top level BEFORE the case so structs are available)
# ---------------------------------------------------------------------------

defmodule H0bS2.ConstantModule do
  @behaviour Dspy.Module
  defstruct [:answer]

  @impl true
  def forward(%__MODULE__{answer: answer}, _inputs) do
    {:ok, Dspy.Prediction.new(%{answer: answer})}
  end
end

defmodule H0bS2.RaisingModule do
  @behaviour Dspy.Module
  defstruct [:tag]

  @impl true
  def forward(_module, _inputs) do
    raise "H0b S2 member raise"
  end
end

defmodule H0bS2.ThrowingModule do
  @behaviour Dspy.Module
  defstruct []

  @impl true
  def forward(_module, _inputs) do
    throw(:h0b_s2_throw_marker)
  end
end

defmodule H0bS2.ExitingModule do
  @behaviour Dspy.Module
  defstruct []

  @impl true
  def forward(_module, _inputs) do
    exit(:h0b_s2_exit_marker)
  end
end

# A mock LM that always returns a valid "Answer: 4" response.
defmodule H0bS2.WorkingLM do
  @behaviour Dspy.LM
  defstruct []

  @impl true
  def generate(_lm, request) do
    prompt = request.messages |> List.first() |> Map.fetch!(:content)

    matches = Regex.scan(~r/Question:\s*(.*?)\nAnswer:/s, prompt, capture: :all_but_first)

    question =
      case List.last(matches) do
        [q] -> String.trim(q)
        _ -> "4"
      end

    {:ok,
     %{
       choices: [
         %{message: %{role: "assistant", content: "Answer: #{question}"}, finish_reason: "stop"}
       ],
       usage: nil
     }}
  end

  @impl true
  def supports?(_lm, _feature), do: true
end

# A mock LM that always raises — used to force all candidate evaluations to fail.
defmodule H0bS2.RaisingLM do
  @behaviour Dspy.LM
  defstruct []

  @impl true
  def generate(_lm, _request) do
    raise "H0b S2: LM always raises"
  end

  @impl true
  def supports?(_lm, _feature), do: true
end

# A working teacher module for bootstrap compile tests.
defmodule H0bS2.WorkingTeacher do
  @behaviour Dspy.Module
  defstruct []

  @impl true
  def forward(_teacher, _inputs) do
    {:ok, Dspy.Prediction.new(%{answer: "4"})}
  end
end

# A scripted LM for the mipro_v2.ex:299 test.
#
# It answers the instruction-generation prompts (so MIPROv2's
# generate_instruction_candidates/3 succeeds) but RAISES for every other
# (bootstrap QA) prompt. Because the mipro bootstrap_few_shot_examples task body
# (mipro_v2.ex:299) calls Dspy.Module.forward/2 directly — not wrapped in
# Evaluate.evaluate or a rescuing helper — a raising LM propagates the raise
# into the child catch-all at site 299.
defmodule H0bS2.MiproScriptedLM do
  @behaviour Dspy.LM
  defstruct []

  @impl true
  def generate(_lm, request) do
    prompt = request.messages |> List.first() |> Map.fetch!(:content)

    prompt_text =
      case prompt do
        parts when is_list(parts) ->
          parts
          |> Enum.map(fn
            %{"type" => "text", "text" => t} -> t
            _ -> ""
          end)
          |> Enum.join("")

        text when is_binary(text) ->
          text
      end

    if String.contains?(prompt_text, "Generate an effective instruction") do
      # Valid instruction (15-300 chars, no TODO/FIXME/XXX) so that
      # generate_instruction_candidates/3 returns {:ok, […]}.
      {:ok,
       %{
         choices: [
           %{
             message: %{
               role: "assistant",
               content: "Answer the question accurately and concisely."
             },
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    else
      # Bootstrap QA prompt: raise so that Dspy.Module.forward/2 at site 299
      # raises and the child catch-all is exercised.
      raise "H0b S2: mipro bootstrap LM raises at site 299"
    end
  end

  @impl true
  def supports?(_lm, _feature), do: true
end

# A raising teacher module — used to force bootstrap_round's task body to raise.
defmodule H0bS2.RaisingTeacher do
  @behaviour Dspy.Module
  defstruct []

  @impl true
  def forward(_teacher, _inputs) do
    raise "H0b S2: teacher raises"
  end
end

# A teacher that THROWS for inputs whose question starts with "boom" and
# returns a valid prediction otherwise. Used to prove site 274 is REACHABLE:
# generate_bootstrap_example/3 (bootstrap_few_shot.ex:317-343) has a `rescue`
# only (no `catch`), so a throw escapes it and reaches the site-274 child
# catch-all. A raise would be caught by the rescue and never reach the catch.
defmodule H0bS2.ThrowingTeacher do
  @behaviour Dspy.Module
  defstruct []

  @impl true
  def forward(_teacher, %{question: q} = _inputs) when is_binary(q) do
    if String.starts_with?(q, "boom") do
      throw(:h0b_s2_teacher_throw)
    else
      {:ok, Dspy.Prediction.new(%{answer: "4"})}
    end
  end

  def forward(_teacher, _inputs) do
    {:ok, Dspy.Prediction.new(%{answer: "4"})}
  end
end

defmodule H0bS2.ExitingTeacher do
  @behaviour Dspy.Module
  defstruct []

  @impl true
  def forward(_teacher, %{question: q} = _inputs) when is_binary(q) do
    if String.starts_with?(q, "boom") do
      exit(:h0b_s2_teacher_exit)
    else
      {:ok, Dspy.Prediction.new(%{answer: "4"})}
    end
  end

  def forward(_teacher, _inputs) do
    {:ok, Dspy.Prediction.new(%{answer: "4"})}
  end
end

defmodule H0bS2.TestQA do
  use Dspy.Signature

  input_field(:question, :string, "Question to answer")
  output_field(:answer, :string, "Answer to the question")
end

defmodule H0b.S2SiteTest do
  @moduledoc """
  H0b-1 S2: Task.async_stream site crash isolation tests.

  Real tests for the 7 S2 sites:

  Directly reachable (behaviour test):
  - ensemble.ex:37 (Ensemble.Program.forward/2) — raise/throw/exit isolation
    AND the E4 weight-alignment fix (a failing member must not shift the
    weight↔member pairing for `:weighted_average`).

  Reached via the public compile/3 entry point:
  - bootstrap_few_shot.ex:274 (bootstrap_round) — BEHAVIOUR PROOF: a teacher
    whose forward THROWS (or exits) escapes generate_bootstrap_example/3
    (bootstrap_few_shot.ex:317-343), which has a `rescue` only (no `catch`), so
    the throw/exit reaches the site-274 child catch-all. A raise would be caught
    by the inner rescue and NOT reach the catch. compile/3 returns {:ok, program}.
  - bootstrap_few_shot.ex:440 (select_best_program) — DEFENSE-IN-DEPTH:
    RaisingLM → Evaluate.evaluate's evaluate_chunk catches per example. Caller
    survives.
  - mipro_v2.ex:299 (bootstrap_few_shot_examples) — BEHAVIOUR PROOF: the task
    body calls Dspy.Module.forward/2 directly; MiproScriptedLM raises for the
    bootstrap QA prompts (answering instruction prompts), so the site-299
    catch-all drops every example and the compile returns a program (or a
    defined error) instead of crashing.

  DEFENSE-IN-DEPTH (characterization only, not a behaviour proof):
  - ensemble.ex:373 (train_ensemble_members) — inner layer: train_single_member
    (ensemble.ex:458-475) rescues around the base teleprompter's compile/3.
  - ensemble.ex:514 (calculate_performance_weights) — inner layer: Evaluate
    evaluate_chunk (evaluate.ex:295-325) catches per example.
  - simba.ex:169 (score_candidates) — inner layer: Evaluate evaluate_chunk
    (evaluate.ex:295-325) catches per example.

  See openspec/changes/h0b-crash-hardening/proposal.md 'Deviations' for the
  per-site file:line + inner-layer table.
  """
  use ExUnit.Case, async: false

  doctest Dspy

  @tag :h0b_s2
  test "ensemble.ex:37 forward/2 — a raising member does not kill the caller; survivors are combined" do
    program = %Dspy.Teleprompt.Ensemble.Program{
      members: [
        %H0bS2.RaisingModule{tag: :raise},
        %H0bS2.ConstantModule{answer: "a"},
        %H0bS2.ConstantModule{answer: "a"},
        %H0bS2.ConstantModule{answer: "b"}
      ],
      weights: [1.0, 1.0, 1.0, 1.0],
      strategy: :majority_vote,
      num_threads: 4,
      timeout_ms: 5_000
    }

    # Before H0b: the raising member's task exit would propagate to the caller
    # via Task.async_stream (default on_timeout / untrapped exit). After: the
    # child catch-all converts it to {:error, _}, the stream item is
    # {:ok, {:error, _}}, and we drop just that member.
    assert {:ok, pred} = Dspy.Module.forward(program, %{})
    assert pred.attrs.answer == "a"
  end

  @tag :h0b_s2
  test "ensemble.ex:37 forward/2 — a throwing member does not kill the caller" do
    program = %Dspy.Teleprompt.Ensemble.Program{
      members: [
        %H0bS2.ThrowingModule{},
        %H0bS2.ConstantModule{answer: "x"}
      ],
      weights: [1.0, 1.0],
      strategy: :majority_vote,
      num_threads: 2,
      timeout_ms: 5_000
    }

    assert {:ok, pred} = Dspy.Module.forward(program, %{})
    assert pred.attrs.answer == "x"
  end

  @tag :h0b_s2
  test "ensemble.ex:37 forward/2 — an exiting member does not kill the caller" do
    program = %Dspy.Teleprompt.Ensemble.Program{
      members: [
        %H0bS2.ExitingModule{},
        %H0bS2.ConstantModule{answer: "y"}
      ],
      weights: [1.0, 1.0],
      strategy: :majority_vote,
      num_threads: 2,
      timeout_ms: 5_000
    }

    assert {:ok, pred} = Dspy.Module.forward(program, %{})
    assert pred.attrs.answer == "y"
  end

  @tag :h0b_s2
  test "ensemble.ex:37 forward/2 — all members failing returns {:error, :all_ensemble_members_failed}" do
    program = %Dspy.Teleprompt.Ensemble.Program{
      members: [%H0bS2.RaisingModule{tag: :raise}, %H0bS2.RaisingModule{tag: :raise}],
      weights: [1.0, 1.0],
      strategy: :majority_vote,
      num_threads: 2,
      timeout_ms: 5_000
    }

    assert {:error, :all_ensemble_members_failed} = Dspy.Module.forward(program, %{})
  end

  @tag :h0b_s2
  @tag timeout: 10_000
  test "ensemble.ex:37 forward/2 — E4: a failing middle member does NOT shift weight alignment" do
    program = %Dspy.Teleprompt.Ensemble.Program{
      members: [
        # index 0 — FAILS, weight 5.0
        %H0bS2.RaisingModule{tag: :raise},
        # index 1 — survives, weight 1.0
        %H0bS2.ConstantModule{answer: "low"},
        # index 2 — survives, weight 9.0
        %H0bS2.ConstantModule{answer: "high"}
      ],
      weights: [5.0, 1.0, 9.0],
      strategy: :weighted_average,
      num_threads: 3,
      timeout_ms: 5_000
    }

    assert {:ok, pred} = Dspy.Module.forward(program, %{})

    # E4-correct: B("high") has weight 9.0 > A("low") weight 1.0 => "high".
    # Buggy (shifted): A would be paired with the FAIL weight 5.0 and B with
    # A's 1.0 => "low" would win (5.0 > 1.0). So "high" proves alignment held.
    assert pred.attrs.answer == "high"
  end

  # ---------------------------------------------------------------------------
  # Compile/3 tests for the 6 private sites
  # ---------------------------------------------------------------------------

  @tag :h0b_s2
  @tag timeout: 30_000
  test "bootstrap_few_shot.ex:274 bootstrap_round — throwing teacher: site-274 catch-all is REACHABLE (throw escapes the inner rescue), compile returns {:ok, program}" do
    # BEHAVIOUR PROOF. generate_bootstrap_example/3
    # (bootstrap_few_shot.ex:317-343) has a `rescue` ONLY (no `catch`): a teacher
    # forward that RAISES is caught there, but a teacher forward that THROWS (or
    # exits) escapes it and reaches the site-274 child catch-all. So site 274 is
    # REACHABLE — unlike ensemble:514 / simba:169 / bootstrap:440, whose inner
    # layer (Evaluate evaluate_chunk) catches every kind per example.
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %H0bS2.WorkingLM{})

    student = Dspy.Predict.new(H0bS2.TestQA)

    # One input throws (question starts with "boom"), the other succeeds.
    trainset = [
      Dspy.Example.new(question: "boom 2+2?", answer: "4"),
      Dspy.Example.new(question: "What is 2+2?", answer: "4")
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    teleprompt =
      Dspy.Teleprompt.BootstrapFewShot.new(
        metric: metric,
        teacher: %H0bS2.ThrowingTeacher{},
        max_bootstrapped_demos: 2,
        max_labeled_demos: 0,
        max_rounds: 1,
        num_candidate_programs: 1,
        num_threads: 1,
        seed: 123
      )

    # The throwing teacher's throw escapes generate_bootstrap_example's rescue
    # and reaches the site-274 child catch-all (`catch kind, reason ->
    # {:error, {:thrown, kind, reason}}`). The chunk is dropped, the bootstrap
    # yields the surviving example, and compile/3 returns {:ok, program} — not
    # a crash. Without the catch-all, the linked task's throw would kill the
    # caller (see mutation-bootstrap-274.log).
    assert {:ok, _optimized} =
             Dspy.Teleprompt.BootstrapFewShot.compile(teleprompt, student, trainset)
  end

  @tag :h0b_s2
  @tag timeout: 30_000
  test "bootstrap_few_shot.ex:274 bootstrap_round — exiting teacher: site-274 catch-all is REACHABLE (exit escapes the inner rescue), compile returns {:ok, program}" do
    # Same reachability as the throwing-teacher test, for the :exit arm of the
    # child catch-all (`catch :exit, reason -> {:error, {:exit, reason}}`).
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %H0bS2.WorkingLM{})

    student = Dspy.Predict.new(H0bS2.TestQA)

    trainset = [
      Dspy.Example.new(question: "boom 2+2?", answer: "4"),
      Dspy.Example.new(question: "What is 2+2?", answer: "4")
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    teleprompt =
      Dspy.Teleprompt.BootstrapFewShot.new(
        metric: metric,
        teacher: %H0bS2.ExitingTeacher{},
        max_bootstrapped_demos: 2,
        max_labeled_demos: 0,
        max_rounds: 1,
        num_candidate_programs: 1,
        num_threads: 1,
        seed: 123
      )

    assert {:ok, _optimized} =
             Dspy.Teleprompt.BootstrapFewShot.compile(teleprompt, student, trainset)
  end

  @tag :h0b_s2
  @tag timeout: 30_000
  test "bootstrap_few_shot.ex:440 select_best_program — all candidate evaluations fail: compile still returns a program" do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %H0bS2.RaisingLM{})

    student = Dspy.Predict.new(H0bS2.TestQA)

    trainset = [
      Dspy.Example.new(question: "What is 2+2?", answer: "4"),
      Dspy.Example.new(question: "Still 2+2?", answer: "4")
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    teleprompt =
      Dspy.Teleprompt.BootstrapFewShot.new(
        metric: metric,
        teacher: %H0bS2.WorkingTeacher{},
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        max_rounds: 1,
        num_candidate_programs: 2,
        num_threads: 1,
        seed: 123
      )

    # DEFENSE-IN-DEPTH, not a behaviour proof: select_best_program's task body
    # (bootstrap_few_shot.ex:440) calls Dspy.Evaluate.evaluate/4, whose inner
    # evaluate_chunk (evaluate.ex:295-325) catches every raise/throw/exit per
    # example and returns a scored item. So a RaisingLM makes every candidate
    # score 0.0 but never propagates an exception to the child catch-all. The
    # compile still returns a program (the first candidate via the empty-list
    # guard or a 0.0-scored candidate). This test asserts the caller survives;
    # it does NOT prove the child catch-all at :440 (recorded under
    # openspec/…/h0b-crash-hardening/proposal.md 'Deviations').
    assert {:ok, _optimized} =
             Dspy.Teleprompt.BootstrapFewShot.compile(teleprompt, student, trainset)
  end

  # NOTE: ensemble.ex:373 (train_ensemble_members) — DEFENSE-IN-DEPTH, not a
  # behaviour proof. The task body calls train_single_member/3, which has its own
  # `rescue e -> {:error, {:exception, …}}` around the base teleprompter's
  # compile/3 (ensemble.ex:458-475). A raising LM/forward is caught there and
  # converted to {:error, …}, so it never reaches the child catch-all at :373.
  # The characterization test below asserts the catch-all's presence.

  # NOTE: ensemble.ex:514 (calculate_performance_weights) — DEFENSE-IN-DEPTH.
  # The task body calls Dspy.Evaluate.evaluate/4, whose evaluate_chunk
  # (evaluate.ex:295-325) catches every raise/throw/exit per example. A failing
  # forward or metric never reaches the child catch-all at :514.

  # NOTE: simba.ex:169 (score_candidates) — DEFENSE-IN-DEPTH. Same as
  # ensemble.ex:514: the task body calls Dspy.Evaluate.evaluate/4, whose
  # evaluate_chunk catches per example.

  @tag :h0b_s2
  @tag timeout: 30_000
  test "mipro_v2.ex:299 bootstrap_few_shot_examples — raising student forward: catch-all drops example, compile returns a program" do
    # BEHAVIOUR PROOF (unlike the defense-in-depth sites above). The task body
    # at mipro_v2.ex:299 calls Dspy.Module.forward/2 directly — not wrapped in
    # Evaluate.evaluate or a rescuing helper. MiproScriptedLM answers the
    # instruction-generation prompts (so generate_instruction_candidates/3
    # succeeds) but raises for every bootstrap QA prompt. Because the student is
    # a Dspy.Predict whose forward delegates to that LM, Dspy.Module.forward/2
    # at site 299 raises, and the child catch-all converts it to {:error, _}.
    # The stream drops the failing examples, the bootstrap yields an empty demo
    # list, and the compile still returns a program (or a defined error) — it
    # must NOT crash.
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %H0bS2.MiproScriptedLM{})

    student = Dspy.Predict.new(H0bS2.TestQA)

    trainset =
      for i <- 1..10,
          do: Dspy.Example.new(question: "What is #{i}+#{i}?", answer: "#{i * 2}")

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    teleprompt =
      Dspy.Teleprompt.MIPROv2.new(
        metric: metric,
        num_trials: 1,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        num_threads: 1,
        seed: 123,
        verbose: false
      )

    result = Dspy.Teleprompt.MIPROv2.compile(teleprompt, student, trainset)

    # The site-299 catch-all drops every raising example; the compile must not
    # crash. It returns a program (if the optimizer finds a usable config) or a
    # defined error tuple. Either way the caller survives — which is the
    # invariant under test (A4.1: the caller process never dies).
    assert match?({:ok, _}, result) or match?({:error, _}, result)
  end

  # ---------------------------------------------------------------------------
  # Source characterization: all 7 sites carry a child catch-all + on_timeout.
  # For the three sites whose inner layer already catches every kind
  # (ensemble:373, ensemble:514, simba:169), this only asserts the catch-all's
  # presence and is NOT a behaviour proof (see proposal.md 'Deviations').
  # bootstrap:274 and mipro:299 ARE behaviour-proven (throwing/exiting teacher
  # at :274; raising LM at :299). bootstrap:440 is defense-in-depth (Evaluate
  # evaluate_chunk catches per example).
  # ---------------------------------------------------------------------------

  @tag :h0b_s2
  test "all 7 S2 sites carry a child catch-all and on_timeout: :kill_task" do
    files = %{
      "lib/dspy/teleprompt/ensemble.ex" => 3,
      "lib/dspy/teleprompt/simba.ex" => 1,
      "lib/dspy/teleprompt/mipro_v2.ex" => 1,
      "lib/dspy/teleprompt/bootstrap_few_shot.ex" => 2
    }

    Enum.each(files, fn {file, expected_sites} ->
      content = File.read!(file)
      sites = content |> String.split("Task.async_stream(") |> length() |> Kernel.-(1)

      assert sites == expected_sites,
             "#{file}: expected #{expected_sites} Task.async_stream sites, found #{sites}"

      kill_task_count =
        content |> String.split("on_timeout: :kill_task") |> length() |> Kernel.-(1)

      assert kill_task_count == expected_sites,
             "#{file}: expected #{expected_sites} on_timeout: :kill_task, found #{kill_task_count}"

      exit_clause =
        content
        |> String.split(":exit, reason -> {:error, {:exit, reason}}")
        |> length()
        |> Kernel.-(1)

      assert exit_clause == expected_sites,
             "#{file}: expected #{expected_sites} :exit catch clauses, found #{exit_clause}"
    end)
  end
end
