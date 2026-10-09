defmodule Dspy.ImageInputPipelineTest do
  @moduledoc """
  End-to-end tests: first-class image inputs flowing through
  Dspy.Predict.forward/2 into the LM request as `image_url` content parts.

  Proves the design properties that make the consumer raw-seam obsolete:

  - image values are spliced into the user message content as `image_url`
    parts at their field position (field-declaration order, then list order);
    the prompt text carries NO marker tokens and no base64 bytes
  - works across the default (legacy), chat, and two-step adapters
  - image values are accepted on `:image` and on `:string`-declared fields
    (Python-DSPy-style ergonomics, same escape hatch as attachments)
  - attachments and images can coexist in one request (attachments appended,
    images interleaved at field position)
  """
  use ExUnit.Case, async: false

  # --- fixtures: two distinct tiny "images" as local files -------------------

  defp write_png(name, content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "dspy_img_pipeline_#{name}_#{System.unique_integer([:positive])}.png"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp page_images() do
    page1 = Dspy.Image.new(write_png("p1", "AAAA"))
    page2 = Dspy.Image.new(write_png("p2", "BBBB"))

    %{
      page1: page1,
      page2: page2,
      expected1: "data:image/png;base64,#{Base.encode64("AAAA")}",
      expected2: "data:image/png;base64,#{Base.encode64("BBBB")}",
      inline: Dspy.Image.new("data:image/png;base64,QUJD")
    }
  end

  # --- recording LM (raw response strings, records every request) ------------

  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:pid, :script]

    @impl true
    def generate(%{pid: pid} = lm, request) do
      send(pid, {:lm_request, request})

      content =
        Agent.get_and_update(lm.script, fn
          {[], n} ->
            {{:error, {:script_exhausted, n}}, {[], n}}

          {contents, n} ->
            [head | tail] = contents
            {head, {tail, n + 1}}
        end)

      case content do
        {:error, _} = err -> err
        text -> {:ok, response(text)}
      end
    end

    @impl true
    def supports?(_lm, _feature), do: true

    defp response(text) do
      %{
        choices: [%{message: %{role: "assistant", content: text}, finish_reason: "stop"}],
        usage: nil
      }
    end
  end

  # --- signatures -------------------------------------------------------------

  defmodule ImageSig do
    use Dspy.Signature

    input_field(:document_page, :image, "A rendered page of the document")
    input_field(:page_images, :image, "Per-page images, in order")
    input_field(:note, :string, "A short note")
    output_field(:summary, :string, "A short summary")
  end

  defmodule StringImageSig do
    use Dspy.Signature

    input_field(:img, :string, "An image (Python-ergonomics escape hatch)")
    output_field(:summary, :string, "A short summary")
  end

  defmodule MixedMediaSig do
    use Dspy.Signature

    input_field(:files, :string, "File attachments")
    input_field(:page, :image, "A page image")
    output_field(:summary, :string, "A short summary")
  end

  # --- helpers ----------------------------------------------------------------

  defp start_lm(contents) do
    {:ok, script} = Agent.start_link(fn -> {contents, 0} end)
    lm = %ScriptedLM{pid: self(), script: script}
    Dspy.configure(lm: lm)
    lm
  end

  defp last_user_message(%{messages: messages} = _request) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {msg, _i} ->
      if (Map.get(msg, :role) || Map.get(msg, "role")) == "user", do: msg
    end)
  end

  defp image_urls(content) when is_list(content) do
    content
    |> Enum.filter(fn part ->
      part = Map.new(part)
      (Map.get(part, "type") || Map.get(part, :type)) == "image_url"
    end)
    |> Enum.map(fn part ->
      part = Map.new(part)
      nested = Map.new(part["image_url"] || part[:image_url])
      nested["url"] || nested[:url]
    end)
  end

  defp texts_of(content) when is_list(content) do
    content
    |> Enum.filter(fn part ->
      part = Map.new(part)
      (Map.get(part, "type") || Map.get(part, :type)) == "text"
    end)
    |> Enum.map(fn part ->
      part = Map.new(part)
      Map.get(part, "text") || Map.get(part, :text)
    end)
  end

  defp full_text(content) when is_list(content), do: Enum.join(texts_of(content), "")

  defp assert_clean_text!(text) do
    sentinel = Dspy.Signature.AdapterPipeline.image_ref_token()
    refute String.contains?(text, sentinel)
    refute String.contains?(text, "<image>")
    refute String.contains?(text, "base64,")
  end

  defp image_sig_inputs(imgs) do
    %{document_page: imgs.page1, page_images: [imgs.page2, imgs.inline], note: "hello"}
  end

  # --- tests ------------------------------------------------------------------

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "default adapter: image_url parts spliced at field position, clean prompt text" do
    imgs = page_images()
    start_lm(["Summary: done"])

    assert {:ok, pred} =
             Dspy.Module.forward(Dspy.Predict.new(ImageSig), image_sig_inputs(imgs))

    assert pred.attrs.summary == "done"
    assert_receive {:lm_request, request}, 1_000

    content = last_user_message(request).content
    text = full_text(content)

    # prompt text: field labels and values, never markers or base64 bytes
    assert String.contains?(text, "Document_page: ")
    assert String.contains?(text, "Page_images: ")
    assert String.contains?(text, "Note: hello")
    assert_clean_text!(text)
    refute String.contains?(text, imgs.expected1)

    # parts: interleaved at field position — image after its field label,
    # list order preserved within the field
    assert image_urls(content) == [imgs.expected1, imgs.expected2, "data:image/png;base64,QUJD"]

    types =
      content
      |> Enum.map(fn part ->
        part = Map.new(part)
        Map.get(part, "type") || Map.get(part, :type)
      end)

    assert types == [
             "text",
             "image_url",
             "text",
             "image_url",
             "image_url",
             "text"
           ]
  end

  test "image value on a :string-declared field (Python-ergonomics escape hatch)" do
    imgs = page_images()
    start_lm(["Summary: ok"])

    assert {:ok, _pred} =
             Dspy.Module.forward(Dspy.Predict.new(StringImageSig), %{img: imgs.page1})

    assert_receive {:lm_request, request}, 1_000
    assert image_urls(last_user_message(request).content) == [imgs.expected1]
  end

  test "attachments and images coexist: image at field position, attachment appended" do
    imgs = page_images()
    start_lm(["Summary: mixed"])

    attachments = Dspy.Attachments.new("/tmp/dspy_img_pipeline_file.pdf")

    assert {:ok, _pred} =
             Dspy.Module.forward(Dspy.Predict.new(MixedMediaSig), %{
               files: attachments,
               page: imgs.page1
             })

    assert_receive {:lm_request, request}, 1_000
    content = last_user_message(request).content
    text = full_text(content)
    assert_clean_text!(text)
    assert String.contains?(text, "Files: <attachments>")

    types =
      content
      |> Enum.map(fn part ->
        part = Map.new(part)
        Map.get(part, "type") || Map.get(part, :type)
      end)

    assert types == ["text", "image_url", "text", "input_file"]
  end

  test "chat adapter: parts spliced at field position, no marker, no base64 leak" do
    imgs = page_images()
    start_lm(["[[ ## summary ## ]]done"])

    program = Dspy.Predict.new(ImageSig, adapter: Dspy.Signature.Adapters.ChatAdapter)

    assert {:ok, pred} = Dspy.Module.forward(program, image_sig_inputs(imgs))
    assert pred.attrs.summary == "done"

    assert_receive {:lm_request, request}, 1_000
    content = last_user_message(request).content
    text = full_text(content)

    assert_clean_text!(text)
    assert image_urls(content) == [imgs.expected1, imgs.expected2, "data:image/png;base64,QUJD"]
  end

  test "two-step adapter: main request carries image parts; extraction request does not" do
    imgs = page_images()
    start_lm(["Here is my natural answer about the pages.", "{\"summary\": \"done\"}"])

    # TwoStep needs the extraction LM configured explicitly
    Dspy.configure(two_step_extraction_lm: Dspy.Settings.get(:lm))

    program =
      Dspy.Predict.new(ImageSig, adapter: Dspy.Signature.Adapters.TwoStep, max_output_retries: 0)

    assert {:ok, pred} = Dspy.Module.forward(program, image_sig_inputs(imgs))
    assert pred.attrs.summary == "done"

    assert_receive {:lm_request, main_request}, 1_000
    assert_receive {:lm_request, extraction_request}, 1_000

    main_content = last_user_message(main_request).content
    assert length(image_urls(main_content)) == 3

    if is_list(main_content) do
      assert_clean_text!(full_text(main_content))
    else
      assert_clean_text!(main_content)
    end

    # extraction input is the main response text; no media parts
    extraction_content = last_user_message(extraction_request).content
    extraction_urls = if is_list(extraction_content), do: image_urls(extraction_content), else: []
    assert extraction_urls == []
  end
end
