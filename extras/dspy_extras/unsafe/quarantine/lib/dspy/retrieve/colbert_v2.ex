defmodule Dspy.Retrieve.ColBERTv2 do
  @moduledoc """
  Search a configured ColBERTv2 server using `search/3`.

  The legacy retriever callbacks are placeholders. Use the value returned by
  `new/1` to run a remote search.
  """

  @behaviour Dspy.Retrieve.Retriever

  @timeout 10_000

  defstruct [
    :url,
    :collection,
    :port,
    :embedding_provider,
    :k,
    :search_port,
    post_requests: false
  ]

  def new(opts \\ []) do
    url = opts[:url]
    port = opts[:port] || 8893

    %__MODULE__{
      url: url || "http://localhost",
      collection: opts[:collection] || "default",
      port: port,
      embedding_provider: opts[:embedding_provider],
      k: opts[:k] || 10,
      search_port: if(url, do: opts[:port], else: port),
      post_requests: Access.get(opts, :post_requests, false)
    }
  end

  @doc """
  Query the configured URL and return up to `:k` ranked results.

  Supply a complete `:url` when constructing the client. An explicit
  `:port` overrides the URL's port. Construction without a URL uses
  `http://localhost:8893` by default. The client uses GET unless constructed
  with `post_requests: true`. GET supports at most 100 results.

  Results are maps with string keys, in server order. GET sets
  `"long_text"` from the server's `"text"`. Set `simplify: true` to return
  just the `"long_text"` strings.
  """
  def search(%__MODULE__{} = client, query, opts \\ []) do
    with :ok <- validate_query(query),
         {:ok, opts} <- search_options(opts, client.k),
         {:ok, method} <- request_method(Map.get(client, :post_requests, false)),
         :ok <- validate_k(opts[:k], method),
         {:ok, uri} <- search_uri(client),
         {:ok, body} <- request(uri, method, query, opts[:k]) do
      decode_results(body, method, opts)
    end
  end

  defp validate_query(query) do
    if is_binary(query) and String.valid?(query), do: :ok, else: {:error, :invalid_query}
  end

  defp search_options(opts, default_k) when is_integer(length(opts)) do
    with true <- Keyword.keyword?(opts),
         {:ok, options} <- Keyword.validate(opts, k: default_k, simplify: false),
         true <- is_boolean(options[:simplify]) do
      {:ok, options}
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp search_options(_opts, _default_k), do: {:error, :invalid_options}

  defp request_method(false), do: {:ok, :get}
  defp request_method(true), do: {:ok, :post}
  defp request_method(_value), do: {:error, :invalid_method}

  defp validate_k(k, method) when is_integer(k) and k >= 0 and (method == :post or k <= 100),
    do: :ok

  defp validate_k(_k, _method), do: {:error, :invalid_k}

  defp search_uri(%{url: url} = client) when is_binary(url) do
    with true <- String.valid?(url),
         {:ok, %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = uri}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.new(url),
         {:ok, port} <- resolve_port(Map.get(client, :search_port), uri.port) do
      {:ok, %{uri | port: port}}
    else
      _ -> {:error, :invalid_endpoint}
    end
  end

  defp search_uri(_client), do: {:error, :invalid_endpoint}

  defp resolve_port(nil, default) when is_integer(default), do: resolve_port(default, nil)
  defp resolve_port(port, _default) when is_integer(port) and port in 1..65535, do: {:ok, port}

  defp resolve_port(port, _default) when is_binary(port) do
    case Integer.parse(port) do
      {value, ""} when value in 1..65535 -> {:ok, value}
      _ -> :error
    end
  end

  defp resolve_port(_port, _default), do: :error

  defp request(uri, method, query, k) do
    request = Req.Request.new() |> Req.Steps.attach()

    options = [
      method: method,
      connect_options: [timeout: @timeout],
      receive_timeout: @timeout,
      retry: false,
      redirect: false,
      decode_body: false
    ]

    payload = [query: query, k: k]

    case Req.request(request, options ++ request_options(method, uri, payload)) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
      {:error, _reason} -> {:error, :transport}
    end
  rescue
    ArgumentError -> {:error, :invalid_endpoint}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _reason -> {:error, :transport}
  end

  defp request_options(:get, uri, payload),
    do: [url: URI.append_query(uri, URI.encode_query(payload))]

  defp request_options(:post, uri, payload) do
    [
      url: uri,
      json: Map.new(payload),
      headers: [{"content-type", "application/json; charset=utf-8"}]
    ]
  end

  defp decode_results(body, method, opts) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} when error not in [nil, false, "", 0, 0.0, [], %{}] ->
        {:error, :server_error}

      {:ok, %{"topk" => rows}} when is_list(rows) ->
        rows
        |> Enum.take(opts[:k])
        |> render_results(method, opts[:simplify])

      _ ->
        {:error, :invalid_response}
    end
  end

  defp render_results(rows, method, simplify?) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, results} ->
      with {:ok, row} <- normalize_row(method, row),
           {:ok, result} <- render_row(row, simplify?) do
        {:cont, {:ok, [result | results]}}
      else
        :error -> {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_row(:get, %{"text" => text} = row) when is_binary(text),
    do: {:ok, Map.put(row, "long_text", text)}

  defp normalize_row(:post, row) when is_map(row), do: {:ok, row}
  defp normalize_row(_method, _row), do: :error

  defp render_row(row, false), do: {:ok, row}
  defp render_row(%{"long_text" => text}, true) when is_binary(text), do: {:ok, text}
  defp render_row(_row, true), do: :error

  @impl true
  def retrieve(_query, _opts \\ []) do
    {:error,
     "ColBERTv2 is a quarantined extras placeholder (use a custom Retriever + RAGPipeline; see docs/OVERVIEW.md)"}
  end

  @impl true
  def index_documents(_documents, _opts \\ []) do
    {:error,
     "ColBERTv2 is a quarantined extras placeholder (indexing not implemented; see docs/OVERVIEW.md)"}
  end

  @impl true
  def clear_index(_opts \\ []) do
    {:error,
     "ColBERTv2 is a quarantined extras placeholder (clear_index not implemented; see docs/OVERVIEW.md)"}
  end
end
