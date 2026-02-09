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

  @behaviour Dspy.Retrieve.EmbeddingProvider

  @impl true
  def embed_text(text, opts \\ [])

  def embed_text(text, opts) when is_binary(text) and is_list(opts) do
    {req_llm, opts} = Keyword.pop(opts, :req_llm, ReqLLM)

    with {:ok, model} <- fetch_model_opt(opts) do
      opts = Keyword.delete(opts, :model)

      with {:ok, embedding} <- req_llm.embed(model, text, opts),
           :ok <- validate_embedding_vector(embedding) do
        {:ok, embedding}
      end
    end
  end

  def embed_text(_text, _opts), do: {:error, :invalid_text}

  @impl true
  def embed_batch(texts, opts \\ [])

  def embed_batch(texts, opts) when is_list(texts) and is_list(opts) do
    cond do
      texts == [] ->
        {:ok, []}

      not Enum.all?(texts, &is_binary/1) ->
        {:error, :invalid_texts}

      true ->
        {req_llm, opts} = Keyword.pop(opts, :req_llm, ReqLLM)

        with {:ok, model} <- fetch_model_opt(opts) do
          opts = Keyword.delete(opts, :model)

          with {:ok, embeddings} <- req_llm.embed(model, texts, opts),
               :ok <- validate_embedding_matrix(embeddings) do
            {:ok, embeddings}
          end
        end
    end
  end

  def embed_batch(_texts, _opts), do: {:error, :invalid_texts}

  defp fetch_model_opt(opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} when is_binary(model) and model != "" -> {:ok, model}
      {:ok, _} -> {:error, :invalid_model}
      :error -> {:error, :model_required}
    end
  end

  defp validate_embedding_vector(list) when is_list(list) do
    if Enum.all?(list, &is_number/1) do
      :ok
    else
      {:error, {:invalid_embedding, list}}
    end
  end

  defp validate_embedding_vector(other), do: {:error, {:invalid_embedding, other}}

  defp validate_embedding_matrix(list) when is_list(list) do
    has_vectors? = Enum.all?(list, &match?([_ | _], &1))
    all_numbers? = Enum.all?(list, fn vec -> Enum.all?(vec, fn x -> is_number(x) end) end)

    if has_vectors? and all_numbers? do
      :ok
    else
      {:error, {:invalid_embeddings, list}}
    end
  end

  defp validate_embedding_matrix(other), do: {:error, {:invalid_embeddings, other}}
end
