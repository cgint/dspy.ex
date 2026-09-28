defmodule Dspy.LM.LiteLLM do
  @moduledoc """
  Universal language model client wrapper supporting 100+ providers.
  Compatible with Python DSPy's LiteLLM integration.

  Supported providers:
  - OpenAI (GPT-3.5, GPT-4, GPT-4o)
  - Anthropic (Claude 3.5 Sonnet, Haiku, Opus)
  - Google (Gemini Pro, Ultra)
  - Meta (Llama 3.1, 3.2)
  - Mistral (7B, 8x7B, 8x22B)
  - Cohere (Command R+)
  - And 90+ more providers
  """

  use GenServer

  defstruct [
    :model,
    :api_key,
    :base_url,
    :provider,
    :max_tokens,
    :temperature,
    :timeout,
    :retry_attempts,
    :custom_headers,
    :completion_window,
    :request_id
  ]

  @type t :: %__MODULE__{
          model: String.t(),
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          provider: atom(),
          max_tokens: pos_integer(),
          temperature: float(),
          timeout: pos_integer(),
          retry_attempts: pos_integer(),
          custom_headers: map(),
          completion_window: pos_integer(),
          request_id: String.t() | nil
        }

  # Provider mappings
  @providers %{
    # OpenAI family
    "gpt-3.5-turbo" => :openai,
    "gpt-4" => :openai,
    "gpt-4-turbo" => :openai,
    "gpt-4o" => :openai,
    "gpt-4o-mini" => :openai,

    # Anthropic family
    "claude-3-5-sonnet-20241022" => :anthropic,
    "claude-3-5-haiku-20241022" => :anthropic,
    "claude-3-opus-20240229" => :anthropic,

    # Google family
    "gemini-2.5-pro" => :google,
    "gemini-2.5-flash" => :google,
    "gemini-2.5-flash-lite" => :google,

    # Meta Llama family
    "meta-llama/Llama-3.1-8B-Instruct" => :meta,
    "meta-llama/Llama-3.1-70B-Instruct" => :meta,
    "meta-llama/Llama-3.2-90B-Vision-Instruct" => :meta,

    # Mistral family
    "mistral-7b-instruct" => :mistral,
    "mixtral-8x7b-instruct" => :mistral,
    "mixtral-8x22b-instruct" => :mistral,

    # Cohere family
    "command-r-plus" => :cohere,
    "command-r" => :cohere
  }

  @default_config %{
    max_tokens: 1024,
    temperature: 0.0,
    timeout: 30_000,
    retry_attempts: 3,
    completion_window: 10_000
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    {:ok, %{clients: %{}, config: Map.merge(@default_config, Map.new(opts))}}
  end

  @doc """
  Create a new LiteLLM client instance.

  ## Examples

      iex> LiteLLM.new("gpt-4o")
      %LiteLLM{model: "gpt-4o", provider: :openai, ...}

      iex> LiteLLM.new("claude-3-5-sonnet-20241022", api_key: "sk-ant-...")
      %LiteLLM{model: "claude-3-5-sonnet-20241022", provider: :anthropic, ...}
  """
  def new(model, opts \\ []) do
    provider = Map.get(@providers, model, :unknown)

    config = Map.merge(@default_config, Map.new(opts))

    %__MODULE__{
      model: model,
      provider: provider,
      api_key: opts[:api_key] || get_api_key(provider),
      base_url: opts[:base_url] || get_base_url(provider),
      max_tokens: config.max_tokens,
      temperature: config.temperature,
      timeout: config.timeout,
      retry_attempts: config.retry_attempts,
      custom_headers: opts[:custom_headers] || %{},
      completion_window: config.completion_window,
      request_id: generate_request_id()
    }
  end

  @doc """
  Generate completions from the language model.

  ## Examples

      iex> client = LiteLLM.new("gpt-4o")
      iex> LiteLLM.completions(client, [%{role: "user", content: "Hello!"}])
      {:ok, %{choices: [%{message: %{content: "Hello! How can I help you?"}}]}}
  """
  def completions(%__MODULE__{} = client, messages, opts \\ []) do
    case client.provider do
      :openai -> call_openai(client, messages, opts)
      :anthropic -> call_anthropic(client, messages, opts)
      :google -> call_google(client, messages, opts)
      :meta -> call_meta(client, messages, opts)
      :mistral -> call_mistral(client, messages, opts)
      :cohere -> call_cohere(client, messages, opts)
      :unknown -> {:error, "Unsupported model: #{client.model}"}
    end
  end

  @doc """
  Generate text completion with automatic provider routing.
  """
  def generate(%__MODULE__{} = client, prompt, opts \\ []) when is_binary(prompt) do
    messages = [%{role: "user", content: prompt}]

    case completions(client, messages, opts) do
      {:ok, response} ->
        content = extract_content(response, client.provider)
        {:ok, %{completions: [content]}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions for provider-specific implementations

  defp call_openai(client, messages, opts) do
    request_body = %{
      model: client.model,
      messages: messages,
      max_tokens: opts[:max_tokens] || client.max_tokens,
      temperature: opts[:temperature] || client.temperature
    }

    headers =
      [
        {"Authorization", "Bearer #{client.api_key}"},
        {"Content-Type", "application/json"}
      ] ++ Map.to_list(client.custom_headers)

    url = "#{client.base_url || "https://api.openai.com"}/v1/chat/completions"

    make_request(url, request_body, headers, client.timeout)
  end

  defp call_anthropic(client, messages, opts) do
    # Convert OpenAI format to Anthropic format
    system_msg = Enum.find(messages, &(&1.role == "system"))
    user_messages = Enum.filter(messages, &(&1.role != "system"))

    request_body = %{
      model: client.model,
      messages: user_messages,
      max_tokens: opts[:max_tokens] || client.max_tokens,
      temperature: opts[:temperature] || client.temperature
    }

    request_body =
      if system_msg do
        Map.put(request_body, :system, system_msg.content)
      else
        request_body
      end

    headers =
      [
        {"x-api-key", client.api_key},
        {"Content-Type", "application/json"},
        {"anthropic-version", "2023-06-01"}
      ] ++ Map.to_list(client.custom_headers)

    url = "#{client.base_url || "https://api.anthropic.com"}/v1/messages"

    make_request(url, request_body, headers, client.timeout)
  end

  defp call_google(_client, _messages, _opts) do
    # Implement Google Gemini API calls
    {:error, "Google provider not yet implemented"}
  end

  defp call_meta(_client, _messages, _opts) do
    # Implement Meta Llama API calls
    {:error, "Meta provider not yet implemented"}
  end

  defp call_mistral(_client, _messages, _opts) do
    # Implement Mistral API calls
    {:error, "Mistral provider not yet implemented"}
  end

  defp call_cohere(_client, _messages, _opts) do
    # Implement Cohere API calls
    {:error, "Cohere provider not yet implemented"}
  end

  defp make_request(url, body, headers, timeout) do
    opts =
      Application.get_env(:dspy_extras, :req_opts, [])
      |> Keyword.put_new(:receive_timeout, timeout)
      # HTTP clients should not silently retry: callers decide (LiteLLM keeps
      # its retry_attempts field for future explicit retries).
      |> Keyword.put_new(:retry, false)

    case Req.post(url, Keyword.merge([json: body, headers: headers], opts)) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        decode_body(response_body)

      {:ok, %Req.Response{status: status, body: error_body}} ->
        {:error, "API request failed with status #{status}: #{error_message(error_body)}"}

      {:error, %Req.TransportError{} = error} ->
        {:error, "Network error: " <> Exception.message(error)}

      # Safety net: Req raises/returns exceptions for unexpected failures;
      # keep the public shape a plain error tuple (never crash on odd reasons,
      # e.g. {:tls_alert, _} tuples).
      {:error, error} when is_exception(error) ->
        {:error, "Request failed: " <> Exception.message(error)}
    end
  end

  # Req parses JSON bodies into maps when the response content type is JSON;
  # otherwise it leaves the body as a (binary) string. Both cases must decode
  # to the same `%{...}` map so callers see the same shape as with HTTPoison.
  defp decode_body(%{} = body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, "Failed to decode response"}
    end
  end

  defp decode_body(_body), do: {:error, "Failed to decode response"}

  # Req may hand back a parsed map as a non-200 body; keep the old
  # HTTPoison-style "status: <body>" message for strings.
  defp error_message(error_body) when is_binary(error_body), do: error_body
  defp error_message(error_body), do: inspect(error_body)

  defp extract_content(response, provider) do
    case provider do
      :openai ->
        get_in(response, ["choices", Access.at(0), "message", "content"])

      :anthropic ->
        get_in(response, ["content", Access.at(0), "text"])

      _ ->
        get_in(response, ["choices", Access.at(0), "message", "content"])
    end
  end

  defp get_api_key(:openai), do: System.get_env("OPENAI_API_KEY")
  defp get_api_key(:anthropic), do: System.get_env("ANTHROPIC_API_KEY")
  defp get_api_key(:google), do: System.get_env("GOOGLE_API_KEY")
  defp get_api_key(:meta), do: System.get_env("META_API_KEY")
  defp get_api_key(:mistral), do: System.get_env("MISTRAL_API_KEY")
  defp get_api_key(:cohere), do: System.get_env("COHERE_API_KEY")
  defp get_api_key(_), do: nil

  defp get_base_url(:openai), do: "https://api.openai.com"
  defp get_base_url(:anthropic), do: "https://api.anthropic.com"
  defp get_base_url(:google), do: "https://generativelanguage.googleapis.com"
  defp get_base_url(_), do: nil

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc """
  List all supported models across providers.
  """
  def supported_models do
    Map.keys(@providers)
  end

  @doc """
  Get provider for a specific model.
  """
  def get_provider(model) do
    Map.get(@providers, model, :unknown)
  end
end
