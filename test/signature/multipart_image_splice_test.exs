defmodule Dspy.Signature.MultipartImageSpliceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Dspy.{Attachments, Image, Predict}
  alias Dspy.Signature.AdapterPipeline
  alias Dspy.Signature.Adapters.Default

  defmodule MediaSignature do
    use Dspy.Signature

    input_field(:photos, :image, "Photos")
    input_field(:report, :string, "Report attachment")
    output_field(:answer, :string, "Answer")
  end

  defmodule MultipartAdapter do
    @behaviour Dspy.Signature.Adapter

    @impl true
    defdelegate format_instructions(signature, opts), to: Default

    @impl true
    defdelegate parse_outputs(signature, text, opts), to: Default

    @impl true
    def format_request(_signature, _inputs, _demos, _opts) do
      marker = AdapterPipeline.image_ref_token()

      %{
        messages: [
          %{role: "user", content: "Earlier user message"},
          %{
            role: "user",
            content: [
              %{"type" => "text", "text" => "first #{marker} tail"},
              %{"type" => "input_file", "file_id" => "existing-file"},
              %{type: "text", text: "second #{marker}   #{marker} tail"},
              %{type: "text", text: "untouched", cache_control: %{type: "ephemeral"}}
            ]
          },
          %{role: "assistant", content: "Later assistant message"}
        ]
      }
    end
  end

  defmodule RecordingLM do
    @behaviour Dspy.LM
    defstruct [:owner]

    @impl true
    def generate(lm, request) do
      send(lm.owner, {:multipart_request, request})
      {:ok, "Answer: ok"}
    end
  end

  test "each marker in a multipart predictor request consumes the next image once" do
    photos = Enum.map(1..3, &Image.new("https://example.invalid/photo-#{&1}.png"))
    [first, second, third] = Enum.flat_map(photos, &Image.format/1)
    report = Attachments.new("/tmp/new-report.pdf")
    [attachment] = Attachments.to_message_parts(report)

    predictor =
      Predict.new(MediaSignature,
        adapter: MultipartAdapter,
        lm: %RecordingLM{owner: self()},
        max_retries: 0,
        max_output_retries: 0
      )

    assert {:ok, prediction} =
             Dspy.context([cache: false], fn ->
               Dspy.call(predictor, %{photos: photos, report: report})
             end)

    assert prediction[:answer] == "ok"

    assert_received {:multipart_request, %{messages: messages}}

    assert messages == [
             %{role: "user", content: "Earlier user message"},
             %{
               role: "user",
               content: [
                 text("first "),
                 first,
                 text(" tail"),
                 %{"type" => "input_file", "file_id" => "existing-file"},
                 text("second "),
                 second,
                 third,
                 text(" tail"),
                 %{type: "text", text: "untouched", cache_control: %{type: "ephemeral"}},
                 attachment
               ]
             },
             %{role: "assistant", content: "Later assistant message"}
           ]

    refute_received {:multipart_request, _}
  end

  test "a multipart count mismatch strips the target markers and appends each image once" do
    marker = AdapterPipeline.image_ref_token()
    existing = %{"type" => "input_file", "file_id" => "existing-file"}
    attachment = %{"type" => "input_file", "file_id" => "new-file"}
    earlier = %{"role" => "user", "content" => [text("earlier #{marker}")]}
    later = %{role: "assistant", content: "unchanged"}

    images =
      Enum.flat_map(1..3, fn index ->
        Image.new("https://example.invalid/private-#{index}") |> Image.format()
      end)

    content = [text("private text#{marker}"), existing, %{type: "text", text: "#{marker}tail"}]
    target = %{"role" => "user", "content" => content}
    request = %{"messages" => [earlier, target, later]}

    for image_parts <- [[], Enum.take(images, 1), images] do
      warning =
        "Dspy image splice mismatch: 2 sentinel(s) in prompt text but #{length(image_parts)} image part(s)"

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, merged} = AdapterPipeline.merge_media(request, [attachment], image_parts)

          assert merged == %{
                   messages: [
                     earlier,
                     %{
                       target
                       | "content" =>
                           [text("private text"), existing, text("tail")] ++
                             image_parts ++ [attachment]
                     },
                     later
                   ]
                 }
        end)

      assert length(String.split(log, "Dspy image splice mismatch:")) == 2
      assert log =~ warning
      refute log =~ "private text"
      refute log =~ "example.invalid/private"
    end
  end

  test "multipart content without markers keeps its parts before appended media" do
    content = [text("plain"), %{type: "text", text: "untouched"}]
    image = %{"type" => "image_url", "image_url" => %{"url" => "https://example.invalid/photo"}}
    attachment = %{"type" => "input_file", "file_id" => "new-file"}
    request = %{messages: [%{role: "user", content: content}]}

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, %{messages: [%{content: merged}]}} =
                 AdapterPipeline.merge_media(request, [attachment], [image])

        assert merged == content ++ [image, attachment]
      end)

    refute log =~ "Dspy image splice mismatch:"
  end

  defp text(value), do: %{"type" => "text", "text" => value}
end
