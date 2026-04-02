defmodule Dspy.UntypedOutputRetryDefaultAdapterTest do
  use ExUnit.Case, async: false

  @moduledoc false

  defmodule SummarizeSignature do
    @moduledoc false

    use Dspy.Signature

    input_field(
      :context_json,
      :string,
      "JSON payload with target agent answer, session context, and related OpenSpec context"
    )

    output_field(
      :output_json,
      :string,
      "JSON object with speech_text, focus_points, and used_open_spec_change_ids"
    )
  end

  defmodule RetryMockLM do
    @moduledoc false

    @behaviour Dspy.LM

    defstruct [:counter, :pid, :mode]

    @impl true
    def generate(%__MODULE__{counter: counter, pid: pid, mode: mode}, request) do
      call_num = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

      prompt = extract_user_prompt(request)

      send(pid, {:lm_call, %{call: call_num, prompt: prompt}})

      content = response_content(mode, call_num)

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    defp extract_user_prompt(%{messages: messages}) when is_list(messages) do
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn msg ->
        role = Map.get(msg, :role) || Map.get(msg, "role")
        content = Map.get(msg, :content) || Map.get(msg, "content")

        if role == "user" and is_binary(content), do: content, else: nil
      end)
      |> case do
        nil -> ""
        prompt -> prompt
      end
    end

    defp response_content(:inner_json_then_label, 1) do
      ~s({"speech_text":"hi","focus_points":["a"],"used_open_spec_change_ids":[]})
    end

    defp response_content(:inner_json_then_label, _n) do
      ~s(Output_json: {"speech_text":"hi","focus_points":["a"],"used_open_spec_change_ids":[]})
    end

    defp response_content(:always_inner_json, _n) do
      ~s({"speech_text":"hi","focus_points":["a"],"used_open_spec_change_ids":[]})
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    %{counter: counter}
  end

  defp drain_lm_calls(acc \\ []) do
    receive do
      {:lm_call, msg} -> drain_lm_calls([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "Predict(Default): retries on missing_required_outputs for untyped output_json and succeeds",
       %{counter: counter} do
    Dspy.configure(lm: %RetryMockLM{counter: counter, pid: self(), mode: :inner_json_then_label})

    program = Dspy.Predict.new(SummarizeSignature, max_retries: 0, max_output_retries: 1)

    assert {:ok, pred} = Dspy.Module.forward(program, %{context_json: "{}"})

    assert is_binary(pred.attrs.output_json)
    assert pred.attrs.output_json =~ "speech_text"

    assert Agent.get(counter, & &1) == 2

    calls = drain_lm_calls()
    assert length(calls) == 2

    second_prompt = calls |> Enum.at(1) |> Map.fetch!(:prompt)

    assert second_prompt =~ "Output_json"
    assert second_prompt =~ "missing required output"
  end

  test "Predict(Default): stops after N output retries and returns missing_required_outputs",
       %{counter: counter} do
    Dspy.configure(lm: %RetryMockLM{counter: counter, pid: self(), mode: :always_inner_json})

    program = Dspy.Predict.new(SummarizeSignature, max_retries: 0, max_output_retries: 1)

    assert {:error, {:missing_required_outputs, [:output_json]}} =
             Dspy.Module.forward(program, %{context_json: "{}"})

    # 1 initial attempt + 1 retry
    assert Agent.get(counter, & &1) == 2
  end

  test "Predict(Default): does not retry when max_output_retries is 0",
       %{counter: counter} do
    Dspy.configure(lm: %RetryMockLM{counter: counter, pid: self(), mode: :inner_json_then_label})

    program = Dspy.Predict.new(SummarizeSignature, max_retries: 0, max_output_retries: 0)

    assert {:error, {:missing_required_outputs, [:output_json]}} =
             Dspy.Module.forward(program, %{context_json: "{}"})

    assert Agent.get(counter, & &1) == 1
  end
end
