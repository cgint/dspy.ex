# Consumer contract — changing this requires a deliberate breaking-change decision (see plan/SLICE_LOOP.md)

defmodule Dspy.ConsumerContract.AttachmentsAndAppEnvTest do
  @moduledoc """
  Consumer contract: Dspy.Attachments.new/1 (binary and list) and app env
  keys `:dspy, :attachment_roots` / `:dspy, :allow_absolute_attachment_paths`.

  Item 9 tests are behavioral: they build a Dspy.LM.ReqLLM with a FakeClient
  and send requests containing input_file parts, asserting the error/success
  outcomes that downstream apps depend on. No network is used.
  """
  use ExUnit.Case, async: false
  @moduletag :consumer_contract

  defmodule FakeClient do
    def generate_text(_model, _input, _opts) do
      {:ok, %{fake: :response}}
    end
  end

  defmodule FakeResponse do
    def text(_resp), do: "Answer: ok"
    def finish_reason(_resp), do: :stop
    def usage(_resp), do: nil
  end

  defp input_file_request(path) do
    %{
      messages: [
        %{
          role: "user",
          content: [
            %{"type" => "input_file", "file_path" => path, "mime_type" => "application/pdf"}
          ]
        }
      ]
    }
  end

  defp make_lm do
    Dspy.LM.ReqLLM.new(
      model: "anthropic:fake",
      client_module: FakeClient,
      response_module: FakeResponse
    )
  end

  # ---------------------------------------------------------------------------
  # Item 8: Dspy.Attachments.new/1 with binary and list
  # ---------------------------------------------------------------------------

  describe "Dspy.Attachments.new/1" do
    test "with a single binary path" do
      a = Dspy.Attachments.new("test/fixtures/dummy.pdf")
      assert %Dspy.Attachments{items: items} = a
      assert length(items) == 1
      assert %{type: :file, path: "test/fixtures/dummy.pdf"} = hd(items)
    end

    test "with a list of binary paths" do
      a = Dspy.Attachments.new(["test/fixtures/dummy.pdf", "test/fixtures/dummy.png"])
      assert %Dspy.Attachments{items: items} = a
      assert length(items) == 2
      assert Enum.all?(items, &(&1.type == :file))
    end

    test "to_message_parts produces input_file parts" do
      a = Dspy.Attachments.new("test/fixtures/dummy.pdf")
      [part | _] = Dspy.Attachments.to_message_parts(a)
      assert part["type"] == "input_file"
      assert part["file_path"] == "test/fixtures/dummy.pdf"
    end
  end

  # ---------------------------------------------------------------------------
  # Item 9: app env :dspy keys attachment_roots / allow_absolute_attachment_paths
  # Behavioral tests via Dspy.LM.ReqLLM + FakeClient (offline).
  # ---------------------------------------------------------------------------

  describe "app env :dspy attachment keys (behavioral)" do
    setup do
      prev_roots = Application.get_env(:dspy, :attachment_roots)
      prev_abs = Application.get_env(:dspy, :allow_absolute_attachment_paths)

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

    test "(a) relative path under attachment_roots succeeds" do
      Application.put_env(:dspy, :attachment_roots, ["test/fixtures"])
      Application.put_env(:dspy, :allow_absolute_attachment_paths, false)

      assert {:ok, _response} =
               Dspy.LM.generate(make_lm(), input_file_request("test/fixtures/dummy.pdf"))
    end

    test "(b) attachment_roots [] -> {:error, :attachments_not_enabled}" do
      Application.put_env(:dspy, :attachment_roots, [])
      Application.put_env(:dspy, :allow_absolute_attachment_paths, false)

      assert {:error, :attachments_not_enabled} =
               Dspy.LM.generate(make_lm(), input_file_request("test/fixtures/dummy.pdf"))
    end

    test "(c) absolute path with allow_absolute_attachment_paths false -> {:error, {:absolute_paths_not_allowed, _}}" do
      Application.put_env(:dspy, :attachment_roots, ["test/fixtures"])
      Application.put_env(:dspy, :allow_absolute_attachment_paths, false)

      abs = Path.expand("test/fixtures/dummy.pdf")

      assert {:error, {:absolute_paths_not_allowed, ^abs}} =
               Dspy.LM.generate(make_lm(), input_file_request(abs))
    end

    test "(d) absolute path inside a root with allow_absolute_attachment_paths true succeeds" do
      Application.put_env(:dspy, :attachment_roots, [Path.expand("test/fixtures")])
      Application.put_env(:dspy, :allow_absolute_attachment_paths, true)

      abs = Path.expand("test/fixtures/dummy.pdf")

      assert {:ok, _response} = Dspy.LM.generate(make_lm(), input_file_request(abs))
    end
  end
end
