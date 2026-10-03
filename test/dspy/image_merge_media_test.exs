defmodule Dspy.ImageMergeMediaTest do
  @moduledoc """
  Unit tests for `Dspy.Signature.AdapterPipeline.merge_media/3` — the splice
  point that turns rendered image-ref sentinels into interleaved `image_url`
  content parts, and for `sanitize_prompt/1` on sentinel-free paths.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Dspy.Signature.AdapterPipeline

  defp ref, do: AdapterPipeline.image_ref_token()

  defp img_part(n) do
    %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,IMG#{n}"}}
  end

  defp file_part, do: %{"type" => "input_file", "file" => %{"file_name" => "a.pdf"}}

  defp user_request(content) do
    %{messages: [%{role: "user", content: content}]}
  end

  defp content_types(request) do
    [user] = request.messages
    Enum.map(user.content, fn part -> Map.new(part)["type"] end)
  end

  defp full_text(request) do
    [user] = request.messages

    user.content
    |> Enum.filter(fn part -> Map.new(part)["type"] == "text" end)
    |> Enum.map(fn part -> Map.new(part)["text"] end)
    |> Enum.join("||")
  end

  test "interleaves multiple image parts at sentinel positions in binary content" do
    content = "Doc: #{ref()}\nPages: #{ref()} #{ref()}\nNote: hi\nOut:"
    request = user_request(content)

    assert {:ok, merged} =
             AdapterPipeline.merge_media(request, [], [img_part(1), img_part(2), img_part(3)])

    assert content_types(merged) == [
             "text",
             "image_url",
             "text",
             "image_url",
             "image_url",
             "text"
           ]

    assert full_text(merged) =~ "Doc: "
    assert full_text(merged) =~ "Pages: "
    assert full_text(merged) =~ "Note: hi"
    refute String.contains?(full_text(merged), ref())
  end

  test "interleaves at the sentinel text part of list content" do
    content = [
      %{"type" => "text", "text" => "A: #{ref()}\nB: done"},
      %{"type" => "text", "text" => "trailing"}
    ]

    assert {:ok, merged} = AdapterPipeline.merge_media(user_request(content), [], [img_part(1)])

    assert content_types(merged) == ["text", "image_url", "text", "text"]
    refute String.contains?(full_text(merged), ref())
  end

  test "no sentinels: image parts fall back to append-at-end (raw-seam compat)" do
    assert {:ok, merged} =
             AdapterPipeline.merge_media(user_request("plain text"), [], [img_part(1), img_part(2)])

    assert content_types(merged) == ["text", "image_url", "image_url"]
    assert full_text(merged) == "plain text"
  end

  test "sentinel count mismatch: strip sentinels, append parts (safe degradation)" do
    # Two sentinels but only one image part (e.g. a user string field that
    # happens to contain the literal token): the payload stays sane and a
    # warning names the misalignment for the developer.
    content = "X #{ref()} Y #{ref()} Z"

    assert capture_log([levels: [:warning]], fn ->
             {:ok, _} = AdapterPipeline.merge_media(user_request(content), [], [img_part(1)])
           end) =~ ~r/mismatch/i

    # Deterministic: re-run without capture to assert the structure.
    {:ok, merged} = AdapterPipeline.merge_media(user_request(content), [], [img_part(1)])

    assert content_types(merged) == ["text", "image_url"]
    assert full_text(merged) == "X  Y  Z"
    refute String.contains?(full_text(merged), ref())
  end

  test "attachments append after interleaved image parts" do
    content = "Files: <attachments>\nPage: #{ref()}\nOut:"

    assert {:ok, merged} =
             AdapterPipeline.merge_media(user_request(content), [file_part()], [img_part(1)])

    assert content_types(merged) == ["text", "image_url", "text", "input_file"]
  end

  test "merge_attachments/2 keeps the historical append-at-end behavior" do
    assert {:ok, merged} =
             AdapterPipeline.merge_attachments(user_request("plain"), [file_part()])

    assert content_types(merged) == ["text", "input_file"]
  end

  test "sanitize_prompt/1 removes sentinels for sentinel-free request paths" do
    assert AdapterPipeline.sanitize_prompt("answer #{ref()} end") == "answer  end"
    assert AdapterPipeline.sanitize_prompt("clean text") == "clean text"
  end
end
