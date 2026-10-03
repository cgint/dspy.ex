# Real-model E2E: ONE image PER forward (consumer shape: per-page forward +
# aggregate). Three separate `Dspy.Predict.forward` calls, each carrying a
# single :image field; page order is guaranteed by the application loop, not by
# the model.
#
# This is the acceptance shape for backends whose server cannot reliably handle
# multiple adjacent image parts — verified live (2026-10-03) against the
# llama.cpp judge (qwen36-35b, whose build v9653 predates upstream fix #27348
# for #27313: 2nd of adjacent same-dimension images silently dropped).
#
# Run (needs the LAN + litellm on pluto):
#   mix run examples/playground/image_input_real_per_page.exs

defmodule ImageInputRealPerPage do
  @model System.get_env("E2E_MODEL", "qwen36-35b-judge-sparky-direct")
  @base_url System.get_env("E2E_BASE_URL", "http://pluto:40115/v1")

  # 512x384 solid-color pages (embedded, self-contained): red, blue, green.
  @pages [
    "iVBORw0KGgoAAAANSUhEUgAAAgAAAAGAAQMAAADh7kj8AAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAADUExURf8AABniCTcAAAAHdElNRQfqCgMTIwSEqotaAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTEwLTAzVDE5OjM1OjA0KzAwOjAwo9zRDgAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0xMC0wM1QxOTozNTowNCswMDowMNKBabIAAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMTAtMDNUMTk6MzU6MDQrMDA6MDCFlEhtAAAAL0lEQVR42u3BAQ0AAADCoPdPbQ43oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAL4NYYAAAX2hjmgAAAAASUVORK5CYII=",
    "iVBORw0KGgoAAAANSUhEUgAAAgAAAAGAAQMAAADh7kj8AAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAADUExURQAA/4p40lcAAAAHdElNRQfqCgMTIwSEqotaAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTEwLTAzVDE5OjM1OjA0KzAwOjAwo9zRDgAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0xMC0wM1QxOTozNTowNCswMDowMNKBabIAAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMTAtMDNUMTk6MzU6MDQrMDA6MDCFlEhtAAAAL0lEQVR42u3BAQ0AAADCoPdPbQ43oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAL4NYYAAAX2hjmgAAAAASUVORK5CYII=",
    "iVBORw0KGgoAAAANSUhEUgAAAgAAAAGAAQMAAADh7kj8AAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAADUExURQCAAJz5pZEAAAAHdElNRQfqCgMTIwSEqotaAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTEwLTAzVDE5OjM1OjA0KzAwOjAwo9zRDgAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0xMC0wM1QxOTozNTowNCswMDowMNKBabIAAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMTAtMDNUMTk6MzU6MDQrMDA6MDCFlEhtAAAAL0lEQVR42u3BAQ0AAADCoPdPbQ43oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAL4NYYAAAX2hjmgAAAAASUVORK5CYII="
  ]

  defmodule PageSig do
    use Dspy.Signature

    input_field(:page_image, :image, "Rendered page of the document")
    input_field(:page_number, :integer, "Page number")
    input_field(:document_title, :string, "The document title")
    output_field(:reading, :string, "The dominant color you see on this page, one word")
  end

  def run do
    IO.puts("== dspy.ex per-page single-image forwards -> #{@model} (#{@base_url}) ==")

    {:ok, lm} = Dspy.LM.new("openai:#{@model}", base_url: @base_url, api_key: "sk-dummy")
    Dspy.configure(lm: lm, temperature: 0.0, max_tokens: 100, cache: false)
    predict = Dspy.Predict.new(PageSig)

    readings =
      for {b64, n} <- Enum.with_index(@pages, 1) do
        page = Dspy.Image.new_data(Base.decode64!(b64), "image/png")

        case Dspy.Module.forward(predict, %{
               page_image: page,
               page_number: n,
               document_title: "Color Report"
             }) do
          {:ok, pred} ->
            IO.puts("page #{n}: #{pred.attrs.reading}")
            pred.attrs.reading

          {:error, reason} ->
            raise "forward #{n} failed: #{inspect(reason, limit: 100, printable_limit: 300)}"
        end
      end

    expected = ["red", "blue", "green"]

    checks =
      for {reading, n} <- Enum.with_index(readings, 1) do
        {
          "page #{n} -> #{Enum.at(expected, n - 1)}",
          String.downcase(reading) =~ ~r/#{Enum.at(expected, n - 1)}/
        }
      end

    IO.puts("\nchecks:")
    Enum.each(checks, fn {label, ok} ->
      IO.puts("#{if ok, do: "  PASS", else: "  FAIL"}  #{label}")
    end)

    if Enum.all?(checks, &elem(&1, 1)) do
      IO.puts("\nALL PASS — single-image forwards work; order preserved by the loop.")
    else
      raise "SOME CHECKS FAILED — readings: #{inspect(readings)}"
    end
  end
end

ImageInputRealPerPage.run()
