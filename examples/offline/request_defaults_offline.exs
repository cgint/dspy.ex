# Offline, deterministic *debug* demo of Settings defaults applied to request maps.
#
# This example exists to make it easy to *see* what Dspy forwards into the LM request map
# after applying `Dspy.configure/1` defaults.
#
# IMPORTANT:
# - The small token limits used below are chosen to make the inspected request maps easy
#   to read. They are *not* recommended defaults for real usage.
# - For real programs (Predict/ChainOfThought/ReAct/tools), prefer leaving token limits
#   unset (provider defaults) or using a generous limit to avoid truncation.
#
# Run:
#   mix run examples/request_defaults_offline.exs


defmodule RequestDefaultsOfflineDemo do
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

  def run do
    lm = %CapturingLM{pid: self()}

    # Note: in real usage you typically set *either* :max_tokens or :max_completion_tokens
    # depending on your provider/model family. This example sets both to demonstrate that
    # both keys are supported and propagate into request maps.
    Dspy.configure(
      lm: lm,
      temperature: 0.7,
      max_tokens: 9,
      max_completion_tokens: 17
    )

    {:ok, _resp} = Dspy.LM.generate(%{messages: [%{role: "user", content: "hi"}]})

    receive do
      {:lm_request, request1} ->
        IO.puts("Request #1 (defaults applied):")
        IO.inspect(request1)
    after
      1_000 ->
        raise "expected request #1"
    end

    {:ok, _resp} =
      Dspy.LM.generate(%{
        messages: [%{role: "user", content: "hi"}],
        temperature: 0.1,
        max_tokens: 3
      })

    receive do
      {:lm_request, request2} ->
        IO.puts("\nRequest #2 (override temperature + max_tokens; inherit max_completion_tokens):")
        IO.inspect(request2)
    after
      1_000 ->
        raise "expected request #2"
    end

    {:ok, _resp} =
      Dspy.LM.generate(%{
        messages: [%{role: "user", content: "hi"}],
        max_completion_tokens: 5
      })

    receive do
      {:lm_request, request3} ->
        IO.puts("\nRequest #3 (override max_completion_tokens; inherit others):")
        IO.inspect(request3)
    after
      1_000 ->
        raise "expected request #3"
    end

    :ok
  end
end

RequestDefaultsOfflineDemo.run()
