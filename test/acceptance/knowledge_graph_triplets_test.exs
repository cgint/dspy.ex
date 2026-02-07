defmodule Dspy.Acceptance.KnowledgeGraphTripletsTest do
  use ExUnit.Case

  defmodule TripletExtractionSignature do
    use Dspy.Signature

    signature_description("Extract knowledge-graph triplets from text")

    signature_instructions(
      "Return JSON with key triplets: a list of {subject, predicate, object} maps. " <>
        "Use existing_triplets as context to avoid duplicates and relate new facts."
    )

    input_field(:text, :string, "Source text to analyze")

    input_field(:existing_triplets, :string, "Previously extracted triplets as JSON",
      required: false,
      default: "[]"
    )

    output_field(:triplets, :json, "List of extracted triplets")
  end

  defmodule TripletMockLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      [%{content: prompt} | _] = request.messages
      send(pid, {:prompt, prompt})

      # This mock is intentionally dumb and deterministic. It simulates:
      # - chunk-wise extraction
      # - reuse of `existing_triplets` (so later chunks can add relations)
      content =
        cond do
          prompt =~ "Text: Linear is a communication tool." ->
            """
            ```json
            {"triplets": [
              {"subject": "Linear", "predicate": "is", "object": "a communication tool"},
              {"subject": "Linear", "predicate": "provides", "object": "custom instructions"}
            ]}
            ```
            """

          prompt =~ "Text: Humans maintain ownership" and prompt =~ "existing_triplets" ->
            """
            ```json
            {"triplets": [
              {"subject": "Humans", "predicate": "maintain", "object": "ownership"},
              {"subject": "Humans", "predicate": "delegate", "object": "tasks to AI agents"},
              {"subject": "AI agents", "predicate": "support", "object": "Linear"}
            ]}
            ```
            """

          true ->
            """
            ```json
            {"triplets": []}
            ```
            """
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
    Dspy.configure(lm: %TripletMockLM{pid: self()})
    :ok
  end

  defp chunk_text(text) do
    text
    |> String.split("\n\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp dedupe_triplets(triplets) when is_list(triplets) do
    triplets
    |> Enum.uniq_by(fn t ->
      {Map.get(t, "subject"), Map.get(t, "predicate"), Map.get(t, "object")}
    end)
  end

  test "ports dspy-intro knowledge_graph/*: extract triplets chunk-by-chunk and reuse existing_triplets" do
    extractor = Dspy.Predict.new(TripletExtractionSignature)

    doc = """
    Linear is a communication tool. Linear provides custom instructions.

    Humans maintain ownership while delegating tasks to AI agents.
    """

    chunks = chunk_text(doc)
    assert length(chunks) == 2

    all_triplets =
      Enum.reduce(chunks, [], fn chunk, acc_triplets ->
        existing_json = Jason.encode!(acc_triplets)

        assert {:ok, pred} =
                 Dspy.Module.forward(extractor, %{text: chunk, existing_triplets: existing_json})

        triplets = pred.attrs.triplets
        assert is_list(triplets)

        dedupe_triplets(acc_triplets ++ triplets)
      end)

    # A few spot checks that demonstrate we got structured triplets and reused context.
    assert Enum.any?(all_triplets, &(&1["subject"] == "Linear" and &1["predicate"] == "provides"))
    assert Enum.any?(all_triplets, &(&1["subject"] == "Humans" and &1["predicate"] == "delegate"))

    assert Enum.any?(
             all_triplets,
             &(&1["subject"] == "AI agents" and &1["predicate"] == "support")
           )

    # Prompt contains our instructions + both input fields (including existing_triplets context).
    assert_receive {:prompt, prompt1}, 1_000
    assert_receive {:prompt, prompt2}, 1_000

    prompt = prompt1 <> "\n\n" <> prompt2
    assert prompt =~ "Instructions:"
    assert prompt =~ "Return JSON with key triplets"
    assert prompt =~ "existing_triplets"
  end

  test "Evaluate can score a triplet extractor deterministically" do
    extractor = Dspy.Predict.new(TripletExtractionSignature)

    examples = [
      Dspy.Example.new(%{
        text: "Linear is a communication tool. Linear provides custom instructions.",
        existing_triplets: "[]",
        expected_triplets_json:
          Jason.encode!([
            %{"subject" => "Linear", "predicate" => "is", "object" => "a communication tool"},
            %{"subject" => "Linear", "predicate" => "provides", "object" => "custom instructions"}
          ])
      })
    ]

    metric = fn example, prediction ->
      triplet_set = fn triplets ->
        triplets
        |> dedupe_triplets()
        |> Enum.map(fn t ->
          {Map.get(t, "subject"), Map.get(t, "predicate"), Map.get(t, "object")}
        end)
        |> MapSet.new()
      end

      expected =
        example.attrs.expected_triplets_json
        |> Jason.decode!()
        |> triplet_set.()

      got = triplet_set.(prediction.attrs.triplets)

      if expected == got, do: 1.0, else: 0.0
    end

    result = Dspy.Evaluate.evaluate(extractor, examples, metric, num_threads: 1, progress: false)
    assert result.mean == 1.0
  end
end
