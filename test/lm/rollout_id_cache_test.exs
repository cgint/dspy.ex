defmodule Dspy.LM.RolloutIdCacheTest do
  # `async: false` — tests mutate global `Dspy.Settings` via `Dspy.configure/1`.
  use ExUnit.Case, async: false

  defmodule CountingLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      send(pid, {:lm_called, request})

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: "ok"}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.LM.Cache.clear()
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "nil rollout_id keeps the legacy cache key (identical requests still hit)" do
    lm = %CountingLM{pid: self()}
    Dspy.configure(lm: lm, cache: true)

    assert is_nil(Dspy.Settings.get(:rollout_id))

    request = %{messages: [%{role: "user", content: "hi"}]}

    assert {:ok, _} = Dspy.LM.generate(request)
    assert_receive {:lm_called, ^request}

    assert {:ok, _} = Dspy.LM.generate(request)
    refute_receive {:lm_called, _}, 50
  end

  test "distinct rollout_ids produce distinct cache entries" do
    lm = %CountingLM{pid: self()}
    Dspy.configure(lm: lm, cache: true)

    request = %{messages: [%{role: "user", content: "hi"}]}

    Dspy.Settings.context([rollout_id: 0], fn ->
      assert {:ok, _} = Dspy.LM.generate(request)
      assert_receive {:lm_called, ^request}
    end)

    Dspy.Settings.context([rollout_id: 1], fn ->
      assert {:ok, _} = Dspy.LM.generate(request)
      assert_receive {:lm_called, ^request}
    end)

    # Within a rollout the cache still works.
    Dspy.Settings.context([rollout_id: 0], fn ->
      assert {:ok, _} = Dspy.LM.generate(request)
      refute_receive {:lm_called, _}, 50
    end)
  end

  test "rollout_id never reaches the LM request map" do
    lm = %CountingLM{pid: self()}
    Dspy.configure(lm: lm, cache: false)

    Dspy.Settings.context([rollout_id: 7], fn ->
      request = %{messages: [%{role: "user", content: "hi"}]}
      assert {:ok, _} = Dspy.LM.generate(request)
      assert_receive {:lm_called, captured}
      refute Map.has_key?(captured, :rollout_id)
      refute Map.has_key?(captured, "rollout_id")
    end)
  end
end
