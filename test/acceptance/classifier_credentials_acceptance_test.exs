defmodule Dspy.Acceptance.ClassifierCredentialsAcceptanceTest do
  use ExUnit.Case

  defmodule CredentialsSignature do
    use Dspy.Signature

    signature_description("Classify whether a message contains credentials")

    signature_instructions(
      "Classify the input as safe or unsafe. Output must be exactly one of: safe, unsafe."
    )

    input_field(:text, :string, "Message text")
    output_field(:safety, :string, "safety label", one_of: ["safe", "unsafe"])
  end

  defmodule MockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
      [%{content: prompt} | _] = request.messages

      # Extremely dumb heuristic; good enough to port the workflow deterministically.
      content =
        cond do
          String.contains?(prompt, "password") or String.contains?(prompt, "API_KEY") ->
            "Safety: unsafe"

          true ->
            "Safety: safe"
        end

      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: content}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule BadLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _req) do
      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: "Safety: maybe"}}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %MockLM{})
    :ok
  end

  test "ports dspy-intro classifier_credentials/*: constrained output classification" do
    classifier = Dspy.Predict.new(CredentialsSignature)

    assert {:ok, pred1} = Dspy.Module.forward(classifier, %{text: "hello world"})
    assert pred1.attrs.safety == "safe"

    assert {:ok, pred2} = Dspy.Module.forward(classifier, %{text: "my password is 123"})
    assert pred2.attrs.safety == "unsafe"

    prompt = Dspy.Signature.to_prompt(CredentialsSignature.signature())

    assert prompt =~ "Output Fields:"
    assert prompt =~ "safety"
    assert prompt =~ "one of: safe, unsafe"
  end

  test "rejects outputs not in the allowed set" do
    Dspy.configure(lm: %BadLM{})

    classifier = Dspy.Predict.new(CredentialsSignature)

    assert {:error, {:invalid_output_value, :safety, {:not_in_allowed_set, ["safe", "unsafe"]}}} =
             Dspy.Module.forward(classifier, %{text: "hello"})
  end
end
