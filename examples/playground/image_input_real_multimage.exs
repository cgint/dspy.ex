# Real-model E2E: MULTIPLE images in ONE forward (list :image field).
#
# One `Dspy.Predict.forward` carries a list of three page images; the model must
# name each page's dominant color in order. Proves the marker-free splicing
# (sentinel -> image_url parts) keeps per-page images in the right positions.
#
# NOTE on backends: this only works against models whose chat template/server
# can handle multiple image parts. Verified live (2026-10-03) against
# qwen3.8-27b (SGLang via litellm). The llama.cpp judge build (v9653) silently
# drops the 2nd of adjacent same-dimension images (upstream #27313, fixed in
# #27348) — use image_input_real_per_page.exs for that backend.
#
# Run (needs the LAN + litellm on pluto):
#   mix run examples/playground/image_input_real_multimage.exs

defmodule ImageInputRealMultImage do
  @model System.get_env("E2E_MODEL", "qwen3.8-27b-nvfp4-dflash2-direct")
  @base_url System.get_env("E2E_BASE_URL", "http://pluto:40115/v1")

  # 512x384 solid-color pages, generated once (embedded so the example is
  # self-contained): red, blue, green.
  @pages [
    "iVBORw0KGgoAAAANSUhEUgAAAgAAAAGAAQMAAADh7kj8AAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAADUExURf8AABniCTcAAAAHdElNRQfqCgMTIwSEqotaAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTEwLTAzVDE5OjM1OjA0KzAwOjAwo9zRDgAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0xMC0wM1QxOTozNTowNCswMDowMNKBabIAAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMTAtMDNUMTk6MzU6MDQrMDA6MDCFlEhtAAAAL0lEQVR42u3BAQ0AAADCoPdPbQ43oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAL4NYYAAAX2hjmgAAAAASUVORK5CYII=",
    "iVBORw0KGgoAAAANSUhEUgAAAgAAAAGAAQMAAADh7kj8AAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAADUExURQAA/4p40lcAAAAHdElNRQfqCgMTIwSEqotaAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTEwLTAzVDE5OjM1OjA0KzAwOjAwo9zRDgAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0xMC0wM1QxOTozNTowNCswMDowMNKBabIAAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMTAtMDNUMTk6MzU6MDQrMDA6MDCFlEhtAAAAL0lEQVR42u3BAQ0AAADCoPdPbQ43oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAL4NYYAAAX2hjmgAAAAASUVORK5CYII=",
    "iVBORw0KGgoAAAANSUhEUgAAAgAAAAGAAQMAAADh7kj8AAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAADUExURQCAAJz5pZEAAAAHdElNRQfqCgMTIwSEqotaAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTEwLTAzVDE5OjM1OjA0KzAwOjAwo9zRDgAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0xMC0wM1QxOTozNTowNCswMDowMNKBabIAAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMTAtMDNUMTk6MzU6MDQrMDA6MDCFlEhtAAAAL0lEQVR42u3BAQ0AAADCoPdPbQ43oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAL4NYYAAAX2hjmgAAAAASUVORK5CYII="
  ]

  defmodule PageSig do
    use Dspy.Signature

    input_field(:page_images, :image, "Rendered pages of the document, in order")
    input_field(:document_title, :string, "The document title")
    output_field(:page_readings, :string, "For each page, in order, the dominant color you see")
  end

  def run do
    IO.puts("== dspy.ex multi-image forward -> #{@model} (#{@base_url}) =========")

    {:ok, lm} = Dspy.LM.new("openai:#{@model}", base_url: @base_url, api_key: "sk-dummy")
    Dspy.configure(lm: lm, temperature: 0.0, max_tokens: 300, cache: false)

    pages =
      for b64 <- @pages,
          do: Dspy.Image.new_data(Base.decode64!(b64), "image/png")

    result =
      Dspy.Module.forward(Dspy.Predict.new(PageSig), %{
        page_images: pages,
        document_title: "Color Report"
      })

    case result do
      {:ok, pred} ->
        readings = pred.attrs.page_readings
        lowered = String.downcase(readings)
        IO.puts("\nmodel said: #{readings}")

        checks = [
          {"page 1 -> red", String.contains?(lowered, "red")},
          {"page 2 -> blue", String.contains?(lowered, "blue")},
          {"page 3 -> green", String.contains?(lowered, "green")}
        ]

        IO.puts("\nchecks:")
        Enum.each(checks, fn {label, ok} ->
          IO.puts("#{if ok, do: "  PASS", else: "  FAIL"}  #{label}")
        end)

        if Enum.all?(checks, &elem(&1, 1)) do
          IO.puts("\nALL PASS — all images flowed through the signature, in order.")
        else
          raise "SOME CHECKS FAILED — inspect the readings above"
        end

      {:error, reason} ->
        raise "forward failed: #{inspect(reason, limit: 100, printable_limit: 400)}"
    end
  end
end

ImageInputRealMultImage.run()
