defmodule Dspy.ImageTest do
  use ExUnit.Case, async: true

  setup do
    dir = System.tmp_dir!()
    path = Path.join(dir, "dspy_image_test_#{System.unique_integer([:positive])}.png")
    File.write!(path, "AAAA")
    on_exit(fn -> File.rm(path) end)
    %{png_path: path}
  end

  describe "new/2" do
    test "data URIs pass through unchanged" do
      uri = "data:image/png;base64,QUJD"
      assert %Dspy.Image{url: ^uri} = Dspy.Image.new(uri)
      assert Dspy.Image.data_uri?(Dspy.Image.new(uri))
      refute Dspy.Image.url?(Dspy.Image.new(uri))
    end

    test "http/https/gs URLs pass through unchanged (no download)" do
      for url <- [
            "https://example.com/img.png",
            "http://example.com/img.jpg",
            "gs://bucket/path/to/img.webp"
          ] do
        assert %Dspy.Image{url: ^url} = Dspy.Image.new(url)
        assert Dspy.Image.url?(Dspy.Image.new(url))
        refute Dspy.Image.data_uri?(Dspy.Image.new(url))
      end
    end

    test "local file is encoded to a base64 data URI with extension MIME", %{png_path: path} do
      assert %Dspy.Image{url: url} = Dspy.Image.new(path)
      assert url == "data:image/png;base64,#{Base.encode64("AAAA")}"
    end

    test "local file with unknown extension requires mime_type override" do
      path =
        Path.join(
          System.tmp_dir!(),
          "dspy_image_test_unknown_#{System.unique_integer([:positive])}.img"
        )

      File.write!(path, "BB")
      on_exit(fn -> File.rm(path) end)

      assert_raise ArgumentError, ~r/Could not determine MIME type/, fn ->
        Dspy.Image.new(path)
      end

      expected = "data:image/png;base64,#{Base.encode64("BB")}"

      assert %Dspy.Image{url: ^expected} =
               Dspy.Image.new(path, mime_type: "image/png")
    end

    test "missing local file raises" do
      missing = Path.join(System.tmp_dir!(), "dspy_image_test_missing_#{System.unique_integer([:positive])}.png")
      assert_raise ArgumentError, ~r/Could not determine MIME type|Unrecognized image source/, fn ->
        Dspy.Image.new(missing)
      end
    end

    test "unrecognized source strings raise" do
      assert_raise ArgumentError, ~r/Unrecognized image source/, fn ->
        Dspy.Image.new("not a url or path")
      end
    end

    test "raw image bytes raise a clean ArgumentError (URI parsing must not crash)" do
      # Real PNG bytes: NUL bytes and invalid UTF-8. URI.new/1 raises
      # ErlangError on these; new/2 must convert that into the documented
      # ArgumentError pointing at new_data/2.
      raw_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00"
      assert_raise ArgumentError, ~r/Unrecognized image source.*new_data/s, fn ->
        Dspy.Image.new(raw_png)
      end
    end

    test "non-binary sources raise" do
      assert_raise ArgumentError, ~r/must be a binary string/, fn ->
        Dspy.Image.new(42)
      end
    end
  end

  describe "new_data/2" do
    test "encodes raw bytes with explicit MIME" do
      expected = "data:image/jpeg;base64,#{Base.encode64("JJ")}"
      assert %Dspy.Image{url: ^expected} = Dspy.Image.new_data("JJ", "image/jpeg")
    end

    test "invalid arguments raise" do
      assert_raise ArgumentError, fn -> Dspy.Image.new_data("JJ", "") end
      assert_raise ArgumentError, fn -> Dspy.Image.new_data(42, "image/png") end
    end
  end

  describe "format/1" do
    test "returns image_url content parts (Python Image.format parity)" do
      img = Dspy.Image.new("https://example.com/img.png")

      assert Dspy.Image.format(img) == [
               %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/img.png"}}
             ]
    end
  end

  test "no String.Chars: coercing an image to a string is refused, never leaks" do
    img = Dspy.Image.new("data:image/png;base64,QUFBQUI=")

    # Deliberately unimplemented: string interpolation of an image would either
    # leak base64 into prompt text or emit a backend-breaking marker token.
    # (as_term/1 erases the static type so the probe stays warning-free.)
    assert_raise Protocol.UndefinedError, fn -> to_string(as_term(img)) end
  end

  defp as_term(value) do
    value
  end
end
