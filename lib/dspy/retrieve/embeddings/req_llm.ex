defmodule Dspy.Retrieve.Embeddings.ReqLLM do
  @moduledoc """
  Embedding provider backed by `req_llm`.

  This is a provider-agnostic way to generate embeddings without baking provider
  HTTP quirks into `:dspy`.

  The underlying call is delegated to `ReqLLM.embed/3`.

  ## Options

  - `:model` (required for non-empty inputs) - model spec string, e.g. `"openai:text-embedding-3-small"`
  - `:req_llm` (optional) - module implementing `embed/3` (defaults to `ReqLLM`)

  Any additional options are passed through to `ReqLLM.embed/3` (e.g. `:dimensions`).

  ## Determinism note

  Real embedding models are not suitable for deterministic unit tests.
  In tests, pass a fake `:req_llm` module.
  """

  alias Dspy.Retrieve.EmbeddingProvider

  @behaviour EmbeddingProvider

  @impl true
  def embed_text(text, opts \\ [])

  def embed_text(text, opts) when is_binary(text) and is_list(opts) do
    with {:ok, embedding} <- request_embedding(text, opts, :invalid_embedding),
         :ok <- EmbeddingProvider.validate_vector(embedding) do
      {:ok, embedding}
    end
  end

  def embed_text(_text, _opts), do: {:error, :invalid_text}

  @impl true
  def embed_batch(texts, opts \\ [])

  def embed_batch(texts, opts) when is_integer(length(texts)) and is_list(opts) do
    cond do
      texts == [] ->
        {:ok, []}

      not Enum.all?(texts, &is_binary/1) ->
        {:error, :invalid_texts}

      true ->
        with {:ok, embeddings} <- request_embedding(texts, opts, :invalid_embeddings),
             :ok <- EmbeddingProvider.validate_batch(embeddings, length(texts)) do
          {:ok, embeddings}
        end
    end
  end

  def embed_batch(_texts, _opts), do: {:error, :invalid_texts}

  defp request_embedding(input, opts, invalid_reason) do
    {req_llm, opts} = Keyword.pop(opts, :req_llm, ReqLLM)

    with {:ok, model} <- fetch_model_opt(opts) do
      case req_llm.embed(model, input, Keyword.delete(opts, :model)) do
        {:ok, _} = result -> result
        {:error, _} = error -> error
        other -> {:error, {invalid_reason, other}}
      end
    end
  end

  defp fetch_model_opt(opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} when is_binary(model) and model != "" -> {:ok, model}
      {:ok, _} -> {:error, :invalid_model}
      :error -> {:error, :model_required}
    end
  end
end
