defmodule Dspy.Acceptance.JsonOutputsAcceptanceTest do
  use ExUnit.Case

  defmodule JokeWithRatingSignature do
    use Dspy.Signature

    signature_instructions(
      "Return your final outputs as a JSON object with keys: joke, funnyness_0_to_10."
    )

    input_field(:name, :string, "Name to write a joke about")

    output_field(:joke, :string, "joke text")
    output_field(:funnyness_0_to_10, :integer, "funnyness rating from 0 to 10")
  end

  defmodule JsonMockLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      [%{content: prompt} | _rest] = request.messages
      send(pid, {:prompt, prompt})

      # Simulate Python DSPy with JSONAdapter: return a JSON object instead of label-formatted fields.
      content =
        cond do
          prompt =~ "Name: John" ->
            "```json\n{\"joke\": \"Why did John cross the road? To get to the other side.\", \"funnyness_0_to_10\": 7}\n```"

          true ->
            "```json\n{\"joke\": \"(fallback)\", \"funnyness_0_to_10\": 0}\n```"
        end

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: content},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %JsonMockLM{pid: self()})
    :ok
  end

  test "ports dspy-intro simplest/simplest_dspy_with_signature_onefile.py: JSON-ish structured outputs" do
    predictor = Dspy.Predict.new(JokeWithRatingSignature)

    assert {:ok, prediction} = Dspy.Module.forward(predictor, %{name: "John"})

    assert prediction.attrs.joke =~ "John"
    assert prediction.attrs.funnyness_0_to_10 == 7

    assert_receive {:prompt, prompt}, 1_000

    # Prompt should include signature-provided instructions.
    assert prompt =~ "Instructions:"
    assert prompt =~ "Return your final outputs as a JSON object"

    assert prompt =~ "Name: John"
  end
end
