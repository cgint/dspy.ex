defmodule Dspy.Attachments do
  @moduledoc """
  Minimal attachment wrapper used to send non-text context (e.g. PDFs) alongside prompts.

  This is a lightweight, provider-agnostic representation.

  Today it is primarily used by `Dspy.Predict` to build multimodal request maps
  where the user message `content` is a list of parts, starting with a text part
  and followed by attachment parts.

  The intent is to support the `dspy-intro` workflow `simplest_dspy_with_attachments.py`
  in an offline/deterministic manner.
  """

  defstruct [:items]

  @type item :: %{
          type: :file,
          path: String.t(),
          mime_type: String.t() | nil
        }

  @type t :: %__MODULE__{items: [item()]}

  @spec new(String.t() | [String.t()] | [item()]) :: t()
  def new(path) when is_binary(path) do
    %__MODULE__{items: [file_item(path)]}
  end

  def new(paths) when is_list(paths) do
    items =
      Enum.map(paths, fn
        path when is_binary(path) ->
          file_item(path)

        %{type: :file, path: path} = item when is_binary(path) ->
          normalize_item(item)

        other ->
          raise ArgumentError, "Invalid attachment item: #{inspect(other)}"
      end)

    %__MODULE__{items: items}
  end

  @spec to_message_parts(t()) :: [map()]
  def to_message_parts(%__MODULE__{items: items}) do
    Enum.map(items, fn %{type: :file, path: path, mime_type: mime_type} ->
      part = %{"type" => "input_file", "file_path" => path}

      if is_binary(mime_type) and mime_type != "" do
        Map.put(part, "mime_type", mime_type)
      else
        part
      end
    end)
  end

  defp file_item(path) do
    %{type: :file, path: path, mime_type: mime_type_for_path(path)}
  end

  defp normalize_item(%{type: :file, path: path} = item) when is_binary(path) do
    Map.put_new(item, :mime_type, mime_type_for_path(path))
  end

  defp mime_type_for_path(path) do
    case String.downcase(Path.extname(path)) do
      ".pdf" -> "application/pdf"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      _ -> nil
    end
  end
end

defimpl String.Chars, for: Dspy.Attachments do
  def to_string(%Dspy.Attachments{items: items}) do
    paths = Enum.map(items, & &1.path)
    "<attachments: #{Enum.join(paths, ", ")}>"
  end
end
