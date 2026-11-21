defmodule Dspy.RefineTest do
  use ExUnit.Case, async: true

  alias Dspy.{ChainOfThought, LM, Predict, Prediction, Refine, Settings}
  alias Dspy.Signature.Adapters.Default

  defmodule QA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule RecordingLM do
    @behaviour LM
    defstruct [:owner, :name, :key, :outcomes]

    @impl true
    def generate(lm, request) do
      index = Process.get(lm.key, 0)
      Process.put(lm.key, index + 1)
      send(lm.owner, {:lm_call, lm.name, Settings.get(:rollout_id), request})
      Enum.fetch!(lm.outcomes, index)
    end
  end

  defmodule TwoStageProgram do
    use Dspy.Module

    defstruct [:first, :second]

    @impl true
    def forward(program, inputs) do
      with {:ok, _} <- Dspy.Module.forward(program.first, inputs) do
        Dspy.Module.forward(program.second, inputs)
      end
    end
  end

  defmodule CustomProgram do
    use Dspy.Module

    defstruct [:lm]

    @impl true
    def forward(program, %{question: question} = inputs) do
      request =
        inputs |> Map.take([:temperature]) |> Map.put(:messages, [LM.user_message(question)])

      with {:ok, answer} <- LM.generate(program.lm, request) do
        {:ok, Prediction.new(%{answer: answer})}
      end
    end
  end

  defmodule SequenceProgram do
    use Dspy.Module

    defstruct [:counter, :answers]

    @impl true
    def forward(%__MODULE__{counter: counter, answers: answers}, _inputs) do
      idx = Agent.get_and_update(counter, fn i -> {i, i + 1} end)
      answer = Enum.at(answers, idx) || List.last(answers)
      {:ok, Dspy.Prediction.new(%{answer: answer})}
    end
  end

  test "new/2 validates options" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    prog = %SequenceProgram{counter: counter, answers: ["x"]}

    assert_raise ArgumentError, ~r/:n must be a positive integer/, fn ->
      Dspy.Refine.new(prog, n: 0, reward_fn: fn _, _ -> 1.0 end)
    end

    assert_raise ArgumentError, ~r/:reward_fn must be a function with arity 2/, fn ->
      Dspy.Refine.new(prog, n: 1, reward_fn: fn _ -> 1.0 end)
    end
  end

  test "selects the best attempt (including negative rewards)" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    program =
      %SequenceProgram{
        counter: counter,
        answers: ["bad", "good"]
      }

    refiner =
      Dspy.Refine.new(program,
        n: 2,
        threshold: 0.0,
        reward_fn: fn _inputs, pred -> if pred.attrs.answer == "good", do: -1.0, else: -2.0 end
      )

    assert {:ok, pred} = Dspy.Module.forward(refiner, %{question: "q"})
    assert pred.attrs.answer == "good"
  end

  test "errors when reward_fn never returns a score" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    program =
      %SequenceProgram{
        counter: counter,
        answers: ["x", "y"]
      }

    refiner =
      Dspy.Refine.new(program,
        n: 2,
        threshold: 1.0,
        reward_fn: fn _inputs, _pred -> raise "boom" end
      )

    assert {:error, {:no_scored_attempts, meta}} = Dspy.Module.forward(refiner, %{question: "q"})
    assert meta.invalid_reward_attempts == 2
    assert meta.scored_attempts == 0
  end

  test "named predictor rollouts use distinct cache entries and score in the original scope" do
    first = recording_lm(:predict, ok: "Answer: draft", ok: "Answer: draft")

    second =
      recording_lm(:chain_of_thought,
        ok: "Reasoning: draft\nAnswer: below target",
        ok: "Reasoning: revised\nAnswer: target"
      )

    first_config = %{temperature: 0.2, rollout_id: 7, max_tokens: 16}
    second_config = %{temperature: 0.3, rollout_id: nil, max_tokens: 24}

    program = %TwoStageProgram{
      first: Predict.new(QA, lm: first, config: first_config, adapter: Default),
      second: ChainOfThought.new(QA, lm: second, config: second_config, adapter: Default)
    }

    refiner = Refine.new(program, n: 3, threshold: 1.0, reward_fn: reward_recorder())
    inputs = %{question: "same prompt for both attempts"}
    outer_context = Settings.current_overrides()

    Dspy.context([cache: true, rollout_id: 50, temperature: 0.6, max_tokens: 100], fn ->
      scoped = Settings.current_overrides()
      result = Dspy.call(refiner, inputs)

      assert_received {:lm_call, :predict, 50, first_request}
      assert_received {:lm_call, :chain_of_thought, 50, second_request}
      assert_received {:lm_call, :predict, 51, ^first_request}
      assert_received {:lm_call, :chain_of_thought, 51, ^second_request}
      refute_received {:lm_call, _, _, _}

      assert %{temperature: 1.0, max_tokens: 16} = first_request
      assert %{temperature: 1.0, max_tokens: 24} = second_request
      refute Enum.any?(Map.keys(first_request), &(&1 in [:rollout_id, "rollout_id"]))
      refute Enum.any?(Map.keys(second_request), &(&1 in [:rollout_id, "rollout_id"]))

      assert {:ok, %Prediction{attrs: %{answer: "target"}} = prediction} = result
      assert_rewards(scoped)
      assert Settings.current_overrides() == scoped

      assert {:ok, ^prediction} = Dspy.call(refiner, inputs)
      assert_rewards(scoped)
      refute_received {:lm_call, _, _, _}
      assert Settings.current_overrides() == scoped
    end)

    assert Settings.current_overrides() == outer_context
    assert Predict.get_config(refiner.program.first) == first_config
    assert ChainOfThought.get_config(refiner.program.second) == second_config
  end

  test "custom modules inherit the rollout scope, skip failed attempts, and keep the last tie" do
    lm = recording_lm(:custom, error: :offline_failure, ok: "first", ok: "last")

    refiner =
      Refine.new(%CustomProgram{lm: lm},
        n: 3,
        threshold: 1.0,
        reward_fn: reward_recorder()
      )

    Dspy.context([cache: true, rollout_id: nil, temperature: 0.4], fn ->
      scoped = Settings.current_overrides()
      result = Dspy.call(refiner, %{question: "same custom request"})

      assert_received {:lm_call, :custom, 0, request}
      assert_received {:lm_call, :custom, 1, ^request}
      assert_received {:lm_call, :custom, 2, ^request}
      assert %{temperature: 1.0} = request
      refute Map.has_key?(request, :rollout_id)
      refute_received {:lm_call, _, _, _}

      assert {:ok, %Prediction{attrs: %{answer: "last"}}} = result
      assert_received {:reward, ^scoped, "first"}
      assert_received {:reward, ^scoped, "last"}
      refute_received {:reward, _, _}
      assert Settings.current_overrides() == scoped
    end)
  end

  test "custom modules can set an explicit request temperature" do
    program = %CustomProgram{lm: recording_lm(:custom, ok: "answer")}
    refiner = Refine.new(program, n: 1, reward_fn: fn _, _ -> 1.0 end)

    Dspy.context([cache: false, rollout_id: 5, temperature: 0.4], fn ->
      assert {:ok, %Prediction{attrs: %{answer: "answer"}}} =
               Dspy.call(refiner, %{question: "custom request", temperature: 0.3})

      assert_received {:lm_call, :custom, 5, %{temperature: 0.3}}
    end)
  end

  defp recording_lm(name, outcomes) do
    %RecordingLM{owner: self(), name: name, key: make_ref(), outcomes: outcomes}
  end

  defp reward_recorder do
    owner = self()

    fn _inputs, %Prediction{attrs: %{answer: answer}} ->
      send(owner, {:reward, Settings.current_overrides(), answer})
      if answer == "target", do: 1.0, else: 0.5
    end
  end

  defp assert_rewards(scoped) do
    assert_received {:reward, ^scoped, "below target"}
    assert_received {:reward, ^scoped, "target"}
    refute_received {:reward, _, _}
  end
end
