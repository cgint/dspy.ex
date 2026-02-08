defmodule Dspy.AttachmentsTest do
  use ExUnit.Case, async: true

  test "to_message_parts omits mime_type when unknown" do
    a = Dspy.Attachments.new("/tmp/file.unknown")
    [part] = Dspy.Attachments.to_message_parts(a)

    assert part["type"] == "input_file"
    assert part["file_path"] == "/tmp/file.unknown"
    refute Map.has_key?(part, "mime_type")
  end
end
