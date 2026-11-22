defmodule Dspy.Teleprompt.GEPACustomProposerTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Predict, Prediction, Settings, Signature, Teleprompt}
  alias Dspy.Signature.Adapters.JSONAdapter
  alias Dspy.Teleprompt.GEPA
  alias Dspy.Teleprompt.GEPA.InstructionProposer

  @starting "Answer zero."
  @improved "Answer four."
  @integer_slot [{:field, :slots}, {:key, 1}]
  @string_slot [{:field, :slots}, {:key, "1"}]
  @dormant_slot [{:field, :slots}, {:key, :dormant}]

  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:owner, :label, fail_string_slot?: false]

    @impl true
    def generate(%__MODULE__{label: :rollout, owner: owner}, request) do
      prompt = List.last(request.messages).content
      question = if prompt =~ "training row", do: :train, else: :held_out
      slot = if prompt =~ "integer slot", do: 1, else: "1"
      answer = if prompt =~ "Answer four.", do: "4", else: "0"
      send(owner, {:rollout, question, slot, answer, Settings.get(:lm)})
      {:ok, Jason.encode!(%{answer: answer})}
    end

    def generate(%__MODULE__{label: :all_reflection, owner: owner} = lm, request) do
      prompt = List.last(request.messages).content
      send(owner, {:joint_reflection, prompt})

      if lm.fail_string_slot? and prompt =~ "training row string slot" do
        {:error, :failed_reflection}
      else
        {:ok, Jason.encode!(%{new_instruction: "Answer four."})}
      end
    end

    def generate(%__MODULE__{owner: owner, label: label}, _request) do
      send(owner, {:reflection_lm_called, label})
      {:ok, Jason.encode!(%{new_instruction: "Answer four."})}
    end
  end

  defmodule PairedPredictors do
    @behaviour Dspy.Module
    defstruct [:slots]

    @impl true
    def forward(program, %{question: question}) do
      with {:ok, integer} <-
             Predict.forward(program.slots[1], %{
               question: question <> " integer slot",
               unrelated: "UNDECLARED_SLOT_INPUT"
             }),
           {:ok, string} <-
             Predict.forward(program.slots["1"], %{question: question <> " string slot"}) do
        {:ok, Prediction.new(answer: integer[:answer], sibling: string[:answer])}
      end
    end
  end

  test "a proposer alone improves held-out scores at the exact selected slot" do
    owner = self()
    program = program()
    assert program.slots[1] == program.slots["1"]

    proposer = fn candidate, reflective_dataset, [selected] ->
      send(owner, {:proposal, candidate, reflective_dataset, [selected], Settings.get(:lm)})
      %{selected => @improved}
    end

    tp = optimizer(proposer, candidate_selection_strategy: :pareto, max_metric_calls: 4)

    Dspy.context([lm: nil, cache: false], fn ->
      assert {:ok, optimized} = GEPA.compile(tp, program, [training()], valset: [held_out()])
      assert optimized.slots[1].signature.instructions == @improved
      assert optimized.slots["1"] == program.slots["1"]
      assert program.slots[1].signature.instructions == @starting
      assert Settings.get(:lm) == nil

      integer_slot = @integer_slot
      string_slot = @string_slot

      assert_received {:proposal,
                       %{^integer_slot => @starting, ^string_slot => @starting} = prior,
                       %{^integer_slot => [observation]} = report, [@integer_slot], nil}

      assert map_size(prior) == 2
      assert map_size(report) == 1
      assert observation.inputs == %{"question" => "training row integer slot"}
      assert observation.outputs == %{"answer" => "0"}
      assert byte_size(observation.feedback) <= 1_024
      assert observation.feedback =~ "Change its answer."
      assert observation.feedback =~ "[truncated]"

      inspected = inspect(report, limit: :infinity, printable_limit: :infinity)
      refute inspected =~ "UNDECLARED_SLOT_INPUT"
      refute inspected =~ "PRIVATE_TRAINING_LABEL"
      refute inspected =~ "held-out row"
      refute_received {:proposal, _, _, _, _}

      assert_rollouts([
        {:held_out, 1, "0", nil},
        {:held_out, "1", "0", nil},
        {:train, 1, "0", nil},
        {:train, "1", "0", nil},
        {:train, 1, "4", nil},
        {:train, "1", "0", nil},
        {:held_out, 1, "4", nil},
        {:held_out, "1", "0", nil}
      ])
    end)
  end

  test "Teleprompt.compile scopes a reflection LM only to the callback" do
    owner = self()
    ambient = %ScriptedLM{owner: owner, label: :ambient}
    reflection = %ScriptedLM{owner: owner, label: :reflection}

    proposer = fn _candidate, _examples, [selected] ->
      send(owner, {:scoped_lm, Settings.get(:lm)})
      %{selected => @improved}
    end

    Dspy.context([lm: ambient, cache: false], fn ->
      for {options, expected_lm} <- [{[], ambient}, {[reflection_lm: reflection], reflection}] do
        tp = optimizer(proposer, options)
        assert {:ok, optimized} = Teleprompt.compile(tp, program(), [training()])
        assert optimized.slots[1].signature.instructions == @improved
        assert_received {:scoped_lm, ^expected_lm}
        assert Settings.get(:lm) == ambient

        assert_rollouts([
          {:train, 1, "0", ambient},
          {:train, "1", "0", ambient},
          {:train, 1, "0", ambient},
          {:train, "1", "0", ambient},
          {:train, 1, "4", ambient},
          {:train, "1", "0", ambient}
        ])
      end
    end)
  end

  test "selecting all observed slots produces one joint candidate in the same Pareto budget" do
    owner = self()
    program = program_with_dormant_slot()
    assert program.slots[1] === program.slots["1"]

    proposer = fn candidate, observations, paths ->
      send(owner, {:proposal, candidate, observations, paths, Settings.get(:lm)})
      Map.new(paths, &{&1, @improved})
    end

    reflection = %ScriptedLM{owner: self(), label: :reflection}

    tp =
      optimizer(proposer,
        component_selector: :all,
        candidate_selection_strategy: :pareto,
        max_metric_calls: 4,
        metric: &joint_score/5,
        reflection_lm: reflection
      )

    Dspy.context([lm: nil, cache: false], fn ->
      assert {:ok, optimized} = GEPA.compile(tp, program, [training()], valset: [held_out()])
      assert optimized.slots[1].signature.instructions == @improved
      assert optimized.slots["1"].signature.instructions == @improved
      assert optimized.slots[:dormant] === program.slots[:dormant]
      assert program.slots[1].signature.instructions == @starting
      assert Settings.get(:lm) == nil

      assert_received {:proposal, candidate, observations, [@integer_slot, @string_slot],
                       ^reflection}

      assert candidate == %{
               @integer_slot => @starting,
               @string_slot => @starting,
               @dormant_slot => @starting
             }

      assert %{@integer_slot => [integer], @string_slot => [string]} = observations
      assert map_size(observations) == 2
      assert integer.inputs == %{"question" => "training row integer slot"}
      assert string.inputs == %{"question" => "training row string slot"}
      assert integer.outputs == %{"answer" => "0"}
      assert string.outputs == %{"answer" => "0"}
      assert integer.feedback == "Improve both answers."
      assert string.feedback == "Improve both answers."
      refute_received {:proposal, _, _, _, _}

      assert_joint_rollouts()
    end)
  end

  test "both built-in reflection paths collect per-slot proposals before scoring one candidate" do
    Dspy.context([lm: nil, cache: false], fn ->
      for proposer <- [nil, InstructionProposer.new()] do
        tp =
          optimizer(proposer,
            component_selector: :all,
            candidate_selection_strategy: :pareto,
            max_metric_calls: 4,
            metric: &joint_score/5,
            reflection_lm: %ScriptedLM{owner: self(), label: :all_reflection}
          )

        program = program_with_dormant_slot()
        assert {:ok, optimized} = GEPA.compile(tp, program, [training()], valset: [held_out()])
        assert optimized.slots[1].signature.instructions == @improved
        assert optimized.slots["1"].signature.instructions == @improved
        assert optimized.slots[:dormant] === program.slots[:dormant]

        assert_joint_reflections()
        assert_joint_rollouts()
      end
    end)
  end

  test "a later built-in proposal failure discards earlier changes before candidate scoring" do
    Dspy.context([lm: nil, cache: false], fn ->
      for proposer <- [nil, InstructionProposer.new()] do
        tp =
          optimizer(proposer,
            component_selector: :all,
            reflection_lm: %ScriptedLM{
              owner: self(),
              label: :all_reflection,
              fail_string_slot?: true
            }
          )

        assert {:error, {:reflection_failed, :failed_reflection}} =
                 GEPA.compile(tp, program_with_dormant_slot(), [training()], valset: [held_out()])

        assert_joint_reflections()
        assert_baseline_rollouts(nil)
      end
    end)
  end

  test "all-slot proposals reject unobserved or invalid updates before scoring" do
    Dspy.context([lm: nil, cache: false], fn ->
      for {updates, expected} <- [
            {%{@integer_slot => @improved, @dormant_slot => @improved},
             :unselected_instruction_slot},
            {%{@integer_slot => @improved, @string_slot => 42}, :invalid_instruction_proposal}
          ] do
        tp = optimizer(fn _, _, _ -> updates end, component_selector: :all)

        assert {:error, {:reflection_failed, ^expected}} =
                 GEPA.compile(tp, program_with_dormant_slot(), [training()], valset: [held_out()])

        assert_baseline_rollouts(nil)
      end
    end)
  end

  test "all-slot proposals can update just one of the observed slots" do
    tp = optimizer(fn _, _, _ -> %{@integer_slot => @improved} end, component_selector: :all)
    program = program_with_dormant_slot()

    Dspy.context([lm: nil, cache: false], fn ->
      assert {:ok, optimized} = GEPA.compile(tp, program, [training()], valset: [held_out()])
      assert optimized.slots[1].signature.instructions == @improved
      assert optimized.slots["1"] === program.slots["1"]
      assert optimized.slots[:dormant] === program.slots[:dormant]

      assert_rollouts([
        {:held_out, 1, "0", nil},
        {:held_out, "1", "0", nil},
        {:train, 1, "0", nil},
        {:train, "1", "0", nil},
        {:held_out, 1, "4", nil},
        {:held_out, "1", "0", nil}
      ])
    end)
  end

  test "a raised callback restores the LM and reports a static error" do
    owner = self()
    ambient = %ScriptedLM{owner: owner, label: :ambient}
    reflection = %ScriptedLM{owner: owner, label: :reflection}

    tp =
      optimizer(
        fn _, _, _ ->
          send(owner, {:scoped_lm, Settings.get(:lm)})
          raise "PRIVATE_PROPOSER_ERROR"
        end,
        reflection_lm: reflection
      )

    Dspy.context([lm: ambient, cache: false], fn ->
      assert {:error, {:reflection_failed, :instruction_proposer_raised}} =
               GEPA.compile(tp, program(), [training()], valset: [held_out()])

      assert_received {:scoped_lm, ^reflection}
      assert Settings.get(:lm) == ambient
      assert_baseline_rollouts(ambient)
    end)
  end

  test "invalid proposals are rejected before scoring a candidate" do
    Dspy.context([lm: nil, cache: false], fn ->
      for {result, reason} <- [
            {nil, :invalid_instruction_proposal},
            {%URI{}, :invalid_instruction_proposal},
            {%{@integer_slot => nil}, :invalid_instruction_proposal},
            {%{@integer_slot => <<"Answer ", 255>>}, :invalid_instruction_proposal},
            {%{@integer_slot => String.duplicate("x", 4_097)}, :instruction_too_long},
            {%{@string_slot => @improved}, :unselected_instruction_slot},
            {%{@integer_slot => @improved, @string_slot => @improved},
             :unselected_instruction_slot},
            {%{[{:field, :missing}] => @improved}, :unselected_instruction_slot}
          ] do
        tp = optimizer(fn _, _, _ -> result end)

        assert {:error, {:reflection_failed, ^reason}} =
                 GEPA.compile(tp, program(), [training()], valset: [held_out()])

        assert_baseline_rollouts(nil)
      end
    end)
  end

  test "an empty, blank, or unchanged proposal performs no candidate rollout" do
    program = program()

    Dspy.context([lm: nil, cache: false], fn ->
      for result <- [%{}, %{@integer_slot => "   "}, %{@integer_slot => "  #{@starting}  "}] do
        tp = optimizer(fn _, _, _ -> result end)
        assert {:ok, ^program} = GEPA.compile(tp, program, [training()], valset: [held_out()])
        assert_baseline_rollouts(nil)
      end
    end)
  end

  test "the constructor validates proposer arity and disallows supplied candidates" do
    for invalid <- [:not_callable, fn _, _ -> %{} end] do
      assert_raise ArgumentError, ~r/instruction_proposer.*three arguments/, fn ->
        optimizer(invalid)
      end
    end

    assert_raise ArgumentError, ~r/reflection_lm.*Dspy.LM/, fn ->
      optimizer(nil)
    end

    assert_raise ArgumentError, ~r/:candidates/, fn ->
      optimizer(fn _, _, _ -> %{} end, candidates: [@starting])
    end
  end

  test "an explicit nil and a missing legacy proposer both use the reflection LM" do
    reflection = %ScriptedLM{owner: self(), label: :reflection}

    tp =
      GEPA.new(
        metric: &score/5,
        reflection_lm: reflection,
        instruction_proposer: nil,
        max_metric_calls: 3,
        num_threads: 1
      )

    Dspy.context([lm: nil, cache: false], fn ->
      for variant <- [tp, Map.drop(tp, [:instruction_proposer, :component_selector])] do
        assert {:ok, optimized} =
                 GEPA.compile(variant, program(), [training()], valset: [held_out()])

        assert optimized.slots[1].signature.instructions == @improved
        assert_received {:reflection_lm_called, :reflection}
      end
    end)
  end

  test "reflective component selectors are limited to round-robin and all" do
    assert_raise ArgumentError, ~r/component_selector.*round_robin.*all/, fn ->
      optimizer(fn _, _, _ -> %{} end, component_selector: :unknown)
    end
  end

  defp optimizer(proposer, opts \\ []) do
    options = [
      metric: &score/5,
      instruction_proposer: proposer,
      max_metric_calls: 3,
      num_threads: 1
    ]

    Teleprompt.new(:gepa, Keyword.merge(options, opts))
  end

  defp score(_example, prediction, _trace, _name, _steps) do
    %{
      score: if(prediction[:answer] == "4", do: 1.0, else: 0.0),
      feedback: "Change its answer. " <> String.duplicate("details", 400)
    }
  end

  defp joint_score(_example, prediction, _trace, _name, _steps) do
    %{
      score: if(prediction[:answer] == "4" and prediction[:sibling] == "4", do: 1.0, else: 0.0),
      feedback: "Improve both answers."
    }
  end

  defp program do
    signature = %{Signature.define("question -> answer") | instructions: @starting}

    predictor =
      Predict.new(signature,
        lm: %ScriptedLM{owner: self(), label: :rollout},
        adapter: JSONAdapter,
        max_retries: 0
      )

    %PairedPredictors{slots: %{1 => predictor, "1" => predictor}}
  end

  defp program_with_dormant_slot do
    program = program()
    put_in(program.slots[:dormant], program.slots[1])
  end

  defp training do
    Example.new(question: "training row", answer: "PRIVATE_TRAINING_LABEL")
    |> Example.with_inputs(:question)
  end

  defp held_out, do: Example.new(question: "held-out row") |> Example.with_inputs(:question)

  defp assert_baseline_rollouts(ambient) do
    assert_rollouts([
      {:held_out, 1, "0", ambient},
      {:held_out, "1", "0", ambient},
      {:train, 1, "0", ambient},
      {:train, "1", "0", ambient}
    ])
  end

  defp assert_joint_rollouts do
    assert_rollouts([
      {:held_out, 1, "0", nil},
      {:held_out, "1", "0", nil},
      {:train, 1, "0", nil},
      {:train, "1", "0", nil},
      {:train, 1, "4", nil},
      {:train, "1", "4", nil},
      {:held_out, 1, "4", nil},
      {:held_out, "1", "4", nil}
    ])
  end

  defp assert_joint_reflections do
    assert_received {:joint_reflection, integer}
    assert integer =~ "training row integer slot"
    refute integer =~ "training row string slot"
    assert_received {:joint_reflection, string}
    assert string =~ "training row string slot"
    refute string =~ "training row integer slot"
    refute_received {:joint_reflection, _}
  end

  defp assert_rollouts(expected) do
    for {question, slot, answer, lm} <- expected do
      assert_received {:rollout, actual_question, actual_slot, actual_answer, actual_lm}

      assert {actual_question, actual_slot, actual_answer, actual_lm} ==
               {question, slot, answer, lm}
    end

    refute_received {:rollout, _, _, _, _}
    refute_received {:reflection_lm_called, _}
  end
end
