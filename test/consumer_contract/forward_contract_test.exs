# Consumer contract — changing this requires a deliberate breaking-change decision (see plan/SLICE_LOOP.md)

defmodule Dspy.ConsumerContract.ForwardMockLM do
  @moduledoc false

  @behaviour Dspy.LM

  defstruct [:counter, :mode]

  @impl true
  def generate(%__MODULE__{counter: counter, mode: mode}, _request) do
    call_num = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
    {:ok, response_for(mode, call_num)}
  end

  @impl true
  def supports?(_lm, _feature), do: true

  defp response_for(mode, call_num) do
    content =
      case mode do
        :valid -> ~s({"answer": "42"})
        :typed_valid -> ~s({"result": {"answer": "42"}})
        :invalid_then_valid when call_num == 1 -> "not json at all"
        :invalid_then_valid -> ~s({"answer": "42"})
        :always_invalid -> "not json at all"
        :missing_key -> ~s({"other": "42"})
        :validation_fail -> ~s({"result": {"answer": 42}})
        :schema_fail when call_num == 1 -> ~s({"result": {"not_answer": "42"}})
        :bool_invalid -> ~s({"flag": "not_a_bool"})
        :schema_fail -> ~s({"result": {"answer": "42"}})
        :lm_error -> raise "simulated"
      end

    %{
      choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
      usage: nil
    }
  end
end

defmodule Dspy.ConsumerContract.ForwardFailingLM do
  @moduledoc false

  @behaviour Dspy.LM

  defstruct []

  @impl true
  def generate(_lm, _request) do
    {:error, {:http_error, 500, "boom"}}
  end

  @impl true
  def supports?(_lm, _feature), do: true
end

