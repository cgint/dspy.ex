defmodule Dspy.PredictorLMTest do
  use ExUnit.Case, async: false

  alias Dspy.Signature.Adapters.{JSONAdapter, TwoStep}

  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:model, :test_pid, :responses]

    @impl true
    def generate(lm, request) do
      send(lm.test_pid, {:lm_request, lm.model, request, Dspy.Settings.get(:lm)})

      case Agent.get_and_update(lm.responses, fn [reply | rest] -> {reply, rest} end) do
        {:error, reason} -> {:error, reason}
        content -> {:ok, %{choices: [%{message: %{role: "assistant", content: content}}]}}
      end
    end
  end

  defmodule RequestSummary do
    @behaviour Dspy.Signature.Adapter.Callback

    @impl true
    def on_adapter_format_start(_meta, _payload, pid), do: pid

    @impl true
    def on_adapter_format_end(meta, payload, pid), do: record(:format_end, meta, payload, pid)

    @impl true
    def on_adapter_call_start(meta, payload, pid), do: record(:call_start, meta, payload, pid)

    @impl true
    def on_adapter_call_end(meta, payload, pid), do: record(:call_end, meta, payload, pid)

    @impl true
    def on_adapter_parse_start(_meta, _payload, pid), do: pid

    @impl true
    def on_adapter_parse_end(_meta, _payload, pid), do: pid

    defp record(event, meta, payload, pid) do
      send(pid, {:lm_summary, event, meta.attempt, payload.request, Dspy.Settings.get(:lm)})
      pid
    end
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok = Dspy.configure(lm: nil, cache: false)
    :ok
  end

  test "Predict uses its bound LM through transport and output retries" do
    original_delay = Application.fetch_env(:dspy, :predict_retry_sleep_ms)
    Application.put_env(:dspy, :predict_retry_sleep_ms, 0)

    on_exit(fn ->
      case original_delay do
        {:ok, value} -> Application.put_env(:dspy, :predict_retry_sleep_ms, value)
        :error -> Application.delete_env(:dspy, :predict_retry_sleep_ms)
      end
    end)

    local = scripted_lm("local:predict", [{:error, :transport}, "{}", ~s({"answer":"local"})])
    scoped = scripted_lm("scoped:predict", List.duplicate(~s({"answer":"scoped"}), 2))

    Dspy.context([lm: scoped, temperature: 0.3], fn ->
      opts = [adapter: JSONAdapter, callbacks: [{RequestSummary, self()}]]

      bound =
        Dspy.predict(
          "question -> answer",
          [lm: local, max_retries: 1, max_output_retries: 1] ++ opts
        )

      assert {:ok, %{attrs: %{answer: "local"}}} = Dspy.Module.forward(bound, question: "q")

      for _ <- 1..3 do
        assert_received {:lm_request, "local:predict",
                         %{temperature: 0.3, output_contract: %{"required" => ["answer"]}},
                         ^scoped}
      end

      for attempt <- [1, 2], event <- [:format_end, :call_start, :call_end] do
        assert_received {:lm_summary, ^event, ^attempt,
                         %{model: "local:predict", provider: "local"}, ^scoped}
      end

      refute_received {:lm_request, _, _, _}
      refute_received {:lm_summary, _, _, _, _}

      for unbound_opts <- [opts, [lm: nil] ++ opts] do
        sibling = Dspy.Predict.new("question -> answer", unbound_opts)

        assert {:ok, %{attrs: %{answer: "scoped"}}} = Dspy.Module.forward(sibling, question: "q")
        assert_received {:lm_request, "scoped:predict", _, ^scoped}
      end
    end)
  end

  test "ChainOfThought binds its own LM and keeps reasoning output" do
    local = scripted_lm("local:cot", [~s({"reasoning":"work","answer":"local"})])
    scoped = scripted_lm("scoped:cot", [~s({"reasoning":"other work","answer":"scoped"})])

    Dspy.context([lm: scoped, temperature: 0.3, adapter: JSONAdapter], fn ->
      bound = Dspy.chain_of_thought("question -> answer", lm: local)
      sibling = Dspy.ChainOfThought.new("question -> answer")

      assert {:ok, %{attrs: %{reasoning: "work", answer: "local"}}} =
               Dspy.Module.forward(bound, %{question: "q"})

      assert_received {:lm_request, "local:cot", %{temperature: 0.3}, ^scoped}
      refute_received {:lm_request, "scoped:cot", _, _}

      assert {:ok, %{attrs: %{reasoning: "other work", answer: "scoped"}}} =
               Dspy.Module.forward(sibling, %{question: "q"})

      assert_received {:lm_request, "scoped:cot", _, ^scoped}
    end)
  end

  test "a bound LM works without a configured LM and preserves a signature input named lm" do
    signature = "lm -> answer"
    inputs = [%{lm: "input text"}, %{"lm" => "input text"}, [lm: "input text"]]
    local = scripted_lm("local:only", List.duplicate(~s({"answer":"local"}), 3))
    bound = Dspy.Predict.new(signature, lm: local, adapter: JSONAdapter, max_retries: 0)

    for input <- inputs do
      assert {:ok, %{attrs: %{answer: "local"}}} = Dspy.call(bound, input)
      assert_received {:lm_request, "local:only", %{messages: messages}, nil}
      assert Enum.any?(messages, &String.contains?(&1.content, "input text"))
    end

    unbound = Dspy.Predict.new(signature, max_retries: 0)
    assert {:error, :no_lm_configured} = Dspy.Module.forward(unbound, lm: "input text")
  end

  test "TwoStep uses the bound LM for the main pass and its configured LM for extraction" do
    local = scripted_lm("local:main", ["The answer is Paris."])
    extractor = scripted_lm("local:extractor", [~s({"answer":"Paris"})])

    :ok =
      Dspy.configure(two_step_extraction_lm: extractor, two_step_extraction_adapter: JSONAdapter)

    bound = Dspy.Predict.new("question -> answer", lm: local, adapter: TwoStep, max_retries: 0)

    assert {:ok, %{attrs: %{answer: "Paris"}}} = Dspy.Module.forward(bound, question: "q")
    assert_received {:lm_request, "local:main", _, nil}
    assert_received {:lm_request, "local:extractor", %{messages: messages}, nil}
    assert Enum.any?(messages, &String.contains?(&1.content, "The answer is Paris."))
  end

  test "both constructors reject non-LM bindings" do
    for predictor <- [Dspy.Predict, Dspy.ChainOfThought],
        invalid <- [false, "provider/model", ~D[2026-11-21]] do
      assert_raise ArgumentError, ~r/lm:.*Dspy.LM/, fn ->
        predictor.new("question -> answer", lm: invalid)
      end
    end
  end

  defp scripted_lm(model, replies) do
    responses = start_supervised!({Agent, fn -> replies end}, id: model)
    %ScriptedLM{model: model, test_pid: self(), responses: responses}
  end
end
