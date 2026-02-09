defmodule Dspy.LM.Bumblebee do
  @moduledoc """
  Local (on-device) LLM adapter backed by Bumblebee/Nx.

  This module implements the `Dspy.LM` behaviour, but **does not add** Bumblebee
  (or Nx/EXLA) as a dependency of core `:dspy`.

  That means:

  - `:dspy` can compile and run without Bumblebee present.
  - Your application must add `:bumblebee` (and an Nx backend such as `:exla`) to
    its deps to use this adapter.

  The adapter is intentionally minimal:

  - text-only generation (multimodal parts are rejected)
  - tools are currently rejected (Bumblebee is not a chat tool-calling API)

  ## Usage (sketch)

      # In your app deps (not in :dspy):
      # {:bumblebee, "~> 0.6"}, {:nx, "~> 0.7"}, {:exla, "~> 0.7"}
      # config :nx, default_backend: EXLA.Backend

      {:ok, model_info} = Bumblebee.load_model({:hf, "gpt2"})
      {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "gpt2"})

      serving = Bumblebee.Text.generation(model_info, tokenizer, max_new_tokens: 64)

      lm = Dspy.LM.Bumblebee.new(serving: serving)
      Dspy.configure(lm: lm)

      {:ok, resp} = Dspy.LM.generate(%{messages: [%{role: "user", content: "Hello"}]})

  ## Determinism

  Real model outputs are not guaranteed deterministic across backends/hardware.
  Keep CI deterministic by using mock `Dspy.LM` implementations in tests.
  """

  @behaviour Dspy.LM

  defstruct serving: nil,
            runner_module: Nx.Serving,
            default_opts: [],
            prompt_builder: &__MODULE__.messages_to_prompt/1,
            available_fun: &__MODULE__.nx_serving_available?/0

  @type t :: %__MODULE__{
          serving: term(),
          runner_module: module(),
          default_opts: keyword(),
          prompt_builder: (list() -> String.t()),
          available_fun: (-> boolean())
        }

  @doc """
  Create a new Bumblebee-backed LM.

  Options:

  - `:serving` (required) - an `Nx.Serving` (usually returned by `Bumblebee.Text.generation/3`)
  - `:runner_module` - module that runs the serving (default: `Nx.Serving`)
    - If it exports `run/3`, we will call `run(serving, prompt, opts)`.
    - Otherwise we call `run(serving, prompt)`.
  - `:default_opts` - merged into per-request opts (passed only if `run/3` exists)
  - `:prompt_builder` - function to convert `messages` into a single prompt string

  This constructor does **not** load models; it assumes you build the serving in
  your application.
  """
  def new(opts \\ []) do
    %__MODULE__{
      serving: Keyword.fetch!(opts, :serving),
      runner_module: Keyword.get(opts, :runner_module, Nx.Serving),
      default_opts: Keyword.get(opts, :default_opts, []),
      prompt_builder: Keyword.get(opts, :prompt_builder, &__MODULE__.messages_to_prompt/1),
      available_fun: Keyword.get(opts, :available_fun, &__MODULE__.nx_serving_available?/0)
    }
  end

  @doc """
  Return `true` if `Nx.Serving` is available at runtime.

  This is the runtime requirement for `Dspy.LM.Bumblebee.new(serving: ...)`.
  """
  def available?, do: nx_serving_available?()

  @doc """
  Return `true` if Nx.Serving can be used at runtime.

  This is the runtime requirement for `Dspy.LM.Bumblebee.new(serving: ...)`.
  """
  def nx_serving_available? do
    Code.ensure_loaded?(Nx) and Code.ensure_loaded?(Nx.Serving)
  end

  @doc """
  Return `true` if the `Bumblebee` module is available at runtime.

  This is only required if you want to *load models* at runtime. If you already
  have an `Nx.Serving` built, the adapter only needs Nx.
  """
  def bumblebee_loaded? do
    Code.ensure_loaded?(Bumblebee)
  end

  @impl true
  def supports?(_lm, feature) do
    case feature do
      # NOTE: this adapter accepts `messages` inputs, but it is *not* template-aware
      # chat (it linearizes messages into a single prompt).
      :generate -> true
      :text_generation -> true
      :chat -> true
      :tools -> false
      :multipart -> false
      :attachments -> false
      _ -> false
    end
  end

  @impl true
  def generate(%__MODULE__{} = lm, request) when is_map(request) do
    with :ok <- ensure_available(lm),
         {:ok, prompt} <- request_to_prompt(lm, request),
         {:ok, opts} <- request_to_runner_opts(lm, request),
         {:ok, output} <- run(lm, prompt, opts),
         {:ok, text} <- extract_text(output) do
      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: text},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_available(%__MODULE__{} = lm) do
    if lm.available_fun.() do
      :ok
    else
      {:error, :bumblebee_not_available}
    end
  end

  defp request_to_prompt(%__MODULE__{} = lm, request) do
    tools = Map.get(request, :tools) || Map.get(request, "tools")

    cond do
      tools in [nil, []] ->
        :ok

      true ->
        {:error, :tools_not_supported}
    end
    |> case do
      :ok ->
        messages = Map.get(request, :messages) || Map.get(request, "messages")

        cond do
          is_list(messages) ->
            if Enum.all?(messages, fn m -> text_only_message?(m) end) do
              {:ok, lm.prompt_builder.(messages)}
            else
              {:error, :unsupported_message_shape}
            end

          true ->
            prompt =
              Map.get(request, :prompt) || Map.get(request, "prompt") ||
                Map.get(request, :text) || Map.get(request, "text") ||
                Map.get(request, :input) || Map.get(request, "input")

            if is_binary(prompt) do
              {:ok, prompt}
            else
              {:error, :missing_prompt}
            end
        end

      {:error, _} = err ->
        err
    end
  end

  defp text_only_message?(%{role: role, content: content})
       when is_binary(role) and is_binary(content),
       do: true

  defp text_only_message?(%{"role" => role, "content" => content})
       when is_binary(role) and is_binary(content),
       do: true

  defp text_only_message?(_), do: false

  @doc """
  Convert a list of `%{role, content}` messages to a single prompt string.

  This is a simple, deterministic linearization. Many instruct/chat models
  require a model-specific chat template; for those, supply your own
  `:prompt_builder`.
  """
  def messages_to_prompt(messages) when is_list(messages) do
    messages
    |> Enum.map(fn msg ->
      %{role: role, content: content} = normalize_message(msg)

      prefix =
        case role do
          "system" -> "System"
          "assistant" -> "Assistant"
          _ -> "User"
        end

      "#{prefix}: #{content}"
    end)
    |> Enum.join("\n")
  end

  defp normalize_message(%{role: role, content: content}), do: %{role: role, content: content}

  defp normalize_message(%{"role" => role, "content" => content}),
    do: %{role: role, content: content}

  defp request_to_runner_opts(%__MODULE__{} = lm, request) do
    # Many Bumblebee servables bake generation options in at build-time.
    # We still pass opts if the runner supports `run/3`.
    # Bumblebee generation typically uses `:max_new_tokens`.
    max_tokens = Map.get(request, :max_tokens) || Map.get(request, "max_tokens")
    temperature = Map.get(request, :temperature) || Map.get(request, "temperature")
    stop = Map.get(request, :stop) || Map.get(request, "stop")

    with {:ok, max_tokens} <- validate_max_tokens(max_tokens),
         {:ok, temperature} <- validate_temperature(temperature),
         {:ok, stop} <- validate_stop(stop) do
      request_opts =
        []
        |> maybe_put(:max_new_tokens, max_tokens)
        |> maybe_put(:temperature, temperature)
        |> maybe_put(:stop, stop)

      {:ok, Keyword.merge(lm.default_opts, request_opts)}
    end
  end

  defp validate_max_tokens(nil), do: {:ok, nil}
  defp validate_max_tokens(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp validate_max_tokens(other), do: {:error, {:invalid_request_opt, :max_tokens, other}}

  defp validate_temperature(nil), do: {:ok, nil}
  defp validate_temperature(t) when is_number(t), do: {:ok, t}
  defp validate_temperature(other), do: {:error, {:invalid_request_opt, :temperature, other}}

  defp validate_stop(nil), do: {:ok, nil}
  defp validate_stop(stop) when is_binary(stop), do: {:ok, [stop]}

  defp validate_stop(stop) when is_list(stop) do
    if Enum.all?(stop, &is_binary/1) do
      {:ok, stop}
    else
      {:error, {:invalid_request_opt, :stop, stop}}
    end
  end

  defp validate_stop(other), do: {:error, {:invalid_request_opt, :stop, other}}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp run(%__MODULE__{} = lm, prompt, opts) when is_binary(prompt) and is_list(opts) do
    cond do
      function_exported?(lm.runner_module, :run, 3) ->
        {:ok, lm.runner_module.run(lm.serving, prompt, opts)}

      function_exported?(lm.runner_module, :run, 2) ->
        # Ignore opts
        {:ok, lm.runner_module.run(lm.serving, prompt)}

      true ->
        {:error, :invalid_runner_module}
    end
  rescue
    e ->
      {:error, {:runner_error, e.__struct__, Exception.message(e)}}
  catch
    kind, reason ->
      {:error, {:runner_error, kind, reason}}
  end

  defp extract_text(text) when is_binary(text), do: {:ok, text}

  defp extract_text(%{results: [%{text: text} | _]}) when is_binary(text), do: {:ok, text}
  defp extract_text(%{"results" => [%{"text" => text} | _]}) when is_binary(text), do: {:ok, text}

  defp extract_text(%{text: text}) when is_binary(text), do: {:ok, text}
  defp extract_text(%{"text" => text}) when is_binary(text), do: {:ok, text}

  defp extract_text(other), do: {:error, {:unexpected_runner_output, summarize_output(other)}}

  defp summarize_output(v) when is_binary(v), do: %{type: :binary, bytes: byte_size(v)}
  defp summarize_output(v) when is_list(v), do: %{type: :list, length: length(v)}

  defp summarize_output(v) when is_map(v) do
    keys = Map.keys(v)

    %{
      type: :map,
      keys_count: length(keys),
      keys_sample: keys |> Enum.take(20)
    }
  end

  defp summarize_output(v) do
    struct = if is_struct(v), do: v.__struct__, else: nil
    %{type: :other, struct: struct || :none}
  end
end
