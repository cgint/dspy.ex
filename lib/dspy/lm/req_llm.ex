defmodule Dspy.LM.ReqLLM do
  @moduledoc """
  ReqLLM-backed language model client.

  This delegates LLM provider calls to `req_llm` (unified API across providers).

  ## Multipart / attachments

  This adapter supports `request.messages[].content` as either:

  - a plain string, or
  - a list of OpenAI-style parts like `%{"type" => "text", "text" => ...}` and
    `%{"type" => "input_file", "file_path" => ...}`.

  For `"input_file"` parts with `"file_path"`, this adapter may read from the local
  filesystem (`File.read/1`) to build `ReqLLM.Message.ContentPart.file/3`.

  For safety, local file reads are **disabled by default**. (This adapter is strict and
  will error on unsupported message shapes rather than coercing them.) To enable file
  reads, set:

      config :dspy, attachment_roots: ["/some/allowed/dir"]

  and (optionally) allow absolute paths via:

      config :dspy, allow_absolute_attachment_paths: true
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
    with {:ok, {input, opts}} <- to_req_llm_input_and_opts(lm, request),
         {:ok, response} <- lm.client_module.generate_text(lm.model, input, opts) do
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
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def supports?(_lm, _feature), do: true

  defp to_req_llm_input_and_opts(%__MODULE__{} = lm, request) do
    with {:ok, input} <- to_req_llm_input(lm, request) do
      request_opts =
        []
        |> maybe_put(:temperature, request[:temperature])
        |> maybe_put(:max_tokens, request[:max_tokens])
        |> maybe_put(:max_completion_tokens, request[:max_completion_tokens])
        |> maybe_put(:stop, request[:stop])
        |> maybe_put(:tools, request[:tools])

      opts = Keyword.merge(lm.default_opts, request_opts)
      opts = normalize_token_limits_for_model(lm.model, opts)

      {:ok, {input, opts}}
    end
  end

  defp to_req_llm_input(%__MODULE__{} = lm, request) do
    case request[:messages] do
      messages when is_list(messages) ->
        with {:ok, msgs} <- to_req_llm_messages(lm.context_module, messages) do
          {:ok, lm.context_module.new(msgs)}
        end

      _ ->
        {:ok, request[:prompt] || request[:text] || request[:input] || ""}
    end
  end

  defp to_req_llm_messages(context_module, messages) do
    with {:ok, rev} <-
           Enum.reduce_while(messages, {:ok, []}, fn msg, {:ok, acc} ->
             case to_req_llm_message(context_module, msg) do
               {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      {:ok, Enum.reverse(rev)}
    end
  end

  defp to_req_llm_message(context_module, %{role: role, content: content})
       when is_binary(role) and is_binary(content) do
    {:ok,
     case role do
       "system" -> context_module.system(content)
       "assistant" -> context_module.assistant(content)
       _ -> context_module.user(content)
     end}
  end

  defp to_req_llm_message(context_module, %{role: role, content: content})
       when is_binary(role) and is_list(content) do
    with {:ok, parts} <- to_req_llm_parts(content) do
      {:ok,
       case role do
         "system" -> context_module.system(parts)
         "assistant" -> context_module.assistant(parts)
         _ -> context_module.user(parts)
       end}
    end
  end

  defp to_req_llm_message(context_module, %{"role" => role, "content" => content})
       when is_binary(role) do
    to_req_llm_message(context_module, %{role: role, content: content})
  end

  defp to_req_llm_message(_context_module, other) do
    {:error, {:unsupported_message, other}}
  end

  defp to_req_llm_parts(parts) when is_list(parts) do
    with {:ok, rev} <-
           Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
             case to_req_llm_part(part) do
               {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      {:ok, Enum.reverse(rev)}
    end
  end

  defp to_req_llm_part(%{"type" => "text", "text" => text}) when is_binary(text) do
    {:ok, ReqLLM.Message.ContentPart.text(text)}
  end

  defp to_req_llm_part(%{type: "text", text: text}) when is_binary(text) do
    {:ok, ReqLLM.Message.ContentPart.text(text)}
  end

  defp to_req_llm_part(%{"type" => "input_file", "data" => data, "filename" => filename} = part)
       when is_binary(filename) do
    mime_type = part["mime_type"] || "application/octet-stream"

    with {:ok, bin} <- normalize_file_data(data) do
      {:ok, ReqLLM.Message.ContentPart.file(bin, filename, mime_type)}
    end
  end

  defp to_req_llm_part(%{"type" => "input_file", "file_path" => path} = part)
       when is_binary(path) do
    mime_type = part["mime_type"]

    with {:ok, realpath} <- validate_input_file_path(path),
         :ok <- validate_attachment_size(realpath),
         {:ok, bin} <- File.read(realpath) do
      filename = Path.basename(path)

      {:ok,
       ReqLLM.Message.ContentPart.file(bin, filename, mime_type || "application/octet-stream")}
    end
  end

  defp to_req_llm_part(%{type: "input_file", data: data, filename: filename} = part)
       when is_binary(filename) do
    mime_type = Map.get(part, :mime_type) || "application/octet-stream"

    with {:ok, bin} <- normalize_file_data(data) do
      {:ok, ReqLLM.Message.ContentPart.file(bin, filename, mime_type)}
    end
  end

  defp to_req_llm_part(%{type: "input_file", file_path: path} = part) when is_binary(path) do
    mime_type = Map.get(part, :mime_type)

    with {:ok, realpath} <- validate_input_file_path(path),
         :ok <- validate_attachment_size(realpath),
         {:ok, bin} <- File.read(realpath) do
      filename = Path.basename(path)

      {:ok,
       ReqLLM.Message.ContentPart.file(bin, filename, mime_type || "application/octet-stream")}
    end
  end

  defp to_req_llm_part(%{"type" => "image_url", "image_url" => %{"url" => url}})
       when is_binary(url) do
    {:ok, ReqLLM.Message.ContentPart.image_url(url)}
  end

  defp to_req_llm_part(%{type: "image_url", image_url: %{url: url}}) when is_binary(url) do
    {:ok, ReqLLM.Message.ContentPart.image_url(url)}
  end

  defp to_req_llm_part(%{type: "image_url", url: url}) when is_binary(url) do
    {:ok, ReqLLM.Message.ContentPart.image_url(url)}
  end

  defp to_req_llm_part(other) do
    {:error, {:unsupported_content_part, other}}
  end

  defp validate_input_file_path(path) when is_binary(path) do
    allow_absolute? = Application.get_env(:dspy, :allow_absolute_attachment_paths, false)

    if Path.type(path) == :absolute and not allow_absolute? do
      {:error, {:absolute_paths_not_allowed, path}}
    else
      parts = Path.split(path)

      if Enum.any?(parts, &(&1 == "..")) do
        {:error, {:parent_dir_not_allowed, path}}
      else
        enforce_allowed_roots(path)
      end
    end
  end

  defp enforce_allowed_roots(path) do
    roots = Application.get_env(:dspy, :attachment_roots, [])

    if roots == [] do
      {:error, :attachments_not_enabled}
    else
      expanded = Path.expand(path)

      allowed_root =
        Enum.find(roots, fn root ->
          root_expanded = Path.expand(root)
          expanded == root_expanded or String.starts_with?(expanded, root_expanded <> "/")
        end)

      if allowed_root do
        root_expanded = Path.expand(allowed_root)

        with :ok <- ensure_root_not_symlink(root_expanded),
             :ok <- ensure_no_symlinks(expanded, root_expanded) do
          {:ok, expanded}
        else
          {:error, reason} -> {:error, {:invalid_attachment_root, root_expanded, reason}}
        end
      else
        {:error, {:path_not_allowed, path}}
      end
    end
  end

  defp ensure_root_not_symlink(root_expanded) do
    case File.lstat(root_expanded) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink_root_not_allowed, root_expanded}}
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:lstat_failed, root_expanded, reason}}
    end
  end

  defp ensure_no_symlinks(expanded_path, root_expanded) do
    parts = Path.split(expanded_path)
    root_parts = Path.split(root_expanded)

    if Enum.take(parts, length(root_parts)) != root_parts do
      {:error, {:path_not_allowed, expanded_path}}
    else
      start_i = length(root_parts) + 1
      end_i = length(parts)

      if start_i > end_i do
        :ok
      else
        # Check every component below the root for symlinks (including the final file).
        Enum.reduce_while(start_i..end_i, :ok, fn i, :ok ->
          current = parts |> Enum.take(i) |> Path.join()

          case File.lstat(current) do
            {:ok, %File.Stat{type: :symlink}} ->
              {:halt, {:error, {:symlink_not_allowed, current}}}

            {:ok, _stat} ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, {:lstat_failed, current, reason}}}
          end
        end)
      end
    end
  end

  defp validate_attachment_size(path) when is_binary(path) do
    max = Application.get_env(:dspy, :max_attachment_bytes, 10_000_000)

    with {:ok, stat} <- File.stat(path) do
      cond do
        stat.type != :regular ->
          {:error, {:attachment_not_a_regular_file, stat.type}}

        stat.size <= max ->
          :ok

        true ->
          {:error, {:attachment_too_large, stat.size, max}}
      end
    end
  end

  defp normalize_file_data(data) when is_binary(data), do: {:ok, data}

  defp normalize_file_data(data) when is_list(data) do
    try do
      {:ok, IO.iodata_to_binary(data)}
    rescue
      _ -> {:error, :invalid_file_data}
    end
  end

  defp normalize_file_data(data) when is_map(data) do
    {:error, {:invalid_file_data, data}}
  end

  defp normalize_file_data(_data), do: {:error, :invalid_file_data}

  defp normalize_token_limits_for_model(model_spec, opts)
       when is_binary(model_spec) and is_list(opts) do
    if reasoning_model_spec?(model_spec) do
      max_completion_tokens = Keyword.get(opts, :max_completion_tokens)
      {max_tokens, opts} = Keyword.pop(opts, :max_tokens)

      cond do
        is_integer(max_completion_tokens) ->
          opts

        is_integer(max_tokens) ->
          Keyword.put(opts, :max_completion_tokens, max_tokens)

        true ->
          opts
      end
    else
      opts
    end
  end

  defp normalize_token_limits_for_model(_model_spec, opts), do: opts

  defp reasoning_model_spec?(model_spec) when is_binary(model_spec) do
    case split_model_spec(model_spec) do
      {provider, model_id} when provider in ["openai", "azure"] ->
        reasoning_model_id?(model_id)

      _ ->
        false
    end
  end

  defp split_model_spec(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider, model_id] -> {provider, model_id}
      _ -> {nil, spec}
    end
  end

  # Mirror ReqLLM's OpenAI "reasoning model" detection for the token limit key.
  # This avoids ReqLLM warning logs for common usage (e.g. GPT-4.1 + max_tokens).
  defp reasoning_model_id?("gpt-5-chat-latest"), do: false
  defp reasoning_model_id?(<<"o1", _::binary>>), do: true
  defp reasoning_model_id?(<<"o3", _::binary>>), do: true
  defp reasoning_model_id?(<<"o4", _::binary>>), do: true
  defp reasoning_model_id?(<<"gpt-4.1", _::binary>>), do: true
  defp reasoning_model_id?(<<"gpt-5", _::binary>>), do: true
  defp reasoning_model_id?(<<"codex", _::binary>>), do: true

  defp reasoning_model_id?(model_id) when is_binary(model_id) do
    String.contains?(model_id, "-codex")
  end

  defp reasoning_model_id?(_), do: false

  defp map_usage(nil), do: nil

  # Preserve ReqLLM's full usage map (provider-dependent), while adding
  # Python/DSPy-style aliases when possible.
  defp map_usage(usage) when is_map(usage) do
    input_tokens = usage[:input_tokens] || usage["input_tokens"]
    output_tokens = usage[:output_tokens] || usage["output_tokens"]

    prompt_tokens = usage[:prompt_tokens] || usage["prompt_tokens"] || input_tokens
    completion_tokens = usage[:completion_tokens] || usage["completion_tokens"] || output_tokens
    total_tokens = usage[:total_tokens] || usage["total_tokens"]

    cached_tokens = usage[:cached_tokens] || usage["cached_tokens"]
    reasoning_tokens = usage[:reasoning_tokens] || usage["reasoning_tokens"]

    usage =
      usage
      |> maybe_put_map(:prompt_tokens, prompt_tokens)
      |> maybe_put_map(:completion_tokens, completion_tokens)
      |> maybe_put_map(:total_tokens, total_tokens)

    usage =
      if is_integer(cached_tokens) do
        details = usage[:prompt_tokens_details] || usage["prompt_tokens_details"]
        details = if is_map(details), do: details, else: %{}
        Map.put(usage, :prompt_tokens_details, Map.put(details, :cached_tokens, cached_tokens))
      else
        usage
      end

    usage =
      if is_integer(reasoning_tokens) do
        details = usage[:completion_tokens_details] || usage["completion_tokens_details"]
        details = if is_map(details), do: details, else: %{}

        Map.put(
          usage,
          :completion_tokens_details,
          Map.put(details, :reasoning_tokens, reasoning_tokens)
        )
      else
        usage
      end

    usage
  end

  defp maybe_put_map(map, _key, nil), do: map

  defp maybe_put_map(map, key, value) when is_map(map) do
    Map.put(map, key, value)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
