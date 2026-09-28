defmodule Dspy.LM.LiteLLMTest do
  @moduledoc """
  Tests for the HTTP behaviour of `Dspy.LM.LiteLLM` (Req-based, since EXT-HTTP).

  Uses `Req.Test` plug stubs — no network access. Covers the success and error
  paths of the shared request path (`completions/2`, `generate/2`).
  """
  use ExUnit.Case

  @stub :lite_llm_req_stub

  setup do
    # In tests, route LiteLLM HTTP through a Req.Test plug stub; retry is
    # disabled by default in the module so failures surface on the first attempt.
    :ok = Application.put_env(:dspy_extras, :req_opts, plug: {Req.Test, @stub})
    :ok
  end

  defp new_openai_client(overrides \\ []) do
    Dspy.LM.LiteLLM.new("gpt-4o", Keyword.merge([api_key: "test-key"], overrides))
  end

  # --- success paths -------------------------------------------------------

  test "completions/2 returns decoded JSON on 200" do
    Req.Test.stub(@stub, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      assert {"authorization", "Bearer test-key"} in conn.req_headers

      body = Req.Test.raw_body(conn)
      assert %{"model" => "gpt-4o", "messages" => [%{"role" => "user"}]} = Jason.decode!(body)

      Req.Test.json(conn, %{
        choices: [%{message: %{content: "hello back"}}]
      })
    end)

    client = new_openai_client(base_url: "https://openai.example")

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "hello back"}}]}} =
             Dspy.LM.LiteLLM.completions(client, [%{role: "user", content: "hi"}])
  end

  test "generate/2 extracts content from the provider response" do
    Req.Test.stub(@stub, fn conn ->
      Req.Test.json(conn, %{
        choices: [%{message: %{content: "generated"}}]
      })
    end)

    client = new_openai_client(base_url: "https://openai.example")
    assert {:ok, %{completions: ["generated"]}} = Dspy.LM.LiteLLM.generate(client, "hi")
  end

  # --- error paths ---------------------------------------------------------

  test "completions/2 returns an error tuple for non-200 status" do
    Req.Test.stub(@stub, fn conn ->
      Plug.Conn.send_resp(conn, 401, "unauthorized")
    end)

    client = new_openai_client(base_url: "https://openai.example")

    assert {:error, "API request failed with status 401: unauthorized"} =
             Dspy.LM.LiteLLM.completions(client, [%{role: "user", content: "hi"}])
  end

  test "completions/2 returns an error tuple for invalid JSON body" do
    Req.Test.stub(@stub, fn conn ->
      Req.Test.text(conn, "not-json")
    end)

    client = new_openai_client(base_url: "https://openai.example")

    assert {:error, "Failed to decode response"} =
             Dspy.LM.LiteLLM.completions(client, [%{role: "user", content: "hi"}])
  end

  test "completions/2 returns a network error tuple on transport failure" do
    Req.Test.stub(@stub, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    client = new_openai_client(base_url: "https://openai.example")

    assert {:error, "Network error: econnrefused"} =
             Dspy.LM.LiteLLM.completions(client, [%{role: "user", content: "hi"}])
  end

  # --- provider routing (no HTTP involved) ---------------------------------

  test "completions/2 for unknown model returns a stable error" do
    client = Dspy.LM.LiteLLM.new("no-such-model", api_key: "test-key")

    assert {:error, "Unsupported model: no-such-model"} =
             Dspy.LM.LiteLLM.completions(client, [%{role: "user", content: "hi"}])
  end
end
