defmodule Dspy.LM.ReqLLMMultimodalTest do
  use ExUnit.Case, async: false

  defmodule FakeClient do
    def generate_text(_model, input, _opts) do
      send(self(), {:req_llm_input, input})
      {:ok, %{fake: :response}}
    end
  end

  defmodule FakeResponse do
    def text(_resp), do: "Answer: ok"
    def finish_reason(_resp), do: :stop
    def usage(_resp), do: nil
  end

  defp rm_tmp(tmp) do
    tmp_dir = System.tmp_dir!() |> Path.expand()
    expanded = Path.expand(tmp)

    unless String.starts_with?(expanded, tmp_dir <> "/") and
             String.contains?(Path.basename(expanded), "dspy_req_llm_") do
      raise "Refusing to delete unexpected path: #{expanded}"
    end

    # non-bang, best-effort cleanup
    _ = File.rm_rf(expanded)
    :ok
  end

  setup do
    prev_roots = Application.get_env(:dspy, :attachment_roots)
    prev_abs = Application.get_env(:dspy, :allow_absolute_attachment_paths)

    Application.put_env(:dspy, :attachment_roots, ["test/fixtures"])
    Application.put_env(:dspy, :allow_absolute_attachment_paths, false)

    on_exit(fn ->
      if is_nil(prev_roots),
        do: Application.delete_env(:dspy, :attachment_roots),
        else: Application.put_env(:dspy, :attachment_roots, prev_roots)

      if is_nil(prev_abs),
        do: Application.delete_env(:dspy, :allow_absolute_attachment_paths),
        else: Application.put_env(:dspy, :allow_absolute_attachment_paths, prev_abs)
    end)

    :ok
  end

  test "ReqLLM adapter converts multipart content (text + input_file) into ReqLLM.ContentPart list" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "anthropic:fake",
        client_module: FakeClient,
        response_module: FakeResponse
      )

    request = %{
      messages: [
        %{
          role: "user",
          content: [
            %{"type" => "text", "text" => "Summarize"},
            %{
              "type" => "input_file",
              "file_path" => "test/fixtures/dummy.pdf",
              "mime_type" => "application/pdf"
            }
          ]
        }
      ]
    }

    assert {:ok, response} = Dspy.LM.generate(lm, request)
    assert %{choices: [%{message: %{content: "Answer: ok"}}]} = response

    assert_receive {:req_llm_input, %ReqLLM.Context{messages: [msg]}}

    assert msg.role == :user
    assert [part1, part2] = msg.content

    assert part1.type == :text
    assert part1.text == "Summarize"

    assert part2.type == :file
    assert part2.media_type == "application/pdf"
    assert part2.filename == "dummy.pdf"
    assert is_binary(part2.data)
    assert byte_size(part2.data) > 0
  end

  test "ReqLLM adapter returns error for unsupported message shapes" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "anthropic:fake",
        client_module: FakeClient,
        response_module: FakeResponse
      )

    request = %{messages: ["not a message map"]}

    assert {:error, {:unsupported_message, _}} = Dspy.LM.generate(lm, request)
  end

  test "ReqLLM adapter blocks file_path attachments unless attachment_roots configured" do
    prev_roots = Application.get_env(:dspy, :attachment_roots)
    Application.put_env(:dspy, :attachment_roots, [])

    on_exit(fn ->
      if is_nil(prev_roots),
        do: Application.delete_env(:dspy, :attachment_roots),
        else: Application.put_env(:dspy, :attachment_roots, prev_roots)
    end)

    lm =
      Dspy.LM.ReqLLM.new(
        model: "anthropic:fake",
        client_module: FakeClient,
        response_module: FakeResponse
      )

    request = %{
      messages: [
        %{
          role: "user",
          content: [
            %{
              "type" => "input_file",
              "file_path" => "test/fixtures/dummy.pdf",
              "mime_type" => "application/pdf"
            }
          ]
        }
      ]
    }

    assert {:error, :attachments_not_enabled} = Dspy.LM.generate(lm, request)
  end

  test "ReqLLM adapter rejects .. path traversal for file_path attachments" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "anthropic:fake",
        client_module: FakeClient,
        response_module: FakeResponse
      )

    request = %{
      messages: [
        %{
          role: "user",
          content: [
            %{
              "type" => "input_file",
              "file_path" => "test/fixtures/../dummy.pdf",
              "mime_type" => "application/pdf"
            }
          ]
        }
      ]
    }

    assert {:error, {:parent_dir_not_allowed, _}} = Dspy.LM.generate(lm, request)
  end

  test "ReqLLM adapter rejects absolute paths by default" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "anthropic:fake",
        client_module: FakeClient,
        response_module: FakeResponse
      )

    abs = Path.expand("test/fixtures/dummy.pdf")

    request = %{
      messages: [
        %{
          role: "user",
          content: [
            %{
              "type" => "input_file",
              "file_path" => abs,
              "mime_type" => "application/pdf"
            }
          ]
        }
      ]
    }

    assert {:error, {:absolute_paths_not_allowed, ^abs}} = Dspy.LM.generate(lm, request)
  end

  test "ReqLLM adapter rejects attachment_roots that are symlinks" do
    prev_roots = Application.get_env(:dspy, :attachment_roots)
    prev_abs = Application.get_env(:dspy, :allow_absolute_attachment_paths)

    token = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "dspy_req_llm_symlink_root_#{System.unique_integer([:positive])}_#{token}"
      )

    root = Path.join(tmp, "root")
    target = Path.join(tmp, "target")

    File.mkdir_p!(target)
    File.write!(Path.join(target, "secret.txt"), "nope")

    # root is a symlink to target
    File.mkdir_p!(tmp)
    :ok = File.ln_s(target, root)

    Application.put_env(:dspy, :attachment_roots, [root])
    Application.put_env(:dspy, :allow_absolute_attachment_paths, true)

    on_exit(fn ->
      if is_nil(prev_roots),
        do: Application.delete_env(:dspy, :attachment_roots),
        else: Application.put_env(:dspy, :attachment_roots, prev_roots)

      if is_nil(prev_abs),
        do: Application.delete_env(:dspy, :allow_absolute_attachment_paths),
        else: Application.put_env(:dspy, :allow_absolute_attachment_paths, prev_abs)

      rm_tmp(tmp)
    end)

    lm =
      Dspy.LM.ReqLLM.new(
        model: "anthropic:fake",
        client_module: FakeClient,
        response_module: FakeResponse
      )

    abs = Path.join(root, "secret.txt")

    request = %{
      messages: [
        %{
          role: "user",
          content: [%{"type" => "input_file", "file_path" => abs, "mime_type" => "text/plain"}]
        }
      ]
    }

    assert {:error, {:invalid_attachment_root, _, {:symlink_root_not_allowed, _}}} =
             Dspy.LM.generate(lm, request)
  end

  test "ReqLLM adapter rejects symlinks inside an allowed root" do
    prev_roots = Application.get_env(:dspy, :attachment_roots)
    prev_abs = Application.get_env(:dspy, :allow_absolute_attachment_paths)

    token = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "dspy_req_llm_symlink_sub_#{System.unique_integer([:positive])}_#{token}"
      )

    root = Path.join(tmp, "root")
    outside = Path.join(tmp, "outside")

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "nope")

    link = Path.join(root, "link")
    :ok = File.ln_s(outside, link)

    Application.put_env(:dspy, :attachment_roots, [root])
    Application.put_env(:dspy, :allow_absolute_attachment_paths, true)

    on_exit(fn ->
      if is_nil(prev_roots),
        do: Application.delete_env(:dspy, :attachment_roots),
        else: Application.put_env(:dspy, :attachment_roots, prev_roots)

      if is_nil(prev_abs),
        do: Application.delete_env(:dspy, :allow_absolute_attachment_paths),
        else: Application.put_env(:dspy, :allow_absolute_attachment_paths, prev_abs)

      rm_tmp(tmp)
    end)

    lm =
      Dspy.LM.ReqLLM.new(
        model: "anthropic:fake",
        client_module: FakeClient,
        response_module: FakeResponse
      )

    abs = Path.join(link, "secret.txt")

    request = %{
      messages: [
        %{
          role: "user",
          content: [%{"type" => "input_file", "file_path" => abs, "mime_type" => "text/plain"}]
        }
      ]
    }

    assert {:error, {:invalid_attachment_root, _, {:symlink_not_allowed, _}}} =
             Dspy.LM.generate(lm, request)
  end

  test "ReqLLM adapter returns error for unsupported content parts" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "anthropic:fake",
        client_module: FakeClient,
        response_module: FakeResponse
      )

    request = %{
      messages: [
        %{
          role: "user",
          content: [%{"type" => "video", "url" => "http://example.com/x.mp4"}]
        }
      ]
    }

    assert {:error, {:unsupported_content_part, _}} = Dspy.LM.generate(lm, request)
  end
end
