defmodule Dspy.BestOfNTest do
  # `async: false` — tests mutate global `Dspy.Settings` via `Dspy.configure/1`.
  use ExUnit.Case, async: false

  defmodule TestQA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule CountingLM do
    @moduledoc false

    # Returns a different answer per call (from `answers`, cycling), and
    # announces each real LM call to `pid` so tests can count non-cached
    # calls.
    @behaviour Dspy.LM
    defstruct [:pid, :calls, :answers]

    @impl true
    def generate(%__MODULE__{pid: pid, calls: calls, answers: answers}, _request) do
      idx = Agent.get(calls, fn {i, _} -> i end)
      Agent.update(calls, fn {_i, _list} -> {idx + 1, nil} end)
      answer = Enum.at(answers, rem(idx, length(answers)))
      send(pid, :lm_called)

      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: #{answer}"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule RawCapturingLM do
    @moduledoc false

    # Records the raw request map as seen by the behaviour callback.
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      send(pid, {:raw, request})

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Answer: ok"},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule RolloutCapturingProgram do
    # A module whose forward captures the rollout_id it sees in the attempt
    # context and stores it in the given Agent.
    use Dspy.Module

    defstruct [:ids]

    @impl true
    def forward(%__MODULE__{ids: ids}, _inputs) do
      rid = Dspy.Settings.get(:rollout_id)
      Agent.update(ids, fn list -> [rid | list] end)
      {:ok, Dspy.Prediction.new(%{answer: "ok"})}
    end
  end

  defmodule AlwaysErrorProgram do
    use Dspy.Module

    defstruct []

    @impl true
    def forward(_module, _inputs), do: {:error, :simulated_provider_down}
  end

  setup do
    Dspy.LM.Cache.clear()
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  defp start_calls_agent, do: Agent.start_link(fn -> {0, []} end)

  describe "new/2 validation" do
    test "requires reward_fn with arity 2" do
      program = Dspy.Predict.new(TestQA)

      assert_raise ArgumentError, ~r/:reward_fn must be a function with arity 2/, fn ->
        Dspy.BestOfN.new(program, n: 1, threshold: 1.0, reward_fn: fn _ -> 1.0 end)
      end

      assert_raise KeyError, ~r/:reward_fn/, fn ->
        Dspy.BestOfN.new(program, n: 1, threshold: 1.0)
      end
    end

    test "requires n to be a positive integer" do
      program = Dspy.Predict.new(TestQA)

      assert_raise ArgumentError, ~r/:n must be a positive integer/, fn ->
        Dspy.BestOfN.new(program, n: 0, threshold: 1.0, reward_fn: fn _, _ -> 1.0 end)
      end
    end

    test "requires threshold to be a number" do
      program = Dspy.Predict.new(TestQA)

      assert_raise ArgumentError, ~r/:threshold must be a number/, fn ->
        Dspy.BestOfN.new(program, n: 2, threshold: "high", reward_fn: fn _, _ -> 1.0 end)
      end

      assert_raise KeyError, ~r/:threshold/, fn ->
        Dspy.BestOfN.new(program, n: 2, reward_fn: fn _, _ -> 1.0 end)
      end
    end

    test "requires fail_count to be a non-negative integer" do
      program = Dspy.Predict.new(TestQA)

      assert_raise ArgumentError, ~r/:fail_count must be a non-negative integer/, fn ->
        Dspy.BestOfN.new(
          program,
          n: 2,
          threshold: 1.0,
          reward_fn: fn _, _ -> 1.0 end,
          fail_count: -1
        )
      end
    end

    test "accepts :N alias for :n" do
      program = Dspy.Predict.new(TestQA)

      assert %Dspy.BestOfN{n: 3} =
               Dspy.BestOfN.new(program, N: 3, threshold: 1.0, reward_fn: fn _, _ -> 1.0 end)
    end

    test "fail_count defaults to n" do
      program = Dspy.Predict.new(TestQA)

      assert %Dspy.BestOfN{fail_count: 3, n: 3} =
               Dspy.BestOfN.new(program, n: 3, threshold: 1.0, reward_fn: fn _, _ -> 1.0 end)
    end
  end

  describe "forward/2" do
    test "stops early when a reward meets the threshold" do
      {:ok, calls} = start_calls_agent()
      lm = %CountingLM{pid: self(), calls: calls, answers: ["one-word", "two words", "x y z"]}
      Dspy.configure(lm: lm)
      program = Dspy.Predict.new(TestQA)

      bon =
        Dspy.BestOfN.new(program,
          n: 3,
          threshold: 1.0,
          reward_fn: fn _inputs, pred ->
            if String.split(pred.attrs.answer) |> length() == 1, do: 1.0, else: 0.0
          end
        )

      assert {:ok, pred} = Dspy.call(bon, %{question: "q"})
      assert pred.attrs.answer == "one-word"

      # Only the first attempt ran (early stop at threshold).
      assert_receive :lm_called, 50
      refute_receive :lm_called, 50
    end

    test "picks the highest-reward attempt when none reach threshold" do
      {:ok, calls} = start_calls_agent()
      lm = %CountingLM{pid: self(), calls: calls, answers: ["bad", "worse", "best"]}
      Dspy.configure(lm: lm)
      program = Dspy.Predict.new(TestQA)

      rewards = %{"bad" => 0.1, "worse" => 0.2, "best" => 0.9}

      bon =
        Dspy.BestOfN.new(program,
          n: 3,
          threshold: 1.0,
          reward_fn: fn _inputs, pred -> Map.fetch!(rewards, pred.attrs.answer) end
        )

      assert {:ok, pred} = Dspy.call(bon, %{question: "q"})
      assert pred.attrs.answer == "best"

      assert_receive :lm_called, 50
      assert_receive :lm_called, 50
      assert_receive :lm_called, 50
      refute_receive :lm_called, 50
    end

    test "ties keep the first attempt" do
      {:ok, calls} = start_calls_agent()
      lm = %CountingLM{pid: self(), calls: calls, answers: ["first", "second"]}
      Dspy.configure(lm: lm)
      program = Dspy.Predict.new(TestQA)

      bon =
        Dspy.BestOfN.new(program,
          n: 2,
          threshold: 1.0,
          reward_fn: fn _inputs, _pred -> 0.5 end
        )

      assert {:ok, pred} = Dspy.call(bon, %{question: "q"})
      assert pred.attrs.answer == "first"
    end

    test "each attempt sees temperature 1.0 and a distinct rollout_id" do
      # rollout_id: capture from inside the module's forward, which runs in
      # the attempt's Dspy.context. (The reward fn runs after the context
      # exits, so it cannot observe the per-attempt rollout_id.)
      {:ok, ids} = Agent.start_link(fn -> [] end)
      program = %RolloutCapturingProgram{ids: ids}

      bon =
        Dspy.BestOfN.new(program,
          n: 3,
          threshold: 1.0,
          reward_fn: fn _inputs, _pred -> 0.0 end
        )

      assert {:ok, _} = Dspy.call(bon, %{question: "q"})
      assert Enum.reverse(Agent.get(ids, fn l -> l end)) == [0, 1, 2]

      # temperature 1.0 reaches the LM request map for every attempt.
      # (Dspy.LM.generate/2 applies settings defaults; /1 does not.)
      pid = self()
      lm = %RawCapturingLM{pid: pid}
      Dspy.configure(lm: lm)

      Dspy.Settings.context([rollout_id: 0, temperature: 1.0], fn ->
        request = %{messages: [%{role: "user", content: "hi"}]}
        assert {:ok, _} = Dspy.LM.generate(lm, request)
        assert_receive {:raw, %{temperature: 1.0}}
      end)
    end

    test "nested rollout_id offsets the per-attempt ids" do
      {:ok, ids} = Agent.start_link(fn -> [] end)
      program = %RolloutCapturingProgram{ids: ids}

      bon =
        Dspy.BestOfN.new(program,
          n: 2,
          threshold: 1.0,
          reward_fn: fn _inputs, _pred -> 0.0 end
        )

      Dspy.Settings.context([rollout_id: 100], fn ->
        assert {:ok, _} = Dspy.call(bon, %{question: "q"})
      end)

      assert Enum.reverse(Agent.get(ids, fn l -> l end)) == [100, 101]
    end

    test "rollout_id is absent from the LM request map" do
      pid = self()
      Dspy.configure(lm: %RawCapturingLM{pid: pid})

      Dspy.Settings.context([rollout_id: 42, temperature: 0.7], fn ->
        assert {:ok, _} = Dspy.LM.generate(%{messages: [%{role: "user", content: "hi"}]})
      end)

      assert_receive {:raw, request}
      refute Map.has_key?(request, :rollout_id)
      refute Map.has_key?(request, "rollout_id")
    end

    test "with cache enabled, N attempts produce N distinct LM calls" do
      # Deterministic-per-request counting LM through Dspy.Predict: without
      # rollout-aware caching, attempts 2..N would be cache hits (the request
      # map is identical). rollout_id in the cache key keeps them distinct.
      {:ok, calls} = start_calls_agent()
      lm = %CountingLM{pid: self(), calls: calls, answers: ["a"]}
      Dspy.configure(lm: lm, cache: true)
      program = Dspy.Predict.new(TestQA)

      bon =
        Dspy.BestOfN.new(program,
          n: 3,
          threshold: 1.0,
          reward_fn: fn _inputs, _pred -> 0.0 end
        )

      assert {:ok, _} = Dspy.call(bon, %{question: "q"})

      assert_receive :lm_called, 50
      assert_receive :lm_called, 50
      assert_receive :lm_called, 50
      refute_receive :lm_called, 50
    end

    test "fail_count exceeded -> error tuple" do
      bon =
        Dspy.BestOfN.new(%AlwaysErrorProgram{},
          n: 5,
          threshold: 1.0,
          fail_count: 2,
          reward_fn: fn _, _ -> 1.0 end
        )

      assert {:error, {:best_of_n_failed, meta}} = Dspy.call(bon, %{question: "q"})
      assert meta.failures == 3
      assert meta.last_error == :simulated_provider_down
      assert meta.attempts == 3
    end

    test "all attempts failing with a high fail_count returns no_successful_attempts" do
      bon =
        Dspy.BestOfN.new(%AlwaysErrorProgram{},
          n: 2,
          threshold: 1.0,
          fail_count: 2,
          reward_fn: fn _, _ -> 1.0 end
        )

      assert {:error, {:no_successful_attempts, acc}} = Dspy.call(bon, %{question: "q"})
      assert acc.failures == 2
      assert acc.best_pred == nil
    end

    test "reward_fn raising is counted as a failure" do
      {:ok, calls} = start_calls_agent()
      lm = %CountingLM{pid: self(), calls: calls, answers: ["a"]}
      Dspy.configure(lm: lm)
      program = Dspy.Predict.new(TestQA)

      bon =
        Dspy.BestOfN.new(program,
          n: 2,
          threshold: 1.0,
          fail_count: 2,
          reward_fn: fn _inputs, _pred -> raise "reward exploded" end
        )

      assert {:error, {:no_successful_attempts, acc}} = Dspy.call(bon, %{question: "q"})
      assert acc.failures == 2
      assert {:raised, %{message: "reward exploded", module: RuntimeError}} = acc.last_error
    end
  end
end
