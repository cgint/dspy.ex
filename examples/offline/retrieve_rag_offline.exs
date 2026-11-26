# Offline retrieval and generation using an immutable embeddings index.
# Run: mix run examples/offline/retrieve_rag_offline.exs

defmodule RetrieveRAGOfflineDemo do
  defmodule OfflineLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok, %{choices: [%{message: %{role: "assistant", content: "Cats are great."}}]}}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  def run do
    embed = fn texts ->
      Enum.map(texts, fn text ->
        if String.contains?(String.downcase(text), "cats"), do: [1.0, 0.0], else: [0.0, 1.0]
      end)
    end

    embedder = Dspy.Embedder.new(embed)

    {:ok, index} =
      Dspy.Embeddings.new(["Cats are great.", "Dogs are also great."], embedder, k: 1)

    {:ok, prediction} = Dspy.Embeddings.query(index, "Tell me about cats")
    context = Enum.join(prediction.attrs.passages, "\n")

    request = %{
      messages: [Dspy.LM.user_message("Context: #{context}\nQuestion: Tell me about cats")]
    }

    {:ok, response} = Dspy.LM.generate(%OfflineLM{}, request)
    {:ok, answer} = Dspy.LM.text_from_response(response)
    IO.puts("Answer: #{answer}\nContext: #{context}")
  end
end

RetrieveRAGOfflineDemo.run()
