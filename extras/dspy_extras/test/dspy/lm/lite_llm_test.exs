defmodule Dspy.LM.LiteLLMTest do
  @moduledoc """
  Tests for the HTTP behaviour of `Dspy.LM.LiteLLM` (Req-based, since EXT-HTTP).

  Uses `Req.Test` plug stubs — no network access. Covers the success and error
  paths of the shared request path (`completions/2`, `generate/2`).
  """
  use ExUnit.Case

  defmodule UnexpectedTestError do
    @moduledoc false
    defexception message: "unexpected transport hiccup"
  end

  @stub :lite_llm_req_stub

  setup do
    # In tests, route LiteLLM HTTP through a Req.Test plug stub; retry is
    # disabled by default in the module so failures surface on the first attempt.
    :ok = Application.put_env(:dspy_extras, :req_opts, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.delete_env(:dspy_extras, :req_opts)
    end)
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

    assert {:error, "Network error: connection refused"} =
             Dspy.LM.LiteLLM.completions(client, [%{role: "user", content: "hi"}])
  end

  test "completions/2 formats a tuple transport reason without crashing" do
    # {:tls_alert, _} style reasons must not crash the error path.
    Req.Test.stub(@stub, fn conn ->
      # Bypass Req.Test.transport_error/2's atom-only validation and plant a
      # raw exception with a tuple reason, mirroring what the real transport
      # adapter can surface (e.g. {:tls_alert, :self_signed} from Mint/Finch).
      exception = Req.TransportError.exception(reason: {:tls_alert, :self_signed})
      Plug.Conn.put_private(conn, :req_test_exception, exception)
    end)

    client = new_openai_client(base_url: "https://openai.example")

    result =
      Dspy.LM.LiteLLM.completions(client, [%{role: "user", content: "hi"}])

    assert {:error, message} = result
    assert String.starts_with?(message, "Network error: ")
    assert message =~ "tls_alert"
  end

  test "completions/2 converts a non-transport exception into a stable error tuple" do
    exception = %UnexpectedTestError{}

    Req.Test.stub(@stub, fn conn ->
      Plug.Conn.put_private(conn, :req_test_exception, exception)
    end)

    client = new_openai_client(base_url: "https://openai.example")

    assert {:error, "Request failed: unexpected transport hiccup"} =
             Dspy.LM.LiteLLM.completions(client, [%{role: "user", content: "hi"}])
  end

  # --- provider routing (no HTTP involved) ---------------------------------

  test "completions/2 for unknown model returns a stable error" do
    client = Dspy.LM.LiteLLM.new("no-such-model", api_key: "test-key")

    assert {:error, "Unsupported model: no-such-model"} =
             Dspy.LM.LiteLLM.completions(client, [%{role: "user", content: "hi"}])
  end
end
