defmodule Dspy.LM.RequestDefaultsTest do
  use ExUnit.Case, async: false

  defmodule CapturingLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      send(pid, {:lm_request, request})

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
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "generate/1 applies Settings defaults for max_tokens + temperature when missing" do
    Dspy.configure(lm: %CapturingLM{pid: self()}, max_tokens: 9, temperature: 0.7)

    assert {:ok, _resp} =
             Dspy.LM.generate(%{messages: [%{role: "user", content: "hi"}]})

    assert_receive {:lm_request, request}

    assert request[:max_tokens] == 9
    assert request[:temperature] == 0.7
  end

  test "generate/1 respects per-request overrides (override temperature, inherit max_tokens)" do
    Dspy.configure(lm: %CapturingLM{pid: self()}, max_tokens: 11, temperature: 0.7)

    assert {:ok, _resp} =
             Dspy.LM.generate(%{
               messages: [%{role: "user", content: "hi"}],
               temperature: 0.1
             })

    assert_receive {:lm_request, request}

    assert request[:max_tokens] == 11
    assert request[:temperature] == 0.1
  end

  test "generate/2 respects per-request overrides (override max_tokens, inherit temperature)" do
    lm = %CapturingLM{pid: self()}
    Dspy.configure(lm: lm, max_tokens: 11, temperature: 0.7)

    assert {:ok, _resp} =
             Dspy.LM.generate(lm, %{messages: [%{role: "user", content: "hi"}], max_tokens: 3})

    assert_receive {:lm_request, request}

    assert request[:max_tokens] == 3
    assert request[:temperature] == 0.7
  end
end
