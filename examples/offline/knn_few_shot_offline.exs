# Run with `mix run examples/offline/knn_few_shot_offline.exs`.

defmodule KNNFewShotOffline do
  alias Dspy.{Embedder, Example, Predict, Prediction, Teleprompt}
  alias Dspy.Signature.Adapters.ChatAdapter

  defmodule DemoReaderLM do
    @behaviour Dspy.LM
    defstruct [:demos]

    @impl true
    def generate(lm, %{messages: messages}) do
      prompt = List.last(messages).content
      [_demo, query] = String.split(prompt, "Inputs:\n[[ ## question ## ]]\n", parts: 2)
      {question, answer} = Map.fetch!(lm.demos, query)

      expected_prompt =
        """
        Example 1:
        [[ ## question ## ]]
        #{question}

        [[ ## answer ## ]]
        #{answer}

        Inputs:
        [[ ## question ## ]]
        #{query}
        """
        |> String.trim_trailing()

      true = prompt == expected_prompt
      {:ok, "[[ ## answer ## ]]\n#{answer}"}
    end
  end

  def run do
    cases = [
      {"Which city is the French capital?", "What is the capital of France?", "Paris", [1, 0]},
      {"Name the playwright of Hamlet.", "Who wrote Hamlet?", "Shakespeare", [0, 1]}
    ]

    trainset =
      for {_query, question, answer, _vector} <- cases do
        Example.new(question: question, answer: answer) |> Example.with_inputs(:question)
      end

    vectors =
      for {query, question, _answer, vector} <- cases, text <- [query, question], into: %{} do
        {"question: #{text}", vector}
      end

    demos =
      for {query, question, answer, _vector} <- cases, into: %{}, do: {query, {question, answer}}

    embedder = Embedder.new(fn texts -> Enum.map(texts, &Map.fetch!(vectors, &1)) end)

    student =
      Predict.new("question -> answer", adapter: ChatAdapter, lm: %DemoReaderLM{demos: demos})

    # Use only the nearest labeled demo so the selection is visible in the prompt.
    optimizer =
      Teleprompt.new(:knn_few_shot, k: 1, vectorizer: embedder, max_bootstrapped_demos: 0)

    {:ok, program} = Teleprompt.compile(optimizer, student, trainset)

    for {query, question, answer, _vector} <- cases do
      {:ok, %Prediction{attrs: %{answer: ^answer}}} = Dspy.call(program, question: query)
      IO.puts("#{query} #{answer} (demo: #{question})")
    end
  end
end

KNNFewShotOffline.run()
