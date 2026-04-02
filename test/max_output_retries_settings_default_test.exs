defmodule Dspy.MaxOutputRetriesSettingsDefaultTest do
  use ExUnit.Case, async: false

  @moduledoc false

  defmodule Sig do
    @moduledoc false

    use Dspy.Signature

    input_field(:context_json, :string, "Context")
    output_field(:output_json, :string, "Output JSON")
  end

  defmodule RetryMockLM do
    @moduledoc false

    @behaviour Dspy.LM

    defstruct [:counter]

    @impl true
    def generate(%__MODULE__{counter: counter} = _lm, _request) do
      call_num = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

      content =
        if call_num == 1 do
          ~s({"speech_text":"hi"})
        else
          ~s(Output_json: {"speech_text":"hi"})
        end

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    %{counter: counter}
  end

  test "Predict defaults max_output_retries from Dspy.Settings when not provided", %{
    counter: counter
  } do
    Dspy.configure(lm: %RetryMockLM{counter: counter}, max_output_retries: 1)

    # NOTE: no max_output_retries option passed here.
    program = Dspy.Predict.new(Sig, max_retries: 0)

    assert {:ok, pred} = Dspy.Module.forward(program, %{context_json: "{}"})
    assert pred.attrs.output_json =~ "speech_text"

    assert Agent.get(counter, & &1) == 2
  end
end
