defmodule Dspy.TypedOutputRetryTest do
  use ExUnit.Case, async: false

  defmodule AnswerSchema do
    @moduledoc false

    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{answer: string()},
      required: [:answer],
      additionalProperties: false
    })
  end

  defmodule TypedAnswerSignature do
    @moduledoc false

    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:result, :json, "Typed result", schema: AnswerSchema)
  end

  defmodule RetryMockLM do
    @moduledoc false

    @behaviour Dspy.LM

    defstruct [:counter, :pid, :mode]

    @impl true
    def generate(%__MODULE__{counter: counter, pid: pid, mode: mode}, request) do
      call_num = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

      [%{content: prompt} | _rest] = request.messages

      send(pid, {:lm_call, %{call: call_num, prompt: prompt}})

      content = response_content(mode, call_num)

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    defp response_content(:invalid_then_valid, 1), do: ~s({"result": {"not_answer": "42"}})
    defp response_content(:invalid_then_valid, _n), do: ~s({"result": {"answer": "42"}})

    defp response_content(:decode_then_valid, 1), do: "Result: 42"
    defp response_content(:decode_then_valid, _n), do: ~s({"result": {"answer": "42"}})

    defp response_content(:always_invalid, _n), do: ~s({"result": {"not_answer": "42"}})

    defp response_content(:cot_invalid_then_valid, 1),
      do: ~s({"reasoning": "ok", "result": {"not_answer": "42"}})

    defp response_content(:cot_invalid_then_valid, _n),
      do: ~s({"reasoning": "ok", "result": {"answer": "42"}})

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

  test "Predict: retries on typed-output validation failure and succeeds within max_output_retries",
       %{counter: counter} do
    Dspy.configure(lm: %RetryMockLM{counter: counter, pid: self(), mode: :invalid_then_valid})

    program = Dspy.Predict.new(TypedAnswerSignature, max_retries: 0, max_output_retries: 1)

    assert {:ok, pred} = Dspy.Module.forward(program, %{question: "?"})
    assert %AnswerSchema{answer: "42"} = pred.attrs.result

    assert Agent.get(counter, & &1) == 2

    calls = drain_lm_calls()
    assert length(calls) == 2

    second_prompt = calls |> Enum.at(1) |> Map.fetch!(:prompt)

    assert second_prompt =~ "JSON Schema for result:"
    assert second_prompt =~ "Return JSON only"
    assert second_prompt =~ "Errors:"
  end

  test "Predict: retries on typed-output decode failure (non-JSON first) and succeeds",
       %{counter: counter} do
    Dspy.configure(lm: %RetryMockLM{counter: counter, pid: self(), mode: :decode_then_valid})

    program = Dspy.Predict.new(TypedAnswerSignature, max_retries: 0, max_output_retries: 1)

    assert {:ok, pred} = Dspy.Module.forward(program, %{question: "?"})
    assert %AnswerSchema{answer: "42"} = pred.attrs.result

    assert Agent.get(counter, & &1) == 2
  end

  test "Predict: stops after N output retries and returns the final structured error",
       %{counter: counter} do
    Dspy.configure(lm: %RetryMockLM{counter: counter, pid: self(), mode: :always_invalid})

    program = Dspy.Predict.new(TypedAnswerSignature, max_retries: 0, max_output_retries: 2)

    assert {:error, {:output_validation_failed, %{field: :result, errors: errors}}} =
             Dspy.Module.forward(program, %{question: "?"})

    assert is_list(errors) and errors != []

    # 1 initial attempt + 2 retries
    assert Agent.get(counter, & &1) == 3
  end

  test "ChainOfThought: retries on typed-output validation failure and succeeds",
       %{counter: counter} do
    Dspy.configure(lm: %RetryMockLM{counter: counter, pid: self(), mode: :cot_invalid_then_valid})

    program =
      Dspy.ChainOfThought.new(TypedAnswerSignature,
        max_retries: 0,
        max_output_retries: 1
      )

    assert {:ok, pred} = Dspy.Module.forward(program, %{question: "?"})

    assert is_binary(pred.attrs.reasoning)
    assert %AnswerSchema{answer: "42"} = pred.attrs.result

    assert Agent.get(counter, & &1) == 2
  end
end
