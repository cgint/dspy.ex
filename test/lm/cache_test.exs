defmodule Dspy.LM.CacheTest do
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
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "when cache is enabled, identical requests are served from cache" do
    lm = %CountingLM{pid: self()}
    Dspy.configure(lm: lm, cache: true)

    request = %{messages: [%{role: "user", content: "hi"}], max_tokens: 7}

    assert {:ok, _} = Dspy.LM.generate(request)
    assert_receive {:lm_called, ^request}

    assert {:ok, _} = Dspy.LM.generate(request)

    refute_receive {:lm_called, _}, 50
  end

  test "when cache is disabled, identical requests call the LM each time" do
    lm = %CountingLM{pid: self()}
    Dspy.configure(lm: lm, cache: false)

    request = %{messages: [%{role: "user", content: "hi"}], max_tokens: 7}

    assert {:ok, _} = Dspy.LM.generate(request)
    assert_receive {:lm_called, ^request}

    assert {:ok, _} = Dspy.LM.generate(request)
    assert_receive {:lm_called, ^request}
  end
end
