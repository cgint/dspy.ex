defmodule Dspy.LM.ReqLLM do
  require Logger

  @moduledoc """
  ReqLLM-backed language model client.

  This delegates LLM provider calls to `req_llm` (unified API across providers).

  Assistant history messages can carry OpenAI-style `tool_calls`. Tool result
  messages use role `"tool"` and the corresponding `tool_call_id`. The
  text-generation response includes native function calls when present.

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
    :cache_namespace,
    default_opts: [],
    client_module: ReqLLM,
    context_module: ReqLLM.Context,
    response_module: ReqLLM.Response,
    generation_module: ReqLLM.Generation
  ]

  @type t :: %__MODULE__{
          model: String.t(),
          cache_namespace: String.t() | nil,
          default_opts: keyword(),
          client_module: module(),
          context_module: module(),
          response_module: module(),
          generation_module: module()
        }

  @doc """
  Create a new ReqLLM client.

  Required:
  - `:model` - a model spec string like `"anthropic:claude-haiku-4-5"` or `"openai:gpt-4.1-mini"`

  Optional:
  - `:default_opts` - default ReqLLM options (merged with per-request options)
  - `:cache_namespace` - account namespace for eligible disk cache entries
  - `:client_module` / `:context_module` / `:response_module` - for testing
  """
  def new(opts \\ []) do
    namespace = Keyword.get(opts, :cache_namespace)

    unless valid_cache_namespace?(namespace) do
      raise ArgumentError, "expected :cache_namespace to be nil or a nonblank string"
    end

    %__MODULE__{
      model: Keyword.fetch!(opts, :model),
      cache_namespace: namespace,
      default_opts: Keyword.get(opts, :default_opts, []),
      client_module: Keyword.get(opts, :client_module, ReqLLM),
      context_module: Keyword.get(opts, :context_module, ReqLLM.Context),
      response_module: Keyword.get(opts, :response_module, ReqLLM.Response),
      generation_module: Keyword.get(opts, :generation_module, ReqLLM.Generation)
    }
  end

  @doc false
  def valid_cache_namespace?(nil), do: true

  def valid_cache_namespace?(namespace) when is_binary(namespace),
    do: String.valid?(namespace) and String.trim(namespace) != ""

  def valid_cache_namespace?(_namespace), do: false

  @impl true
  def generate(%__MODULE__{} = lm, request) when is_map(request) do
    with {:ok, {input, opts}} <- to_req_llm_input_and_opts(lm, request) do
      case native_object_contract(request, lm.model) do
        {:ok, contract} ->
          case lm.generation_module.generate_object(lm.model, input, contract, opts) do
            {:ok, response} ->
              normalize_object_response(lm, response)

            {:error, native_reason} = error ->
              if Dspy.LM.RetryPolicy.schema_fallback?(native_reason) do
                Logger.warning(
                  "native structured-output generation failed; falling back to text generation: #{Dspy.LogReason.format(native_reason)}"
                )

                generate_text_response(lm, input, opts)
              else
                error
              end
          end

        :fallback ->
          generate_text_response(lm, input, opts)
      end
    end
  end

  defp generate_text_response(lm, input, opts) do
    with {:ok, response} <- lm.client_module.generate_text(lm.model, input, opts) do
      text = lm.response_module.text(response)
      finish_reason = lm.response_module.finish_reason(response)
      usage = lm.response_module.usage(response)
      normalized_response(text || "", finish_reason, usage, response_tool_calls(lm, response))
    end
  end

  defp normalize_object_response(lm, response) do
    object = lm.response_module.object(response)

    text =
      case lm.response_module.text(response) do
        text when is_binary(text) and text != "" -> text
        _ -> Jason.encode!(object)
      end

    normalized_response(
      text,
      lm.response_module.finish_reason(response),
      lm.response_module.usage(response)
    )
  end

  defp response_tool_calls(lm, response) do
    with true <- function_exported?(lm.response_module, :tool_calls, 1),
         calls when is_integer(length(calls)) <- lm.response_module.tool_calls(response) do
      for call <- calls, not ReqLLM.ToolCall.builtin?(call) do
        case call do
          %ReqLLM.ToolCall{} -> Map.from_struct(call)
          other -> other
        end
      end
    else
      _ -> []
    end
  end

  defp normalized_response(text, finish_reason, usage, tool_calls \\ []) do
    message = %{role: "assistant", content: text}
    message = if tool_calls == [], do: message, else: Map.put(message, :tool_calls, tool_calls)

    {:ok,
     %{
       choices: [
         %{
           message: message,
           finish_reason: finish_reason && Atom.to_string(finish_reason)
         }
       ],
       usage: map_usage(usage)
     }}
  end

  defp native_object_contract(%{output_contract: contract}, model) when is_map(contract) do
    if native_structured_model?(model), do: {:ok, contract}, else: :fallback
  end

  defp native_object_contract(_, _), do: :fallback

  # ReqLLM exposes object generation for more providers, but this adapter keeps its
  # native path intentionally limited to providers covered by this contract slice.
  defp native_structured_model?(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _] when provider in ["google", "google_vertex", "openai"] -> true
      _ -> false
    end
  end

  defp native_structured_model?(_), do: false

  @impl true
  def supports?(%__MODULE__{model: model}, :structured_output),
    do: native_structured_model?(model)

  def supports?(%__MODULE__{model: "openai:" <> _model}, :structured_react), do: true
  def supports?(_lm, :structured_react), do: false
  def supports?(_lm, :multiple_choices), do: false
  def supports?(_lm, _feature), do: true

  defp to_req_llm_input_and_opts(%__MODULE__{} = lm, request) do
    with {:ok, input} <- to_req_llm_input(lm, request) do
      request_opts =
        []
        |> maybe_put(:temperature, request[:temperature])
        |> maybe_put(:max_tokens, request[:max_tokens])
        |> maybe_put(:max_completion_tokens, request[:max_completion_tokens])
        |> maybe_put(:n, if(request[:n] === 1, do: 1))
        |> maybe_put(:stop, request[:stop])
        |> maybe_put(:tools, request[:tools])
        |> maybe_put(:tool_choice, request[:tool_choice])

      opts = Keyword.merge(lm.default_opts, request_opts)

      opts =
        if Map.get(request, :reasoning_effort, :inherit) == nil,
          do: Keyword.delete(opts, :reasoning_effort),
          else: opts

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

  defp to_req_llm_message(context_module, message) when is_map(message) do
    role = wire_field(message, :role)
    content = wire_field(message, :content)

    case {role, wire_field(message, :tool_calls)} do
      {"tool", _} ->
        to_req_llm_tool_result(context_module, message, content)

      {"assistant", calls} when calls not in [nil, []] ->
        content = if is_nil(content), do: "", else: content

        with {:ok, tool_calls} <- to_req_llm_tool_calls(calls),
             {:ok, content} <- to_req_llm_content(content) do
          {:ok, context_module.assistant(content, tool_calls: tool_calls)}
        end

      {role, _} when is_binary(role) and (is_binary(content) or is_integer(length(content))) ->
        with {:ok, content} <- to_req_llm_content(content) do
          {:ok,
           case role do
             "system" -> context_module.system(content)
             "assistant" -> context_module.assistant(content)
             _ -> context_module.user(content)
           end}
        end

      _ ->
        {:error, {:unsupported_message, message}}
    end
  end

  defp to_req_llm_message(_context_module, other) do
    {:error, {:unsupported_message, other}}
  end

  defp to_req_llm_tool_result(context_module, message, content) do
    id = wire_field(message, :tool_call_id)
    name = wire_field(message, :name)

    if nonblank?(id) and (is_nil(name) or nonblank?(name)) do
      with {:ok, content} <- to_req_llm_content(content) do
        {:ok, context_module.tool_result(id, name, content)}
      end
    else
      {:error, {:unsupported_message, :invalid_tool_result}}
    end
  end

  defp to_req_llm_content(content) when is_binary(content), do: {:ok, content}
  defp to_req_llm_content(content) when is_integer(length(content)), do: to_req_llm_parts(content)
  defp to_req_llm_content(_content), do: {:error, {:unsupported_message, :invalid_tool_content}}

  defp to_req_llm_tool_calls(calls) when is_integer(length(calls)) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, acc} ->
      case to_req_llm_tool_call(call) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      {:error, _} = error -> error
    end
  end

  defp to_req_llm_tool_calls(_calls), do: {:error, {:unsupported_message, :invalid_tool_calls}}

  defp to_req_llm_tool_call(call) when is_map(call) do
    with "function" <- wire_field(call, :type),
         false <- ReqLLM.ToolCall.builtin?(call),
         %{} = function <- wire_field(call, :function),
         id = wire_field(call, :id),
         name = wire_field(function, :name),
         true <- nonblank?(id) and nonblank?(name),
         {:ok, args} <- encode_tool_arguments(wire_field(function, :arguments)) do
      tool_call = ReqLLM.ToolCall.new(id, name, args)
      {:ok, ReqLLM.ToolCall.put_metadata(tool_call, tool_call_metadata(call))}
    else
      _ -> {:error, {:unsupported_message, :invalid_tool_call}}
    end
  end

  defp to_req_llm_tool_call(_call), do: {:error, {:unsupported_message, :invalid_tool_call}}

  defp encode_tool_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{}} -> {:ok, args}
      _ -> :error
    end
  end

  defp encode_tool_arguments(args) when is_map(args) and not is_struct(args),
    do: Jason.encode(args)

  defp encode_tool_arguments(_args), do: :error

  defp tool_call_metadata(call) do
    metadata = ReqLLM.ToolCall.metadata(call)

    nested_signature =
      Map.get(metadata, :thought_signature) || Map.get(metadata, "thought_signature")

    signature = Map.get(call, :thought_signature) || Map.get(call, "thought_signature")

    if is_nil(nested_signature) and is_binary(signature) do
      Map.put(metadata, :thought_signature, signature)
    else
      metadata
    end
  end

  defp wire_field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp nonblank?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

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
