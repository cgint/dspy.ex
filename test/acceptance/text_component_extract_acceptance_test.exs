defmodule Dspy.Acceptance.TextComponentExtractAcceptanceTest do
  use ExUnit.Case, async: false

  alias Dspy.Teleprompt.LabeledFewShot

  defmodule GrammaticalComponent do
    @moduledoc false

    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{
        component_type: string(enum: ["subject", "verb", "object", "modifier"]),
        extracted_text: string()
      },
      required: [:component_type, :extracted_text],
      additionalProperties: false
    })
  end

  defmodule GrammaticalComponentsResult do
    @moduledoc false

    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{
        components: array_of(GrammaticalComponent)
      },
      required: [:components],
      additionalProperties: false
    })
  end

  defmodule GrammaticalComponentsSignature do
    use Dspy.Signature

    signature_instructions(
      "Return outputs as JSON with key extracted_components: an object with key components: a list of objects with keys " <>
        "component_type and extracted_text. extracted_text must be an exact substring of the input text."
    )

    input_field(:text, :string, "Sentence to analyze")

    # Mirrors python dspy-intro: `extracted_components: GrammaticalComponentsResult = OutputField()`
    output_field(:extracted_components, :json, "Typed grammatical components",
      schema: GrammaticalComponentsResult
    )
  end

  defmodule ComponentsMockLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      [%{content: prompt} | _] = request.messages

      # We treat presence of the training examples in the prompt as the signal
      # that the program was compiled with LabeledFewShot.
      has_examples? =
        String.contains?(prompt, "My grandmother baked delicious cookies yesterday.") or
          String.contains?(prompt, "Example 1:")

      # Note: prompts may contain many "Text:" occurrences due to examples.
      # We want the *current* input section, which is the last one.
      text =
        prompt
        |> String.split("Text:")
        |> List.last()
        |> String.split("\n", parts: 2)
        |> List.first()
        |> String.trim()

      send(pid, {:lm_seen, %{has_examples?: has_examples?, text: text}})

      components =
        if not has_examples? do
          []
        else
          case text do
            "The curious cat quietly watched the birds from the window." ->
              [
                %{"component_type" => "subject", "extracted_text" => "The curious cat"},
                %{"component_type" => "verb", "extracted_text" => "watched"},
                %{"component_type" => "object", "extracted_text" => "the birds"},
                %{"component_type" => "modifier", "extracted_text" => "quietly"},
                %{"component_type" => "modifier", "extracted_text" => "from the window"}
              ]

            "My grandmother baked delicious cookies yesterday." ->
              [
                %{"component_type" => "subject", "extracted_text" => "My grandmother"},
                %{"component_type" => "verb", "extracted_text" => "baked"},
                %{"component_type" => "object", "extracted_text" => "delicious cookies"},
                %{"component_type" => "modifier", "extracted_text" => "yesterday"}
              ]

            _ ->
              []
          end
        end

      payload = %{"extracted_components" => %{"components" => components}}

      content = "```json\n" <> Jason.encode!(payload) <> "\n```"

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
    Dspy.configure(lm: %ComponentsMockLM{pid: self()})
    :ok
  end

  defp drain_lm_seen(acc \\ []) do
    receive do
      {:lm_seen, msg} -> drain_lm_seen([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp component_set(components) when is_list(components) do
    components
    |> Enum.map(fn
      %{"component_type" => t, "extracted_text" => txt} -> {t, txt}
      %{component_type: t, extracted_text: txt} -> {t, txt}
    end)
    |> MapSet.new()
  end

  test "ports dspy-intro text_component_extract/*: structured extraction + LabeledFewShot improvement" do
    student = Dspy.Predict.new(GrammaticalComponentsSignature)

    trainset = [
      Dspy.Example.new(%{
        text: "My grandmother baked delicious cookies yesterday.",
        extracted_components: %GrammaticalComponentsResult{
          components: [
            %GrammaticalComponent{component_type: "subject", extracted_text: "My grandmother"},
            %GrammaticalComponent{component_type: "verb", extracted_text: "baked"},
            %GrammaticalComponent{component_type: "object", extracted_text: "delicious cookies"},
            %GrammaticalComponent{component_type: "modifier", extracted_text: "yesterday"}
          ]
        }
      }),
      Dspy.Example.new(%{
        text: "The curious cat quietly watched the birds from the window.",
        extracted_components: %GrammaticalComponentsResult{
          components: [
            %GrammaticalComponent{component_type: "subject", extracted_text: "The curious cat"},
            %GrammaticalComponent{component_type: "verb", extracted_text: "watched"},
            %GrammaticalComponent{component_type: "object", extracted_text: "the birds"},
            %GrammaticalComponent{component_type: "modifier", extracted_text: "quietly"},
            %GrammaticalComponent{component_type: "modifier", extracted_text: "from the window"}
          ]
        }
      })
    ]

    evalset = [
      Dspy.Example.new(%{
        text: "The curious cat quietly watched the birds from the window.",
        expected_components_json:
          Jason.encode!([
            %{"component_type" => "subject", "extracted_text" => "The curious cat"},
            %{"component_type" => "verb", "extracted_text" => "watched"},
            %{"component_type" => "object", "extracted_text" => "the birds"},
            %{"component_type" => "modifier", "extracted_text" => "quietly"},
            %{"component_type" => "modifier", "extracted_text" => "from the window"}
          ])
      })
    ]

    metric = fn example, prediction ->
      expected = example.attrs.expected_components_json |> Jason.decode!() |> component_set()

      %GrammaticalComponentsResult{components: got_components} =
        prediction.attrs.extracted_components

      got = component_set(got_components)
      if expected == got, do: 1.0, else: 0.0
    end

    _ = drain_lm_seen()

    baseline = Dspy.Evaluate.evaluate(student, evalset, metric, num_threads: 1, progress: false)
    assert baseline.mean == 0.0

    assert_receive {:lm_seen, baseline_seen}, 2_000
    _ = drain_lm_seen()
    assert baseline_seen.has_examples? == false

    tp =
      LabeledFewShot.new(
        k: 2,
        seed: 123,
        selection_strategy: :random,
        include_reasoning: false
      )

    assert {:ok, optimized} = LabeledFewShot.compile(tp, student, trainset)

    # Sanity-check: the compiled program runs and produces the correct structured output.
    sentence = "The curious cat quietly watched the birds from the window."

    expected_components = [
      %{"component_type" => "subject", "extracted_text" => "The curious cat"},
      %{"component_type" => "verb", "extracted_text" => "watched"},
      %{"component_type" => "object", "extracted_text" => "the birds"},
      %{"component_type" => "modifier", "extracted_text" => "quietly"},
      %{"component_type" => "modifier", "extracted_text" => "from the window"}
    ]

    assert {:ok, pred} = Dspy.Module.forward(optimized, %{text: sentence})

    assert %GrammaticalComponentsResult{components: pred_components} =
             pred.attrs.extracted_components

    assert component_set(pred_components) == component_set(expected_components)

    _ = drain_lm_seen()

    improved = Dspy.Evaluate.evaluate(optimized, evalset, metric, num_threads: 1, progress: false)

    assert_receive {:lm_seen, improved_seen}, 2_000
    _ = drain_lm_seen()

    assert improved_seen.has_examples? == true
    assert improved_seen.text == sentence

    assert improved.mean == 1.0
  end
end
