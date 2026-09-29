defmodule SignatureNumberIntegerStrictTest do
  @moduledoc """
  Tests for strict `:number` and `:integer` string parsing in
  `Dspy.Signature.validate_field_type/2`, verdicts matching upstream
  dspy 3.4.0 `parse_value(s, float)` / `parse_value(s, int)`.
  """
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Test doubles
  # ---------------------------------------------------------------------------

  defmodule ScriptedNumberLM do
    @behaviour Dspy.LM
    defstruct [:answer]

    @impl true
    def generate(%__MODULE__{answer: answer}, _request) do
      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Answer: #{answer}"},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule ScriptedIntegerLM do
    @behaviour Dspy.LM
    defstruct [:count]

    @impl true
    def generate(%__MODULE__{count: count}, _request) do
      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Count: #{count}"},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule NumberSig do
    use Dspy.Signature
    input_field(:question, :string, "A question")
    output_field(:answer, :number, "A number")
  end

  defmodule IntegerSig do
    use Dspy.Signature
    input_field(:question, :string, "A question")
    output_field(:count, :integer, "An integer")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp call_number(answer) do
    predict = Dspy.Predict.new(NumberSig, max_retries: 0, max_output_retries: 0)

    Dspy.context([lm: %ScriptedNumberLM{answer: answer}], fn ->
      Dspy.call(predict, %{question: "q"})
    end)
  end

  defp call_integer(count) do
    predict = Dspy.Predict.new(IntegerSig, max_retries: 0, max_output_retries: 0)

    Dspy.context([lm: %ScriptedIntegerLM{count: count}], fn ->
      Dspy.call(predict, %{question: "q"})
    end)
  end

  # ---------------------------------------------------------------------------
  # SS1: :number strict parsing
  # ---------------------------------------------------------------------------

  describe ":number strict parsing" do
    test "ordinary case: \"0.8\" -> 0.8 (float)" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("0.8")
      assert is_float(value)
      assert value == 0.8
    end

    test "accept: trimmed \" 0.8 \" -> 0.8" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number(" 0.8 ")
      assert value == 0.8
    end

    test "accept: newline \"0.8\\n\" -> 0.8" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("0.8\n")
      assert value == 0.8
    end

    # The leading tab is trimmed by the adapter before parsing; keep the input as-is — trimming here would hide that the adapter does it.
    test "accept: tab+exponent \"\\t-2.5e+3 \" -> -2500.0 (leading tab trimmed by adapter extraction; parser sees \"-2.5e+3\")" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("\t-2.5e+3 ")
      assert value == -2500.0
    end

    test "accept: \"1\" -> 1.0 (float, not integer)" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("1")
      assert is_float(value)
      assert value == 1.0
    end

    test "accept: \"10\" -> 10.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("10")
      assert value == 10.0
    end

    test "accept: \"-0.2\" -> -0.2" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("-0.2")
      assert value == -0.2
    end

    test "accept: \".5\" -> 0.5" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number(".5")
      assert value == 0.5
    end

    test "accept: \"5.\" -> 5.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("5.")
      assert value == 5.0
    end

    test "accept: \"3.\" -> 3.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("3.")
      assert value == 3.0
    end

    test "accept: \"1e-1\" -> 0.1" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("1e-1")
      assert value == 0.1
    end

    test "accept: \"1E3\" -> 1000.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("1E3")
      assert value == 1000.0
    end

    test "accept: \"+0.5\" -> 0.5" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("+0.5")
      assert value == 0.5
    end

    test "accept: \"+1e2\" -> 100.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("+1e2")
      assert value == 100.0
    end

    test "accept: quoted \"\\\"0.8\\\"\" -> 0.8" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} =
        call_number("\"0.8\"")

      assert value == 0.8
    end

    test "accept: \"1_000\" -> 1000.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("1_000")
      assert value == 1000.0
    end

    test "accept: \"1_0\" -> 10.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("1_0")
      assert value == 10.0
    end

    test "accept: \"010\" -> 10.0 (decimal, NOT octal)" do
      # upstream dspy 3.4.0 parse_value("010", float) == 10.0 (decimal),
      # not 8.0 (octal) — pinned, do not "fix" to octal.
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("010")
      assert value == 10.0
    end

    test "accept: \"007\" -> 7.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("007")
      assert value == 7.0
    end

    test "accept: \"12345.6\" -> 12345.6" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("12345.6")
      assert value == 12345.6
    end

    test "accept: parenthesised \"(0.8)\" -> 0.8" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("(0.8)")
      assert value == 0.8
    end

    test "accept: \"0x10\" -> 16.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("0x10")
      assert value == 16.0
    end

    test "accept: \"0x10_0\" -> 256.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("0x10_0")
      assert value == 256.0
    end

    test "accept: \"0b101\" -> 5.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("0b101")
      assert value == 5.0
    end

    test "accept: \"1.0\" -> 1.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("1.0")
      assert value == 1.0
    end

    test "accept: \"2.0\" -> 2.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("2.0")
      assert value == 2.0
    end

    test "accept: \"1.5\" -> 1.5" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("1.5")
      assert value == 1.5
    end

    test "accept: \"0.0\" -> 0.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("0.0")
      assert value == 0.0
    end

    test "accept: \"-0.0\" -> -0.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("-0.0")
      assert value == -0.0
    end

    test "accept: \"1_000_000\" -> 1000000.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("1_000_000")
      assert value == 1_000_000.0
    end

    test "accept: \"2e2\" -> 200.0" do
      {:ok, %Dspy.Prediction{attrs: %{answer: value}}} = call_number("2e2")
      assert value == 200.0
    end

    test "reject: \"80%\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("80%")
    end

    test "reject: \"1/2\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("1/2")
    end

    test "reject: \"0.8/1.0\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("0.8/1.0")
    end

    test "reject: \"0.8 (high)\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("0.8 (high)")
    end

    test "reject: \"about 0.8\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("about 0.8")
    end

    test "reject: \"0,8\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("0,8")
    end

    test "reject: \"12,345.6\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("12,345.6")
    end

    test "reject: \"1,000\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("1,000")
    end

    test "reject: \"1,000.5\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("1,000.5")
    end

    test "reject: \"N/A\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("N/A")
    end

    test "reject: \"\" (empty string)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("")
    end

    test "reject: \" \" (whitespace only)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number(" ")
    end

    test "reject: \"[0.8]\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("[0.8]")
    end

    test "reject: \"0.8.1\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("0.8.1")
    end

    test "reject: \"null\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("null")
    end

    test "reject: \"None\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("None")
    end

    test "reject: \"0x\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("0x")
    end

    test "reject: \"0b\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("0b")
    end

    test "reject: \".\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number(".")
    end

    test "reject: \"+\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("+")
    end

    test "reject: \"-\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("-")
    end

    test "reject: \"+.\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("+.")
    end

    test "reject: \"-.\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("-.")
    end

    test "reject: \"_1\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("_1")
    end

    test "reject: \"1_\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("1_")
    end

    test "reject: \"0xG\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("0xG")
    end

    test "reject: \"0x10G\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("0x10G")
    end

    test "reject: \"1e\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("1e")
    end

    test "reject: \"1e-\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("1e-")
    end

    test "reject: \"1e+\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("1e+")
    end

    test "reject: \"1.2.3.4\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("1.2.3.4")
    end

    test "reject: \"1 000\" (interior whitespace)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("1 000")
    end

    test "reject: \"1d3\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("1d3")
    end

    test "reject: \"1f\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("1f")
    end

    test "reject: \"'\" (single quote alone)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("'")
    end

    # Horst rulings (2026-09-29)
    test "reject: \"NaN\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("NaN")
    end

    test "reject: \"nan\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("nan")
    end

    test "reject: \"NAN\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("NAN")
    end

    test "reject: \"inf\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("inf")
    end

    test "reject: \"-inf\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("-inf")
    end

    test "reject: \"INF\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("INF")
    end

    test "reject: \"+inf\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("+inf")
    end

    test "reject: \"true\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("true")
    end

    test "reject: \"True\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("True")
    end

    test "reject: \"False\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :answer, :invalid_number}, _meta}} =
               call_number("False")
    end
  end

  # ---------------------------------------------------------------------------
  # SS2: :integer strict parsing
  # ---------------------------------------------------------------------------

  describe ":integer strict parsing" do
    test "ordinary case: \"1\" -> 1 (integer)" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("1")
      assert is_integer(value)
      assert value == 1
    end

    test "accept: \"10\" -> 10" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("10")
      assert value == 10
    end

    test "accept: trimmed \" 1 \" -> 1" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer(" 1 ")
      assert value == 1
    end

    test "accept: newline \"1\\n\" -> 1" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("1\n")
      assert value == 1
    end

    test "accept: \"+2\" -> 2" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("+2")
      assert value == 2
    end

    test "accept: \"-3\" -> -3" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("-3")
      assert value == -3
    end

    test "accept: \"5.\" -> 5" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("5.")
      assert value == 5
    end

    test "accept: \"3.\" -> 3" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("3.")
      assert value == 3
    end

    test "accept: \"1E3\" -> 1000 (integer-valued exponent)" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("1E3")
      assert value == 1000
    end

    test "accept: \"+1e2\" -> 100" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("+1e2")
      assert value == 100
    end

    # The leading tab is trimmed by the adapter before parsing; keep the input as-is — trimming here would hide that the adapter does it.
    test "accept: tab+exponent \"\\t-2.5e+3 \" -> -2500 (leading tab trimmed by adapter extraction; parser sees \"-2.5e+3\")" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("\t-2.5e+3 ")
      assert value == -2500
    end

    test "accept: \"1_000\" -> 1000" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("1_000")
      assert value == 1000
    end

    test "accept: \"1_0\" -> 10" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("1_0")
      assert value == 10
    end

    test "accept: \"010\" -> 10 (decimal, NOT octal)" do
      # upstream dspy 3.4.0 parse_value("010", int) == 10 (decimal),
      # not 8 (octal) — pinned, do not "fix" to octal.
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("010")
      assert value == 10
    end

    test "accept: \"007\" -> 7" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("007")
      assert value == 7
    end

    test "accept: \"2e2\" -> 200 (integer-valued exponent)" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("2e2")
      assert value == 200
    end

    test "accept: \"2.0\" -> 2 (float-form, integer-valued)" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("2.0")
      assert value == 2
    end

    test "accept: \"1.0\" -> 1" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("1.0")
      assert value == 1
    end

    test "accept: \"0.0\" -> 0" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("0.0")
      assert value == 0
    end

    test "accept: \"-0.0\" -> 0" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("-0.0")
      assert value == 0
    end

    test "accept: \"1_000_000\" -> 1000000" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("1_000_000")
      assert value == 1_000_000
    end

    test "accept: \"0x10\" -> 16 (Horst: match upstream, no declaration needed)" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("0x10")
      assert value == 16
    end

    test "accept: \"0x10_0\" -> 256" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("0x10_0")
      assert value == 256
    end

    test "accept: \"0b101\" -> 5" do
      {:ok, %Dspy.Prediction{attrs: %{count: value}}} = call_integer("0b101")
      assert value == 5
    end

    test "reject: \"0.8\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("0.8")
    end

    test "reject: \" 0.8 \"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer(" 0.8 ")
    end

    test "reject: \"0.8\\n\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("0.8\n")
    end

    test "reject: \"-0.2\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("-0.2")
    end

    test "reject: \".5\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer(".5")
    end

    test "reject: \"1e-1\" (non-integer exponent value)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1e-1")
    end

    test "reject: \"+0.5\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("+0.5")
    end

    test "reject: \"1.5\" (non-integer float)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1.5")
    end

    test "reject: \"12345.6\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("12345.6")
    end

    test "reject: \"80%\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("80%")
    end

    test "reject: \"1/2\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1/2")
    end

    test "reject: \"0.8/1.0\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("0.8/1.0")
    end

    test "reject: \"0.8 (high)\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("0.8 (high)")
    end

    test "reject: \"about 0.8\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("about 0.8")
    end

    test "reject: \"0,8\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("0,8")
    end

    test "reject: \"12,345.6\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("12,345.6")
    end

    test "reject: \"1,000\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1,000")
    end

    test "reject: \"1,000.5\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1,000.5")
    end

    test "reject: \"N/A\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("N/A")
    end

    test "reject: \"\" (empty string)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("")
    end

    test "reject: \" \" (whitespace only)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer(" ")
    end

    test "reject: \"[0.8]\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("[0.8]")
    end

    test "reject: \"(0.8)\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("(0.8)")
    end

    test "reject: \"0.8.1\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("0.8.1")
    end

    test "reject: \"null\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("null")
    end

    test "reject: \"None\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("None")
    end

    test "reject: \"0x\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("0x")
    end

    test "reject: \"0b\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("0b")
    end

    test "reject: \".\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer(".")
    end

    test "reject: \"+\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("+")
    end

    test "reject: \"-\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("-")
    end

    test "reject: \"+.\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("+.")
    end

    test "reject: \"-.\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("-.")
    end

    test "reject: \"_1\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("_1")
    end

    test "reject: \"1_\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1_")
    end

    test "reject: \"0xG\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("0xG")
    end

    test "reject: \"0x10G\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("0x10G")
    end

    test "reject: \"1e\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1e")
    end

    test "reject: \"1e-\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1e-")
    end

    test "reject: \"1e+\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1e+")
    end

    test "reject: \"1.2.3.4\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1.2.3.4")
    end

    test "reject: \"1 000\" (interior whitespace)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1 000")
    end

    test "reject: \"1d3\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1d3")
    end

    test "reject: \"1f\"" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("1f")
    end

    test "reject: \"'\" (single quote alone)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("'")
    end

    # Horst rulings (2026-09-29)
    test "reject: \"true\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("true")
    end

    test "reject: \"True\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("True")
    end

    test "reject: \"False\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("False")
    end

    test "reject: \"NaN\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("NaN")
    end

    test "reject: \"nan\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("nan")
    end

    test "reject: \"NAN\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("NAN")
    end

    test "reject: \"inf\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("inf")
    end

    test "reject: \"-inf\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("-inf")
    end

    test "reject: \"INF\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("INF")
    end

    test "reject: \"+inf\" (Horst ruling)" do
      assert {:error,
              {:output_parse_failed, {:invalid_output_value, :count, :invalid_integer}, _meta}} =
               call_integer("+inf")
    end
  end
end
