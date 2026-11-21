defmodule Dspy.PredictorConfigTest do
  use ExUnit.Case, async: true

  alias Dspy.{ChainOfThought, Predict, Prediction}
  alias Dspy.Signature.Adapters.{JSONAdapter, TwoStep}

  defmodule OptionsSignature do
    use Dspy.Signature

    input_field(:config, :string, "Config input")
    input_field(:lm, :string, "LM input")
    output_field(:answer, :string, "Answer")
  end

  defmodule RecordingLM do
    @behaviour Dspy.LM
    defstruct [:owner, :ref, :responses]

    @impl true
    def generate(lm, request) do
      send(lm.owner, {:config_request, lm.ref, request})

      case next_response(lm, request) do
        {:error, reason} -> {:error, reason}
        content -> {:ok, %{choices: [%{message: %{role: "assistant", content: content}}]}}
      end
    end

    defp next_response(%{responses: responses}, request) when is_function(responses, 1),
      do: responses.(request)

    defp next_response(lm, _request) do
      key = {__MODULE__, lm.ref}
      index = Process.get(key, 0)
      Process.put(key, index + 1)
      Enum.at(lm.responses, index, List.last(lm.responses))
    end
  end

  defmodule Pair do
    @behaviour Dspy.Module
    defstruct [:left, :right]

    @impl true
    def forward(pair, %{config: input} = inputs) do
      with {:ok, _} <- Dspy.Module.forward(pair.left, %{inputs | config: input <> "/left"}) do
        Dspy.Module.forward(pair.right, %{inputs | config: input <> "/right"})
      end
    end
  end

  defmodule RecordingCallback do
    def on_adapter_call_start(_meta, _payload, owner) do
      send(owner, {:ambient_temperature, Dspy.Settings.get(:temperature)})
      :ok
    end
  end

  test "stored and call config override settings and preserve ordinary signature inputs" do
    lm = recording_lm([~s({"answer":"ok"})])
    ref = lm.ref

    predict =
      Predict.new(OptionsSignature,
        lm: lm,
        adapter: JSONAdapter,
        config: %{temperature: 0.0, max_tokens: 8}
      )

    assert Predict.get_config(predict) == %{temperature: 0.0, max_tokens: 8}
    tuned = Predict.update_config(predict, max_tokens: 16)
    assert Predict.get_config(tuned) == %{temperature: 0.0, max_tokens: 16}
    inputs = %{config: "ordinary config input", lm: "ordinary LM input"}

    Dspy.context([temperature: 0.7, max_tokens: 64, cache: false], fn ->
      assert {:ok, %Prediction{attrs: %{answer: "ok"}}} =
               Dspy.call(tuned, Map.to_list(inputs),
                 config: [temperature: 0.2],
                 callbacks: [{RecordingCallback, self()}]
               )

      assert_received {:ambient_temperature, 0.7}
      assert_received {:config_request, ^ref, %{temperature: 0.2, max_tokens: 16} = request}
      prompt = List.last(request.messages).content
      assert prompt =~ "ordinary config input"
      assert prompt =~ "ordinary LM input"

      assert {:ok, %Prediction{}} = Dspy.call(predict, inputs)
      assert_received {:config_request, ^ref, %{max_tokens: 8} = stored_request}
      assert stored_request.temperature === 0.0
    end)
  end

  test "ChainOfThought keeps configured request fields and rollout identity across output retries" do
    lm = recording_lm(["unusable output", ~s({"reasoning":"proof","answer":"ok"})])
    ref = lm.ref

    cot =
      ChainOfThought.new(OptionsSignature,
        lm: lm,
        adapter: JSONAdapter,
        max_output_retries: 1,
        config: [rollout_id: 1, temperature: 0.0]
      )

    assert ChainOfThought.get_config(cot) == %{rollout_id: 1, temperature: 0.0}
    inputs = %{config: "ordinary config input", lm: "ordinary LM input"}

    Dspy.context([cache: true, rollout_id: 97, temperature: 0.7, max_tokens: 32], fn ->
      assert {:ok, %Prediction{attrs: %{answer: "ok", reasoning: "proof"}}} =
               Dspy.call(cot, inputs)

      assert_received {:config_request, ^ref, %{max_tokens: 32} = initial}
      assert_received {:config_request, ^ref, %{max_tokens: 32} = retry}
      assert initial.temperature === 0.0
      assert retry.temperature === 0.0
      refute Map.has_key?(initial, :rollout_id)
      refute Map.has_key?(retry, :rollout_id)

      assert {:ok, %Prediction{}} = Dspy.call(cot, inputs)
      refute_received {:config_request, ^ref, _request}

      assert {:ok, %Prediction{}} = Dspy.call(cot, inputs, config: %{rollout_id: 2})
      assert_received {:config_request, ^ref, ^initial}

      legacy = Map.delete(cot, :config)
      assert ChainOfThought.get_config(legacy) == %{}
      assert {:ok, %Prediction{}} = Dspy.call(legacy, inputs)
      assert_received {:config_request, ^ref, %{temperature: 0.7}}

      updated = ChainOfThought.update_config(legacy, temperature: 0.0, rollout_id: 2)
      assert ChainOfThought.get_config(updated) == %{temperature: 0.0, rollout_id: 2}
      assert {:ok, %Prediction{}} = Dspy.call(updated, inputs)
      refute_received {:config_request, ^ref, _}
      assert Dspy.Settings.get(:rollout_id) == 97
    end)
  end

  test "BestOfN keeps its attempts distinct when the predictor stores a rollout id" do
    lm = recording_lm([~s({"answer":"reject"}), ~s({"answer":"ok"})])
    ref = lm.ref

    predict =
      Predict.new(OptionsSignature,
        lm: lm,
        adapter: JSONAdapter,
        config: [temperature: 1.0, rollout_id: 0]
      )

    best_of_n =
      Dspy.BestOfN.new(predict,
        n: 2,
        threshold: 1.0,
        reward_fn: fn _, prediction -> if prediction.attrs.answer == "ok", do: 1.0, else: 0.0 end
      )

    Dspy.context([cache: true, rollout_id: 0], fn ->
      assert {:ok, %Prediction{attrs: %{answer: "ok"}}} =
               Dspy.call(best_of_n, %{config: "ordinary config", lm: "ordinary LM"})

      assert_received {:config_request, ^ref, %{temperature: 1.0} = first}
      assert_received {:config_request, ^ref, ^first}
      refute Map.has_key?(first, :rollout_id)
    end)
  end

  test "an unbound predictor clears generation defaults and distinguishes rollout nil and zero" do
    lm = recording_lm([~s({"answer":"ok"})])
    ref = lm.ref

    predict =
      Predict.new(OptionsSignature,
        adapter: JSONAdapter,
        config: [temperature: 0.1, rollout_id: 1]
      )

    inputs = %{config: "ordinary config", lm: "ordinary LM"}

    Dspy.context([lm: lm, cache: true, rollout_id: 97, temperature: nil], fn ->
      legacy = Map.delete(predict, :config)
      assert {:ok, %Prediction{}} = Dspy.forward(legacy, inputs)
      assert_received {:config_request, ^ref, request}
      refute Map.has_key?(request, :temperature)

      assert %Prediction{} =
               Dspy.call!(predict, inputs, config: [temperature: nil, rollout_id: 97])

      refute_received {:config_request, ^ref, _}

      assert {:ok, %Prediction{}} = Dspy.call(predict, inputs, config: [temperature: nil])
      assert_received {:config_request, ^ref, ^request}

      assert {:ok, %Prediction{}} =
               Dspy.call(predict, inputs, config: [temperature: nil, rollout_id: nil])

      assert_received {:config_request, ^ref, ^request}

      cleared = Predict.update_config(predict, temperature: nil, rollout_id: nil)
      assert Predict.get_config(cleared) == %{rollout_id: nil}
      assert {:ok, %Prediction{}} = Dspy.call(cleared, inputs)
      refute_received {:config_request, ^ref, _}

      assert {:ok, %Prediction{}} = Dspy.call(cleared, inputs, config: [rollout_id: 0])
      assert_received {:config_request, ^ref, ^request}
      assert Dspy.Settings.get(:rollout_id) == 97
    end)
  end

  test "legacy predictor structs have empty config and request payloads stay adapter-owned" do
    legacy = Predict.new(OptionsSignature) |> Map.delete(:config)
    assert Predict.get_config(legacy) == %{}

    updated = Predict.update_config(legacy, max_completion_tokens: 9)
    assert Predict.get_config(updated) == %{max_completion_tokens: 9}

    for config <- [
          [messages: []],
          [output_contract: %{}],
          [tools: []],
          %{"temperature" => 0.2},
          ~D[2026-11-21],
          nil,
          [:temperature],
          [max_tokens: 0],
          [max_completion_tokens: -1],
          [temperature: "0.1"],
          [rollout_id: true]
        ] do
      assert_raise ArgumentError, ~r/config/, fn ->
        Predict.new(OptionsSignature, config: config)
      end
    end

    assert_raise ArgumentError, ~r/per-call config/, fn ->
      Dspy.call(%Pair{}, %{}, config: [temperature: 0.2])
    end

    lm = recording_lm([~s({"answer":"ok"})])
    ref = lm.ref
    invalid = legacy |> Map.put(:lm, lm) |> Map.put(:config, %{output_contract: %{}})

    assert_raise ArgumentError, ~r/config/, fn ->
      Dspy.call(invalid, %{config: "ordinary config", lm: "ordinary LM"})
    end

    refute_received {:config_request, ^ref, _}
  end

  test "BootstrapRS opens a fresh rollout when the teacher stores a rollout id" do
    lm = recording_lm([~s({"answer":"reject"}), ~s({"answer":"ok"})])
    ref = lm.ref

    teacher =
      Predict.new(OptionsSignature,
        lm: lm,
        adapter: JSONAdapter,
        config: [temperature: 1.0, rollout_id: 0]
      )

    optimizer =
      Dspy.Teleprompt.new(:bootstrap_rs,
        metric: fn _, prediction -> prediction.attrs.answer == "ok" end,
        max_rounds: 2,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        verbose: false
      )

    Dspy.context([cache: true, rollout_id: 0, temperature: 0.5], fn ->
      assert {:ok, %{program: best}} =
               Dspy.Teleprompt.BootstrapFewShotWithRandomSearch.compile_with_candidates(
                 optimizer,
                 teacher,
                 [row("training")],
                 restrict: [-1],
                 valset: [row("validation")]
               )

      assert [%Dspy.Example{attrs: %{config: "training", answer: "ok"}}] = best.examples
      assert_received {:config_request, ^ref, %{temperature: 1.0} = first_attempt}
      assert_received {:config_request, ^ref, ^first_attempt}
      refute Map.has_key?(first_attempt, :rollout_id)
      assert Predict.get_config(best) == %{temperature: 1.0, rollout_id: 0}
    end)
  end

  test "BootstrapRS applies retry options to every composite teacher slot" do
    lm =
      recording_lm(fn request ->
        if request.temperature == 1.0, do: ~s({"answer":"ok"}), else: ~s({"answer":"reject"})
      end)

    ref = lm.ref
    config = %{temperature: 0.2, rollout_id: 7, max_tokens: 16}
    predict = Predict.new(OptionsSignature, lm: lm, adapter: JSONAdapter, config: config)
    teacher = %Pair{left: predict, right: predict}

    optimizer =
      Dspy.Teleprompt.new(:bootstrap_rs,
        metric: fn _, prediction -> prediction.attrs.answer == "ok" end,
        max_rounds: 2,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        verbose: false
      )

    Dspy.context([cache: true], fn ->
      assert {:ok, %{program: best}} =
               Dspy.Teleprompt.BootstrapFewShotWithRandomSearch.compile_with_candidates(
                 optimizer,
                 teacher,
                 [row("training")],
                 restrict: [-1],
                 valset: [row("validation")]
               )

      assert [%Dspy.Example{attrs: %{config: "training/left", answer: "ok"}}] = best.left.examples

      assert [%Dspy.Example{attrs: %{config: "training/right", answer: "ok"}}] =
               best.right.examples

      for temperature <- [0.2, 0.2, 1.0, 1.0] do
        assert_received {:config_request, ^ref, %{temperature: ^temperature, max_tokens: 16}}
      end

      assert best.left.config == config
      assert best.right.config == config
      assert teacher.left.config == config
      assert teacher.right.config == config
    end)
  end

  test "transport retries retain config and TwoStep extraction uses its own settings" do
    lm = recording_lm([{:error, :transport}, "The answer is clear."])
    extractor = recording_lm([~s({"answer":"ok"})])
    ref = lm.ref
    extraction_ref = extractor.ref

    predict =
      Predict.new(OptionsSignature,
        lm: lm,
        adapter: TwoStep,
        max_retries: 1,
        config: [temperature: 0.0, max_tokens: 16, rollout_id: 1]
      )

    inputs = %{config: "ordinary config", lm: "ordinary LM"}

    Dspy.context(
      [
        cache: true,
        rollout_id: 97,
        temperature: 0.5,
        max_tokens: 64,
        two_step_extraction_lm: extractor,
        two_step_extraction_adapter: JSONAdapter,
        two_step_extraction_request_defaults: []
      ],
      fn ->
        assert {:ok, %Prediction{attrs: %{answer: "ok"}}} = Dspy.call(predict, inputs)
        assert_received {:config_request, ^ref, %{max_tokens: 16} = first}
        assert first.temperature === 0.0
        assert_received {:config_request, ^ref, ^first}
        assert_received {:config_request, ^extraction_ref, %{temperature: 0.5, max_tokens: 64}}

        assert {:ok, %Prediction{}} = Dspy.call(predict, inputs, config: [rollout_id: 2])
        assert_received {:config_request, ^ref, ^first}
        refute_received {:config_request, ^extraction_ref, _}
        assert Dspy.Settings.get(:rollout_id) == 97
      end
    )
  end

  defp row(input) do
    Dspy.Example.new(config: input, lm: "signature input", answer: "ok")
    |> Dspy.Example.with_inputs([:config, :lm])
  end

  defp recording_lm(responses) do
    %RecordingLM{owner: self(), ref: make_ref(), responses: responses}
  end
end
