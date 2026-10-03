defmodule Dspy.Image do
  @moduledoc ~S"""
  First-class image input value (Elixir parity for Python's `dspy.Image`).

  An `Image` normalizes its source into one of two wire forms at construction
  time (eager, matching Python's `dspy.Image.__init__`):

  - a **base64 data URI** (`data:image/png;base64,...`) for local files / raw
    bytes
  - a **plain URL** (`http://`, `https://`, `gs://`) or an already-encoded data
    URI — kept as-is, never downloaded (Python's `download: false` default)

  `format/1` renders the value as OpenAI-style `image_url` content parts, the
  same shape `Dspy.LM.ReqLLM` already transports.

  ## Usage in signatures

      defmodule DescribePage do
        use Dspy.Signature

        input_field(:page_image, :image, "A rendered page of the document")
        output_field(:summary, :string, "A short summary")
      end

      Dspy.Predict.new(DescribePage)
      |> Dspy.Predict.forward(%{page_image: Dspy.Image.new("./page.png")})

  Multiple images for one field: pass a list of `Dspy.Image` values; the parts
  are spliced into the user message content at the field position, in list
  order (no marker tokens or image bytes appear in the prompt text).

  ## Migration note (from hand-built raw requests)

  `Image` deliberately does **not** implement `String.Chars`: interpolating
  one into a prompt string (`"#{image}"`) raises `Protocol.UndefinedError`
  instead of leaking base64 or a backend-breaking marker into text. When
  migrating a raw `image_url`-building request to a signature, pass the image
  through a `:image` input field and let the adapter pipeline render it —
  never build the content parts by hand around string interpolation.

  Note: `Dspy.Image` deliberately implements no `String.Chars` — coercing an
  image to a string would either leak base64 into prompt text or emit a
  backend-breaking marker. Use `url/1`, `data_uri?/1`, or `format/1`.

  ## Parity notes (Python `dspy.Image`)

  - local files and raw bytes are base64-encoded eagerly (at construction);
    failures (missing file, unknown MIME) raise `ArgumentError` up front
  - URLs are kept as plain URLs (no network fetch by default)
  - Python's PIL image input has no BEAM equivalent and is out of scope
  """

  @enforce_keys [:url]
  defstruct [:url]

  @type t :: %__MODULE__{url: String.t()}

  @image_mime_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".bmp" => "image/bmp",
    ".tif" => "image/tiff",
    ".tiff" => "image/tiff",
    ".svg" => "image/svg+xml"
  }

  @doc """
  Create an image value from a source.

  Accepted sources (binary strings):

  - an already-encoded data URI (`data:...`) — kept as-is
  - an `http://`, `https://`, or `gs://` URL — kept as-is (never downloaded)
  - a local file path — read and base64-encoded into a data URI; the MIME type
    is derived from the file extension (override with `mime_type:`)

  Options:

  - `:mime_type` — MIME type override for local files

  Raises `ArgumentError` for unrecognized sources. For raw image bytes use
  `new_data/2`.
  """
  @spec new(term(), keyword()) :: t()
  def new(source, opts \\ []) do
    unless is_binary(source) do
      raise ArgumentError,
            "Dspy.Image.new/2 source must be a binary string (data URI, URL, or file path); " <>
              "got: #{inspect(source)}"
    end

    url =
      cond do
        String.starts_with?(source, "data:") ->
          source

        plain_url?(source) ->
          source

        File.regular?(source) ->
          mime = mime_for_path(source, Keyword.get(opts, :mime_type))
          data = File.read!(source)
          "data:#{mime};base64,#{Base.encode64(data, chunk_size: 76)}"

        true ->
          raise ArgumentError,
                "Unrecognized image source: #{inspect(String.slice(source, 0, 80))}; " <>
                  "expected a data: URI, an http(s)/gs URL, or an existing local file path. " <>
                  "For raw image bytes use Dspy.Image.new_data/2."
      end

    %__MODULE__{url: url}
  end

  @doc """
  Create an image value from raw image bytes (parity with passing `bytes` to
  Python's `dspy.Image`).

  `mime_type` is required because Elixir binaries carry no extension
  information.
  """
  @spec new_data(binary(), String.t()) :: t()
  def new_data(bytes, mime_type) when is_binary(bytes) and is_binary(mime_type) and mime_type != "" do
    %__MODULE__{url: "data:#{mime_type};base64,#{Base.encode64(bytes, chunk_size: 76)}"}
  end

  def new_data(bytes, mime_type) do
    raise ArgumentError,
          "new_data/2 requires a binary payload and a non-empty MIME type string; " <>
            "got bytes: #{if is_binary(bytes), do: byte_size(bytes), else: inspect(bytes)}, " <>
            "mime_type: #{inspect(mime_type)}"
  end

  @doc """
  Render the image as OpenAI-style `image_url` content part(s)
  (parity with Python `Image.format/1`).
  """
  @spec format(t()) :: [map()]
  def format(%__MODULE__{url: url}) do
    [%{"type" => "image_url", "image_url" => %{"url" => url}}]
  end

  @doc "True if the stored URL is a base64 data URI."
  @spec data_uri?(t()) :: boolean()
  def data_uri?(%__MODULE__{url: url}), do: String.starts_with?(url, "data:")

  @doc "True if the stored URL is a plain (http/https/gs) URL."
  @spec url?(t()) :: boolean()
  def url?(%__MODULE__{url: url}), do: plain_url?(url)

  defp plain_url?(source) do
    uri =
      try do
        URI.new(source)
      rescue
        # Raw image bytes / invalid encoding make URI.new/1 raise ErlangError;
        # that is "not a URL", not a crash site.
        _ -> {:error, :not_a_uri}
      end

    case uri do
      {:ok, %URI{scheme: scheme, host: host}} ->
        scheme in ["http", "https", "gs"] and is_binary(host) and host != ""

      _ ->
        false
    end
  end

  defp mime_for_path(path, override) do
    case override do
      mime when is_binary(mime) and mime != "" ->
        mime

      _ ->
        Map.get(@image_mime_types, Path.extname(path) |> String.downcase()) ||
          raise ArgumentError,
                "Could not determine MIME type for #{inspect(path)}; " <>
                  "pass mime_type: \"<type>\" (e.g. mime_type: \"image/png\")."
    end
  end
end