defmodule Dspy.ConsumerContract.ForwardContractTest do
  @moduledoc """
  Consumer contract: Dspy.Predict.new/1,2 + Dspy.Module.forward/2 with mock LMs.

  Freezes the shape of `{:ok, %Dspy.Prediction{attrs: attrs}}` and the error
  tuples consumers must handle. All LM calls go to in-process mock LMs — no
  network.
  """
  use ExUnit.Case, async: false
  @moduletag :consumer_contract

  defmodule Sig do
    @moduledoc false

    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule TypedSchema do
    @moduledoc false

    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{answer: string()},
      required: [:answer],
      additionalProperties: false
    })
  end

  defmodule TypedSig do
    @moduledoc false

    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:result, :json, "Typed result", schema: TypedSchema)
  end

  defmodule BoolSig do
    @moduledoc false

    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:flag, :boolean, "Flag")
  end

  # Mock LM that returns a fixed content per call (configurable via :mode).

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    %{counter: counter}
  end

  # ---------------------------------------------------------------------------
  # Item 5: Dspy.Predict.new/1 and /2
  # ---------------------------------------------------------------------------

  describe "Dspy.Predict.new/1 and /2" do
    test "new/1 returns a %Dspy.Predict{} with defaults" do
      p = Dspy.Predict.new(Sig)
      assert %Dspy.Predict{signature: %Dspy.Signature{}} = p
      assert p.max_retries == 3
      assert p.examples == []
      assert p.adapter == nil
    end

    test "new/2 with max_retries: 0, max_output_retries: 1" do
      p = Dspy.Predict.new(Sig, max_retries: 0, max_output_retries: 1)
      assert p.max_retries == 0
      assert p.max_output_retries == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Item 6: Dspy.Module.forward/2 -> {:ok, %Dspy.Prediction{attrs: attrs}}
  # ---------------------------------------------------------------------------

  describe "Dspy.Module.forward/2" do
    test "returns {:ok, %Dspy.Prediction{attrs: attrs}} with atom keys", %{
      counter: counter
    } do
      Dspy.configure(lm: %Dspy.ConsumerContract.ForwardMockLM{counter: counter, mode: :valid})

      program = Dspy.Predict.new(Sig, max_retries: 0, max_output_retries: 1)
      {:ok, %Dspy.Prediction{} = pred} = Dspy.Module.forward(program, %{question: "?"})

      # attrs are keyed by the output field name (atom), as consumers read them.
      assert pred.attrs.answer == "42"
      assert Dspy.Prediction.get(pred, :answer) == "42"
    end

    test "typed output: attrs contain a %TypedSchema{} struct", %{counter: counter} do
      Dspy.configure(
        lm: %Dspy.ConsumerContract.ForwardMockLM{counter: counter, mode: :typed_valid}
      )

      program = Dspy.Predict.new(TypedSig, max_retries: 0, max_output_retries: 1)
      {:ok, %Dspy.Prediction{} = pred} = Dspy.Module.forward(program, %{question: "?"})

      assert %TypedSchema{answer: "42"} = pred.attrs.result
    end
  end

  # ---------------------------------------------------------------------------
  # Item 10: error tuples from forward with mock LM outputs
  # ---------------------------------------------------------------------------

  describe "error tuples from forward (max_output_retries: 0, max_retries: 0)" do
    test "terminal failure wraps output_decode_failed in output_parse_failed", %{
      counter: counter
    } do
      # Mock LM returns non-JSON on every call.
      Dspy.configure(
        lm: %Dspy.ConsumerContract.ForwardMockLM{counter: counter, mode: :always_invalid}
      )

      program = Dspy.Predict.new(Sig, max_retries: 0, max_output_retries: 0)

      # NOTE (documented current behavior, 2026-09): with max_output_retries: 0,
      # every non-retryable-or-exhausted parse failure is wrapped as
      # {:output_parse_failed, inner_reason, %{raw_output: binary}}.
      # For an untyped signature with non-JSON text, the inner reason is
      # {:missing_required_outputs, [field_names]} (label parsing finds nothing).
      # For a typed signature, the inner reason is {:output_decode_failed, _}.
      assert {:error,
              {:output_parse_failed, {:missing_required_outputs, [_ | _]}, %{raw_output: _}}} =
               Dspy.Module.forward(program, %{question: "?"})
    end

    test "terminal failure wraps missing_required_outputs in output_parse_failed", %{
      counter: counter
    } do
      Dspy.configure(
        lm: %Dspy.ConsumerContract.ForwardMockLM{counter: counter, mode: :missing_key}
      )

      program = Dspy.Predict.new(Sig, max_retries: 0, max_output_retries: 0)

      assert {:error, {:output_parse_failed, {:missing_required_outputs, [_ | _]}, _}} =
               Dspy.Module.forward(program, %{question: "?"})
    end

    test "terminal failure wraps invalid_output_value in output_parse_failed", %{
      counter: counter
    } do
      # Mock returns a non-boolean string where :boolean is expected.
      Dspy.configure(
        lm: %Dspy.ConsumerContract.ForwardMockLM{counter: counter, mode: :bool_invalid}
      )

      program = Dspy.Predict.new(BoolSig, max_retries: 0, max_output_retries: 0)

      assert {:error, {:output_parse_failed, {:invalid_output_value, :flag, _}, _}} =
               Dspy.Module.forward(program, %{question: "?"})
    end

    test "typed: terminal failure wraps output_validation_failed in output_parse_failed",
         %{counter: counter} do
      Dspy.configure(
        lm: %Dspy.ConsumerContract.ForwardMockLM{counter: counter, mode: :schema_fail}
      )

      program = Dspy.Predict.new(TypedSig, max_retries: 0, max_output_retries: 0)

      assert {:error, {:output_parse_failed, {:output_validation_failed, _}, _}} =
               Dspy.Module.forward(program, %{question: "?"})
    end

    test "LM-level error tuple is returned unwrapped", %{counter: _counter} do
      Dspy.configure(lm: %Dspy.ConsumerContract.ForwardFailingLM{})

      program = Dspy.Predict.new(Sig, max_retries: 0, max_output_retries: 0)

      # LM generate/1 returning {:error, reason} propagates verbatim to the
      # caller (no output_parse_failed wrap).
      assert {:error, {:http_error, 500, "boom"}} =
               Dspy.Module.forward(program, %{question: "?"})
    end
  end

  describe "retry behavior (max_output_retries: 1)" do
    test "retries once on invalid then valid output", %{counter: counter} do
      Dspy.configure(
        lm: %Dspy.ConsumerContract.ForwardMockLM{counter: counter, mode: :invalid_then_valid}
      )

      program = Dspy.Predict.new(Sig, max_retries: 0, max_output_retries: 1)
      {:ok, %Dspy.Prediction{} = pred} = Dspy.Module.forward(program, %{question: "?"})
      assert pred.attrs.answer == "42"
      assert Agent.get(counter, & &1) == 2
    end
  end
end
