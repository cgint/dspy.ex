defmodule SignatureH12AdapterPathsTest do
  @moduledoc """
  H12 HB1 (2026-09-29): prove that EACH of the three parser call sites is
  actually wired to `Dspy.Signature.NumberParser`.

  The shared-module mutation (breaking NumberParser) reddens the default
  (signature.ex) path. That does NOT prove the chat and json adapter copies
  are wired — they could be bypassing the shared parser entirely while
  everything looks green (Greta's decisive point). So this file exercises
  the chat and json adapter paths SPECIFICALLY by calling their public
  `parse_outputs/2,3` entry points directly, and pins a strict accept + a
  strict reject for each annotation.

  If `adapters/chat.ex` or `adapters/json.ex` is reverted to the old lenient
  inline parsing (the HB1 per-site revert), the corresponding accept/reject
  verdicts here change and the test goes red — whereas a pure
  shared-module mutation would NOT red these (they'd still use whatever the
  reverted inline code does).

  `async: false` to avoid any interaction with H6's global-adapter hazard.
  """
  use ExUnit.Case, async: false

  defmodule NumSig do
    use Dspy.Signature
    input_field(:question, :string, "Question")
    output_field(:answer, :number, "Answer")
  end

  defmodule IntSig do
    use Dspy.Signature
    input_field(:question, :string, "Question")
    output_field(:count, :integer, "Count")
  end

  # ---------------------------------------------------------------------------
  # CHAT adapter — output format: [[ ## field ## ]]\n value
  # ---------------------------------------------------------------------------
  defp chat_text(field, value) do
    "[[ ## #{field} ## ]]\n#{value}"
  end

  describe "chat adapter :number" do
    test "accepts a strict number" do
      assert %{answer: 0.8} =
               Dspy.Signature.Adapters.ChatAdapter.parse_outputs(
                 NumSig.signature(),
                 chat_text("answer", "0.8")
               )
    end

    test "rejects a lenient number ('80%')" do
      assert {:error, {:invalid_output_value, :answer, :invalid_number}} =
               Dspy.Signature.Adapters.ChatAdapter.parse_outputs(
                 NumSig.signature(),
                 chat_text("answer", "80%")
               )
    end
  end

  describe "chat adapter :integer" do
    test "accepts a strict integer" do
      assert %{count: 5} =
               Dspy.Signature.Adapters.ChatAdapter.parse_outputs(
                 IntSig.signature(),
                 chat_text("count", "5")
               )
    end

    test "rejects a lenient integer (',1')" do
      assert {:error, {:invalid_output_value, :count, :invalid_integer}} =
               Dspy.Signature.Adapters.ChatAdapter.parse_outputs(
                 IntSig.signature(),
                 chat_text("count", ",1")
               )
    end
  end

  # ---------------------------------------------------------------------------
  # JSON adapter — output format: {"field": value}
  # ---------------------------------------------------------------------------
  defp json_text(field, value) do
    # value is a raw string; for :number/:integer the JSON value is the number,
    # but we feed the STRING form to exercise the string->number strict parse.
    ~s({"#{field}": "#{value}"})
  end

  describe "json adapter :number" do
    test "accepts a strict number" do
      assert %{answer: 0.8} =
               Dspy.Signature.Adapters.JSONAdapter.parse_outputs(
                 NumSig.signature(),
                 json_text("answer", "0.8")
               )
    end

    test "rejects a lenient number ('80%')" do
      assert {:error, {:invalid_output_value, :answer, :invalid_number}} =
               Dspy.Signature.Adapters.JSONAdapter.parse_outputs(
                 NumSig.signature(),
                 json_text("answer", "80%")
               )
    end
  end

  describe "json adapter :integer" do
    test "accepts a strict integer" do
      assert %{count: 5} =
               Dspy.Signature.Adapters.JSONAdapter.parse_outputs(
                 IntSig.signature(),
                 json_text("count", "5")
               )
    end

    test "rejects a lenient integer (',1')" do
      assert {:error, {:invalid_output_value, :count, :invalid_integer}} =
               Dspy.Signature.Adapters.JSONAdapter.parse_outputs(
                 IntSig.signature(),
                 json_text("count", ",1")
               )
    end
  end
end
