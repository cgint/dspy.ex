defmodule Dspy.LM do
  @moduledoc """
  Behaviour for language model clients.

  Defines the interface for interacting with different language model providers
  like OpenAI, Anthropic, local models, etc.
  """

  @type message :: %{
          role: String.t(),
          content: String.t()
        }

  @type request :: %{
          messages: [message()] | nil,
          max_tokens: pos_integer() | nil,
          temperature: float() | nil,
          stop: [String.t()] | nil,
          tools: [map()] | nil,
          # Additional fields for different model types
          input: String.t() | nil,
          text: String.t() | nil,
          prompt: String.t() | nil,
          file: String.t() | nil,
          n: pos_integer() | nil,
          size: String.t() | nil,
          voice: String.t() | nil,
          response_format: map() | nil
        }

  @type response :: %{
          choices: [
            %{
              message: message(),
              finish_reason: String.t() | nil
            }
          ],
          usage:
            %{
              prompt_tokens: pos_integer(),
              completion_tokens: pos_integer(),
              total_tokens: pos_integer()
            }
            | nil
        }

  @type t :: struct()

  @doc """
  Generate a completion from the language model.
  """
  @callback generate(lm :: t(), request :: request()) :: {:ok, response()} | {:error, any()}

  @doc """
  Check if the language model supports a specific feature.
  """
  @callback supports?(lm :: t(), feature :: atom()) :: boolean()

  @optional_callbacks [supports?: 2]

  @doc """
  Generate a completion using the configured language model.
  """
  def generate(request) do
    case Dspy.Settings.get(:lm) do
      nil -> {:error, :no_lm_configured}
      lm -> generate(lm, request)
    end
  end

  @doc """
  Generate a completion using a specific language model.

  This function also applies global defaults from `Dspy.Settings` (if running)
  for request fields like `:temperature` and `:max_tokens`, without overriding
  per-request values.
  """
  def generate(lm, request) do
    request = apply_settings_defaults(request)
    lm.__struct__.generate(lm, request)
  end

  @doc """
  Backwards-compatible helper for call sites that pass a prompt string + options.

  Prefer calling `generate/2` with a request map in new code.
  """
  def generate(lm, prompt, opts) when is_binary(prompt) and is_list(opts) do
    generate_text(lm, prompt, opts)
  end

  @doc """
  Generate text from a simple prompt string.
  """
  def generate_text(prompt, opts \\ []) do
    case Dspy.Settings.get(:lm) do
      nil -> {:error, :no_lm_configured}
      lm -> generate_text(lm, prompt, opts)
    end
  end

  @doc """
  Generate text from a prompt string using a specific language model.
  """
  def generate_text(lm, prompt, opts) when is_binary(prompt) and is_list(opts) do
    request = %{
      messages: [%{role: "user", content: prompt}],
      max_tokens: Keyword.get(opts, :max_tokens),
      temperature: Keyword.get(opts, :temperature),
      stop: Keyword.get(opts, :stop),
      tools: Keyword.get(opts, :tools)
    }

    with {:ok, response} <- generate(lm, request) do
      text_from_response(response)
    end
  end

  @doc """
  Extract the first assistant message content from a model response.

  Accepts both atom-keyed and string-keyed response maps.
  """
  @spec text_from_response(response() | String.t()) :: {:ok, String.t()} | {:error, any()}
  def text_from_response(response) when is_binary(response), do: {:ok, response}

  def text_from_response(response) do
    case get_in(response, [:choices, Access.at(0), :message]) do
      %{"content" => content} when is_binary(content) -> {:ok, content}
      # Support atom keys
      %{content: content} when is_binary(content) -> {:ok, content}
      message -> {:error, {:missing_content, message}}
    end
  end

  @doc """
  Check if a language model supports a feature.
  """
  def supports?(lm, feature) do
    if function_exported?(lm.__struct__, :supports?, 2) do
      lm.__struct__.supports?(lm, feature)
    else
      false
    end
  end

  @doc """
  Create a chat message.
  """
  def message(role, content) do
    %{role: to_string(role), content: content}
  end

  @doc """
  Create a user message.
  """
  def user_message(content), do: message("user", content)

  @doc """
  Create an assistant message.
  """
  def assistant_message(content), do: message("assistant", content)

  @doc """
  Create a system message.
  """
  def system_message(content), do: message("system", content)

  @doc """
  Create a request for embedding generation.
  """
  def embedding_request(text, opts \\ []) do
    %{
      input: text,
      encoding_format: Keyword.get(opts, :encoding_format, "float"),
      dimensions: Keyword.get(opts, :dimensions)
    }
  end

  @doc """
  Create a request for image generation.
  """
  def image_request(prompt, opts \\ []) do
    %{
      prompt: prompt,
      n: Keyword.get(opts, :n, 1),
      size: Keyword.get(opts, :size, "1024x1024"),
      quality: Keyword.get(opts, :quality, "standard"),
      style: Keyword.get(opts, :style, "vivid")
    }
  end

  @doc """
  Create a request for text-to-speech.
  """
  def tts_request(text, opts \\ []) do
    %{
      input: text,
      voice: Keyword.get(opts, :voice, "alloy"),
      response_format: Keyword.get(opts, :response_format, "mp3"),
      speed: Keyword.get(opts, :speed, 1.0)
    }
  end

  @doc """
  Create a request for speech-to-text transcription.
  """
  def transcription_request(file, opts \\ []) do
    %{
      file: file,
      language: Keyword.get(opts, :language),
      prompt: Keyword.get(opts, :prompt),
      response_format: Keyword.get(opts, :response_format, "json"),
      temperature: Keyword.get(opts, :temperature, 0)
    }
  end

  @doc """
  Create a request for content moderation.
  """
  def moderation_request(content, opts \\ []) do
    %{
      input: content,
      model: Keyword.get(opts, :model, "omni-moderation-latest")
    }
  end

  @doc """
  Generate structured output from a signature and inputs.
  """
  def generate_structured_output(signature, inputs) do
    # Build the prompt from the signature
    prompt = Dspy.Signature.to_prompt(signature)

    # Add the input values to the prompt
    input_text =
      inputs
      |> Enum.map(fn {key, value} ->
        field_name = key |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
        "#{field_name}: #{inspect(value)}"
      end)
      |> Enum.join("\n")

    full_prompt = "#{prompt}\n\n#{input_text}"

    # Generate the response
    case generate_text(full_prompt) do
      {:ok, response_text} ->
        # Parse the outputs according to the signature
        outputs = Dspy.Signature.parse_outputs(signature, response_text)
        {:ok, outputs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_settings_defaults(request) when is_map(request) do
    if Process.whereis(Dspy.Settings) do
      request
      |> put_default(:temperature, Dspy.Settings.get(:temperature))
      |> put_default(:max_tokens, Dspy.Settings.get(:max_tokens))
    else
      request
    end
  end

  defp apply_settings_defaults(other), do: other

  defp put_default(request, _key, nil), do: request

  defp put_default(request, key, default) do
    case Map.get(request, key) do
      nil -> Map.put(request, key, default)
      _ -> request
    end
  end
end
