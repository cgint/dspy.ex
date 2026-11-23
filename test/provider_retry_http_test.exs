defmodule Dspy.ProviderRetryHTTPTest do
  use ExUnit.Case, async: false

  defmodule Signature do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule OfflineHTTP do
    def run(request) do
      [status | remaining] = Process.get(__MODULE__)
      Process.put(__MODULE__, if(remaining == [], do: [status], else: remaining))
      send(self(), {:http_attempt, status})

      response =
        Req.Response.new(
          status: status,
          headers: [{"content-type", "application/json"}, {"retry-after", "0"}],
          body: body(status, request.url.path)
        )

      {request, response}
    end

    defp body(200, "/responses") do
      Jason.encode!(%{
        id: "resp-offline",
        object: "response",
        model: "gpt-4.1-mini",
        status: "completed",
        output_text: "Answer: ok",
        usage: %{input_tokens: 1, output_tokens: 1}
      })
    end

    defp body(status, _path) when status >= 400,
      do: ~s({"error":{"message":"Offline response","type":"probe"}})
  end

  defmodule UnsupportedGeneration do
    def generate_object(_, _, _, _), do: {:error, :unsupported_schema}
  end

  setup do
    previous_sleep = Application.fetch_env(:dspy, :predict_retry_sleep_ms)
    Application.put_env(:dspy, :predict_retry_sleep_ms, 0)

    on_exit(fn ->
      case previous_sleep do
        {:ok, delay} -> Application.put_env(:dspy, :predict_retry_sleep_ms, delay)
        :error -> Application.delete_env(:dspy, :predict_retry_sleep_ms)
      end
    end)
  end

  test "a persistent OpenAI 401 surfaces the original error after one HTTP attempt" do
    assert {:error, %ReqLLM.Error.API.Request{status: 401}} = predict([401], 3)

    assert_received {:http_attempt, 401}
    refute_received {:http_attempt, _}
  end

  test "OpenAI keeps its pinned inner 429 retry budget when both configured budgets are zero" do
    assert {:error, %ReqLLM.Error.API.Request{status: 429}} =
             predict([429], 0, max_retries: 0)

    for _ <- 1..4 do
      assert_received {:http_attempt, 429}
    end

    refute_received {:http_attempt, _}
  end

  test "persistent 429 uses only the ReqLLM transport retry budget" do
    assert {:error, %ReqLLM.Error.API.Request{status: 429}} = predict([429], 3)

    for _ <- 1..4, do: assert_received({:http_attempt, 429})
    refute_received {:http_attempt, _}
  end

  test "mixed ReqLLM uses the text client retry budget" do
    assert {:error, %ReqLLM.Error.API.Request{status: 429}} = predict([429], 3, [], __MODULE__)
    for _ <- 1..4, do: assert_received({:http_attempt, 429})
    refute_received {:http_attempt, _}
  end

  test "native schema fallback uses only the text client retry budget" do
    Process.put(OfflineHTTP, [429])

    lm =
      Dspy.LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        generation_module: UnsupportedGeneration,
        default_opts: [
          api_key: "fake-offline-key",
          base_url: "http://127.0.0.1:1",
          req_http_options: [adapter: OfflineHTTP]
        ]
      )

    predictor =
      Dspy.predict(Signature,
        lm: lm,
        adapter: Dspy.Signature.Adapters.JSONAdapter,
        max_retries: 3,
        max_output_retries: 0
      )

    assert {:error, %ReqLLM.Error.API.Request{status: 429}} =
             Dspy.context([cache: false], fn -> Dspy.call(predictor, %{question: "Offline"}) end)

    for _ <- 1..4, do: assert_received({:http_attempt, 429})
    refute_received {:http_attempt, _}
  end

  test "ambient ReqLLM uses only its transport retry budget for persistent 429" do
    Process.put(OfflineHTTP, [429])

    lm =
      Dspy.LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        default_opts: [
          api_key: "fake-offline-key",
          base_url: "http://127.0.0.1:1",
          req_http_options: [adapter: OfflineHTTP]
        ]
      )

    predictor =
      Dspy.predict(Signature,
        adapter: Dspy.Signature.Adapters.Default,
        max_retries: 3,
        max_output_retries: 0
      )

    assert {:error, %ReqLLM.Error.API.Request{status: 429}} =
             Dspy.context([lm: lm, cache: false], fn ->
               Dspy.call(predictor, %{question: "Offline"})
             end)

    for _ <- 1..4, do: assert_received({:http_attempt, 429})
    refute_received {:http_attempt, _}
  end

  test "the predictor retries a 503 once and parses the successful HTTP response" do
    assert {:ok, %Dspy.Prediction{attrs: %{answer: "ok"}}} = predict([503, 200], 1)

    assert_received {:http_attempt, 503}
    assert_received {:http_attempt, 200}
    refute_received {:http_attempt, _}
  end

  defp predict(statuses, max_retries, http_opts \\ [], generation_module \\ ReqLLM.Generation) do
    Process.put(OfflineHTTP, statuses)

    lm =
      Dspy.LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        generation_module: generation_module,
        default_opts: [
          api_key: "fake-offline-key",
          base_url: "http://127.0.0.1:1",
          req_http_options: [adapter: OfflineHTTP] ++ http_opts
        ]
      )

    predictor =
      Dspy.predict(Signature,
        lm: lm,
        adapter: Dspy.Signature.Adapters.Default,
        max_retries: max_retries,
        max_output_retries: 0
      )

    Dspy.context([cache: false], fn -> Dspy.call(predictor, %{question: "Offline"}) end)
  end
end
