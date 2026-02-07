defmodule Dspy.Acceptance.ClassifierCredentialsJsonAcceptanceTest do
  use ExUnit.Case

  defmodule CredentialsSignature do
    use Dspy.Signature

    signature_instructions(
      "Return outputs as JSON with key safety. safety must be one of: safe, unsafe."
    )

    input_field(:text, :string, "Message text")
    output_field(:safety, :string, "safety label", one_of: ["safe", "unsafe"])
  end

  defmodule JsonLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _req) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "```json\n{\"safety\": \"unsafe\"}\n```"}}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule BadJsonLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _req) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "```json\n{\"safety\": \"maybe\"}\n```"}}
         ],
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

  test "constrained outputs are enforced for JSON outputs too (decoded JSON types)" do
    Dspy.configure(lm: %JsonLM{})

    classifier = Dspy.Predict.new(CredentialsSignature)
    assert {:ok, pred} = Dspy.Module.forward(classifier, %{text: "pw"})
    assert pred.attrs.safety == "unsafe"

    Dspy.configure(lm: %BadJsonLM{})

    assert {:error, {:invalid_output_value, :safety, {:not_in_allowed_set, ["safe", "unsafe"]}}} =
             Dspy.Module.forward(classifier, %{text: "pw"})
  end
end
