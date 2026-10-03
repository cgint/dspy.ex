# Offline, deterministic proof: first-class IMAGE INPUT in dspy.ex.
#
# This is the playground prototype for the feature that makes the
# OptimusTower/overview-app "raw seam" obsolete: instead of hand-building
# `messages` with `image_url` data: base64 parts and calling
# `Dspy.LM.generate/2` directly (while carrying a fossilized Python
# signature whose fields never receive data), a consumer now writes:
#
#     input_field(:page_images, :image, "Per-page images, in order")
#     Dspy.Predict.forward(program, %{page_images: [Dspy.Image.new("p1.png"), ...]})
#
# and the framework renders `<image>` prompt markers and appends ordered
# `image_url` content parts — the exact request the raw seam built by hand.
#
# Run:
#   mix run examples/playground/image_input_offline.exs

defmodule ImageInputOfflineDemo do
  @moduledoc false

  # --- a deterministic recording LM (no network) ------------------------------

  defmodule RecordingLM do
    @behaviour Dspy.LM
    defstruct [:pid, :script]

    @impl true
    def generate(%{pid: pid} = lm, request) do
      send(pid, {:lm_request, request})

      content =
        Agent.get_and_update(lm.script, fn
          {contents, n} ->
            [head | tail] = contents
            {head, {tail, n + 1}}
        end)

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  # --- the consumer's shape: a PDF, one rendered image per page ---------------

  defmodule ExtractPageInfo do
    use Dspy.Signature

    input_field(:page_images, :image, "Rendered pages of the document, in order")
    input_field(:document_title, :string, "The document title")
    output_field(:extracted_data, :string, "Extracted document data as JSON text")
  end

  def run do
    IO.puts("== dspy.ex: first-class image input (offline proof) ===============")

    # two tiny stand-in "pages" (content is not decoded; only the data path matters)
    pages =
      for n <- 1..3 do
        path =
          Path.join(
            System.tmp_dir!(),
            "image_input_demo_page#{n}_#{System.unique_integer([:positive])}.png"
          )

        File.write!(path, "PAGE#{n}-BYTES")
        Dspy.Image.new(path)
      end

    {:ok, script} = Agent.start_link(fn -> {["Extracted_data: ok"], 0} end)
    lm = %RecordingLM{pid: self(), script: script}
    Dspy.configure(lm: lm)

    program = Dspy.Predict.new(ExtractPageInfo)

    IO.puts("\n-- 1. forward with first-class image values ----------------------")

    result =
      Dspy.Module.forward(program, %{
        page_images: pages,
        document_title: "Demo Document"
      })

    IO.inspect(result, label: "result")

    {:ok, pred} = result
    IO.puts("parsed output: #{inspect(pred.attrs.extracted_data)}")

    IO.puts("\n-- 2. the exact LM request the framework built -------------------")

    receive do
      {:lm_request, request} ->
        [user] = request.messages

        IO.puts("user message content parts (data URIs truncated):")

        user.content
        |> Enum.with_index()
        |> Enum.each(fn {part, i} ->
          part = Map.new(part)

          part =
            if Map.has_key?(part, "image_url") do
              nested = Map.new(part["image_url"])
              Map.put(part, "image_url", Map.put(nested, "url", truncate(nested["url"])))
            else
              part
            end

          part =
            if Map.has_key?(part, "text") do
              Map.put(part, "text", truncate(part["text"]))
            else
              part
            end

          IO.puts("  [#{i}] #{inspect(part, limit: :infinity, printable_limit: 160)}")
        end)

        text =
          user.content
          |> Enum.filter(fn part -> Map.new(part)["type"] == "text" end)
          |> Enum.map(fn part -> Map.new(part)["text"] end)
          |> Enum.join("")

        IO.puts("\n-- 3. invariants ----------------------------------------------")

        sentinel = Dspy.Signature.AdapterPipeline.image_ref_token()

        check(
          "prompt text is clean: no marker tokens, no base64 payload",
          not String.contains?(text, sentinel) and
            not String.contains?(text, "base64,") and
            not String.contains?(text, "<image>")
        )

        urls =
          user.content
          |> Enum.filter(fn part -> Map.new(part)["type"] == "image_url" end)
          |> Enum.map(fn part -> Map.new(Map.new(part)["image_url"])["url"] end)

        expected =
          Enum.map(1..3, fn n -> "data:image/png;base64,#{Base.encode64("PAGE#{n}-BYTES")}" end)

        check("image_url parts are in page order", urls == expected)
        check(
          "parts are spliced at the field position (text, 3 images, text)",
          user.content
            |> Enum.map(fn part -> Map.new(part)["type"] end)
            |> Kernel.==(["text", "image_url", "image_url", "image_url", "text"])
        )
        check(
          "data URIs are base64-encoded with image MIME (Python dspy.Image parity)",
          Enum.all?(urls, &String.starts_with?(&1, "data:image/png;base64,"))
        )

        IO.puts("\n-- 4. what this replaces (the consumer's raw seam) --------------")

        IO.puts("""
        The request above is exactly what the consumer's hand-rolled
        do_real_lm_request built manually (text part + image_url data: parts +
        Dspy.LM.generate) — with one upgrade: image parts are spliced at the
        field position with NO marker tokens in the text, which is what the
        sglang/Qwen-VL backend on pluto requires (literal image tokens in the
        text crash it with "More 'IMAGE' tokens found than corresponding data
        provided"). So

          * Dspy.ChainOfThought / adapters inherit it for free (shared pipeline)
          * prompt text stays small (no base64, no marker tokens)
          * the fossilized "Pdf_document: [input]" signature becomes a real
            signature: Dspy.Image values flow through Dspy.Predict.forward/2

        No network, no provider calls: deterministic by construction.
        """)

        :ok
    after
      2_000 ->
        raise "no LM request recorded — the image input never reached the LM"
    end
  end

  # --- small helpers -----------------------------------------------------------

  defp check(label, true) do
    IO.puts("  PASS  #{label}")
  end

  defp check(label, false) do
    IO.puts("  FAIL  #{label}")
    raise "invariant failed: #{label}"
  end

  defp truncate(nil), do: nil
  defp truncate(text), do: if(String.length(text) > 90, do: "#{String.slice(text, 0, 90)}... [truncated]", else: text)
end

ImageInputOfflineDemo.run()
