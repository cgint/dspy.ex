defmodule Dspy.LM.ReqLLM do
  @moduledoc """
  ReqLLM-backed language model client.

  This delegates LLM provider calls to `req_llm` (unified API across providers).
  """

  @behaviour Dspy.LM

  defstruct [
    :model,
    default_opts: [],
    client_module: ReqLLM,
    context_module: ReqLLM.Context,
    response_module: ReqLLM.Response
  ]

  @type t :: %__MODULE__{
          model: String.t(),
          default_opts: keyword(),
          client_module: module(),
          context_module: module(),
          response_module: module()
        }

  @doc """
  Create a new ReqLLM client.

  Required:
  - `:model` - a model spec string like `"anthropic:claude-haiku-4-5"` or `"openai:gpt-4.1-mini"`

  Optional:
  - `:default_opts` - default ReqLLM options (merged with per-request options)
  - `:client_module` / `:context_module` / `:response_module` - for testing
  """
  def new(opts \\ []) do
    %__MODULE__{
      model: Keyword.fetch!(opts, :model),
      default_opts: Keyword.get(opts, :default_opts, []),
      client_module: Keyword.get(opts, :client_module, ReqLLM),
      context_module: Keyword.get(opts, :context_module, ReqLLM.Context),
      response_module: Keyword.get(opts, :response_module, ReqLLM.Response)
    }
  end

  @impl true
  def generate(%__MODULE__{} = lm, request) when is_map(request) do
    {input, opts} = to_req_llm_input_and_opts(lm, request)

    case lm.client_module.generate_text(lm.model, input, opts) do
      {:ok, response} ->
        text = lm.response_module.text(response)
        finish_reason = lm.response_module.finish_reason(response)
        usage = lm.response_module.usage(response)

        {:ok,
         %{
           choices: [
             %{
               message: %{role: "assistant", content: text || ""},
               finish_reason: finish_reason && Atom.to_string(finish_reason)
             }
           ],
           usage: map_usage(usage)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def supports?(_lm, _feature), do: true

  defp to_req_llm_input_and_opts(%__MODULE__{} = lm, request) do
    input =
      case request[:messages] do
        messages when is_list(messages) ->
          lm.context_module.new(Enum.map(messages, &to_req_llm_message(lm.context_module, &1)))

        _ ->
          request[:prompt] || request[:text] || request[:input] || ""
      end

    request_opts =
      []
      |> maybe_put(:temperature, request[:temperature])
      |> maybe_put(:max_tokens, request[:max_tokens])
      |> maybe_put(:stop, request[:stop])
      |> maybe_put(:tools, request[:tools])

    {input, Keyword.merge(lm.default_opts, request_opts)}
  end

  defp to_req_llm_message(context_module, %{role: role, content: content})
       when is_binary(role) and is_binary(content) do
    case role do
      "system" -> context_module.system(content)
      "assistant" -> context_module.assistant(content)
      _ -> context_module.user(content)
    end
  end

  defp to_req_llm_message(context_module, %{"role" => role, "content" => content})
       when is_binary(role) and is_binary(content) do
    to_req_llm_message(context_module, %{role: role, content: content})
  end

  defp to_req_llm_message(context_module, other) do
    context_module.user(inspect(other))
  end

  defp map_usage(nil), do: nil

  defp map_usage(usage) when is_map(usage) do
    prompt_tokens = usage[:input_tokens] || usage["input_tokens"]
    completion_tokens = usage[:output_tokens] || usage["output_tokens"]
    total_tokens = usage[:total_tokens] || usage["total_tokens"]

    %{
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      total_tokens: total_tokens
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
