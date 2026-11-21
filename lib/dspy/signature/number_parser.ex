defmodule Dspy.Signature.NumberParser do
  @moduledoc """
  Shared strict parser for `:number` and `:integer` DSPy signature output
  fields, matching upstream dspy 3.4.0 `parse_value(s, float)` /
  `parse_value(s, int)` behaviour (see `plan/SLICE_LOOP.md` H12 and the
  Horst rulings 2026-09-29 in `docs/COMPATIBILITY.md`).

  This module is the SINGLE source of truth for string→number parsing in
  output validation. All three parser copies — `Dspy.Signature.validate_field_type/2`,
  `Dspy.Signature.Adapters.Chat.validate_field_type/2`, and
  `Dspy.Signature.Adapters.JSON.validate_field_type/2` — MUST call into
  `parse_number/1` / `parse_integer/1` here so the verdicts stay in lockstep.
  Do NOT re-implement the logic inline; a mutation that breaks this module
  must turn every path red (H12 acceptance criterion, HB1 2026-09-29:
  each call site individually must also be proven wired by reverting it).

  Accept (both annotations, after trimming leading/trailing whitespace):
  - decimal integers and floats: "1", "+2", "-3", "0.8", ".5", "5.", "1.5",
    "5.e3" (== 5000.0), ".5e3" (== 500.0)
  - exponent forms, INCLUDING underscores in the exponent: "1e-1", "1E3",
    "+1e2", "1e1_0" (== 1e10), "1e_1" (== 10.0)
  - underscore digit separators: "1_000", "1_000_000"
  - leading zeros as decimal (NOT octal): "010" == 10, "007" == 7
  - signed hex, binary, and octal literal forms: "0x10" == 16, "0x10_0" == 256,
    "0b101" == 5, "-0x10" == -16, "+0b1" == 1, "0o_17" == 15
  - one matching pair of single or double quotes on either path: "\"0.8\"" -> 0.8,
    "\"5\"" -> 5 / 5.0, "\" 5 \"" -> 5 (inner whitespace trimmed),
    "\"2.0\"" -> 2 (int), "\"1_000\"" -> 1000
  - decimal literals in balanced parentheses: "((5))" and "('5')" -> 5 / 5.0
  - for `:integer` only: integer-valued float forms ("2.0" -> 2, "1E3" -> 1000,
    "2e2" -> 200, "5.e3" -> 5000, ".5e3" -> 500)

  Reject (both annotations):
  - MORE THAN ONE sign: "+-1", "-+1", "++1", "--1", "++0.5" (HB2 2026-09-29:
    at most one sign)
  - trailing or interior text: "80%", "0.8 (high)", "about 0.8", "1 000",
    "1,000", "1,000.5", "0,8", "[0.8]", "0.8.1", "1.2.3.4", "null", "None",
    "'", ",1", "1,", "0x-10" (sign inside hex)
  - NaN / inf words: "NaN", "nan", "NAN", "inf", "-inf", "INF", "+inf"
    (Horst ruling 2026-09-29: BEAM floats cannot represent them; upstream's
    judge clamp would turn NaN into a perfect 1.0 — corrupt-or-lose principle)
  - boolean words: "true", "True", "False" (Horst ruling 2026-09-29)
  - lone punctuation / empty: "", " ", ".", "+", "-", "+.", "-.", "[", "]",
    "(", ")", "%", "%%", "5.e" (trailing dot before a bare exponent)
  - malformed radix forms: "0x", "0b", "0xG", "0x10G", "0o17_", "0b1__0"
  - malformed exponents: "1e", "1e-", "1e+"
  - leading / trailing underscore: "_1", "1_"
  - non-number tokens: "1d3", "1f"
  - quoted forms that are not a single number: "\"(5)\"", "\"0x10\"" (upstream
    rejects quoted hex), "\"1E3\"" as :integer (upstream rejects it for int)
  """

  @doc """
  Parse a string as a strict `:number` (float). Returns `{:ok, float()}` or
  `{:error, :invalid_number}`.
  """
  def parse_number(value) when is_binary(value), do: do_parse(value, :float)

  def parse_number(_value), do: {:error, :invalid_number}

  @doc """
  Parse a string as a strict `:integer`. Returns `{:ok, integer()}` or
  `{:error, :invalid_integer}`.
  """
  def parse_integer(value) when is_binary(value), do: do_parse(value, :int)

  def parse_integer(_value), do: {:error, :invalid_integer}

  # ---------------------------------------------------------------------------
  # Core
  # ---------------------------------------------------------------------------

  defp do_parse(raw, :float) do
    {value, wrapper} = unwrap(raw)

    if strict_shape?(value) and not (wrapper != :bare and radix_literal?(value)),
      do: parse_float_lex(value),
      else: {:error, :invalid_number}
  end

  defp do_parse(raw, :int) do
    {value, wrapper} = unwrap(raw)

    if strict_shape?(value) and not (wrapper != :bare and radix_literal?(value)) and
         not (wrapper == :quoted and String.match?(value, ~r/[eE]/)),
       do: parse_int_lex(value),
       else: {:error, :invalid_integer}
  end

  # ---------------------------------------------------------------------------
  # Shape / unwrap helpers
  # ---------------------------------------------------------------------------

  defp unwrap(raw) do
    {value, wrapper} = strip_parentheses(String.trim(raw), :bare)

    case value do
      <<quote, _::binary>> when quote in [?", ?'] and byte_size(value) >= 2 ->
        if :binary.last(value) == quote, do: {inside(value), :quoted}, else: {value, wrapper}

      _ ->
        {value, wrapper}
    end
  end

  defp strip_parentheses(<<?(, _::binary>> = value, wrapper) do
    if :binary.last(value) == ?),
      do: strip_parentheses(inside(value), :parenthesized),
      else: {value, wrapper}
  end

  defp strip_parentheses(value, wrapper), do: {value, wrapper}

  defp inside(value), do: value |> binary_part(1, byte_size(value) - 2) |> String.trim()

  defp radix_literal?(value), do: String.match?(value, ~r/\A[+-]?0[xXbBoO]/)

  # Full-string strict-number shape (upstream dspy 3.4.0 parse_value).
  # AT MOST ONE leading sign (HB2 2026-09-29: "+-1", "++1", "--1" reject).
  # Accepts: "1", "+2", "-3", "0.8", ".5", "5.", "5.e3", ".5e3", "1e-1",
  # "1E3", "1e1_0", "1e_1", "1_000", "010", "0x10_0", "-0x10", "+0b101",
  # "0o17", "0O17", "-0o17" (HB8 2026-09-29: octal matches upstream),
  # "1.5", "2.0".
  # Rejects: "+-1", "++1", "--1", "80%", "1 000", "true", "NaN", "inf",
  # "", " ", "[0.8]", "0.8.1", "null", "0x", "0b", "0o", ".", "+", "-",
  # "+.", "-.", "_1", "1_", "0xG", "1e", "1e-", "1e+", "1.2.3.4", "1d3",
  # "1f", "'", ",1", "1,", "5.e", "0x-10".
  defp strict_shape?(value) do
    String.match?(
      value,
      ~r/\A
        [+-]?                                   # at most ONE sign
        (?:
          0[xX]_?[0-9A-Fa-f]+(?:_[0-9A-Fa-f]+)* # hex
        | 0[bB]_?[01]+(?:_[01]+)*               # binary
        | 0[oO]_?[0-7]+(?:_[0-7]+)*             # octal
        | (?:
            \d+(?:_\d+)*(?:\.\d*(?:_\d+)*)?     # int or float, trailing "." ok
          | \.\d+(?:_\d+)*                      # ".5"
          )
          (?:[eE][+-]?\d*(?:_\d+)*)?            # exponent, including "1e_1"
        )
      \z/x
    )
  end

  # ---------------------------------------------------------------------------
  # Lexers
  # ---------------------------------------------------------------------------

  defp parse_float_lex(s) do
    s = s |> String.replace("_", "") |> String.replace("+", "", global: false)

    cond do
      String.match?(s, ~r/^[+-]?0[xX]/) ->
        parse_radix(s, 16, :float)

      String.match?(s, ~r/^[+-]?0[bB]/) ->
        parse_radix(s, 2, :float)

      String.match?(s, ~r/^[+-]?0[oO]/) ->
        # Octal (HB8 2026-09-29): "0o17" -> 15.0, matching upstream.
        parse_radix(s, 8, :float)

      true ->
        case Float.parse(normalize_float(s)) do
          {f, ""} ->
            {:ok, f}

          {f, "."} ->
            {:ok, f}

          _ ->
            # Upstream rejects quoted hex ("0x10" as :number) — the shape
            # regex accepts 0x... but Float.parse cannot, and we do NOT fall
            # back to Integer.parse on the float path (that would accept
            # "0x10" as 16.0, diverging from upstream). Reject.
            {:error, :invalid_number}
        end
    end
  end

  # Normalize the two float-form shapes Elixir's Float.parse refuses, so the
  # upstream-accepted "5.e3" (== 5000.0) and ".5e3" (== 500.0) parse:
  #   ".5" / ".5e3"  -> "0.5" / "0.5e3"   (leading-dot)
  #   "5." / "5.e3"  -> "5.0" / "5.0e3"   (trailing-dot, only when an
  #                                          exponent follows the dot)
  # "5.e" (trailing-dot + bare exponent) stays "5.e" -> Float.parse rejects,
  # matching upstream.
  defp normalize_float(s) do
    cond do
      String.match?(s, ~r/^[+-]?\.\d+(?:[eE][+-]?\d+)?$/) ->
        # ".5" -> "0.5"; ".5e3" -> "0.5e3"
        s |> String.replace(".", "0.", global: false)

      String.match?(s, ~r/^[+-]?\d+\.([eE][+-]?\d+)$/) ->
        # "-5.e3" -> "-5.0e3" (preserve the leading sign).
        String.replace(s, ".", ".0", global: false)

      true ->
        # "5." stays "5." (Float.parse handles it as {5.0, "."}); anything
        # else is passed through.
        s
    end
  end

  defp parse_int_lex(s) do
    s = s |> String.replace("_", "") |> String.replace("+", "", global: false)

    cond do
      String.match?(s, ~r/^[+-]?0[xX]/) ->
        parse_radix(s, 16, :int)

      String.match?(s, ~r/^[+-]?0[bB]/) ->
        parse_radix(s, 2, :int)

      String.match?(s, ~r/^[+-]?0[oO]/) ->
        parse_radix(s, 8, :int)

      true ->
        case Integer.parse(s) do
          {int, ""} -> {:ok, int}
          _ -> parse_int_from_float(s)
        end
    end
  end

  defp parse_radix(s, base, :float) do
    case parse_radix(s, base, :int) do
      {:ok, int} -> {:ok, int * 1.0}
      {:error, :invalid_integer} -> {:error, :invalid_number}
    end
  rescue
    ArithmeticError -> {:error, :invalid_number}
  end

  defp parse_radix(s, base, :int) do
    {sign, digits} =
      case s do
        <<?-, _prefix::binary-size(2), digits::binary>> -> {-1, digits}
        <<_prefix::binary-size(2), digits::binary>> -> {1, digits}
      end

    case Integer.parse(digits, base) do
      {int, ""} -> {:ok, sign * int}
      _ -> {:error, :invalid_integer}
    end
  end

  # Accept a float-form string for :integer only when its value is exactly
  # integral. "1E3" -> 1000, "2e2" -> 200, "2.0" -> 2, "5.e3" -> 5000,
  # ".5e3" -> 500. Rejects "1e-1", "1.5", "0.8".
  defp parse_int_from_float(normalized) do
    # Reuse the float normalization so "5.e3" / ".5e3" parse identically on
    # both paths (HB2 parity).
    case Float.parse(normalize_float(normalized)) do
      {f, ""} when f == trunc(f) -> {:ok, trunc(f)}
      {f, "."} when f == trunc(f) -> {:ok, trunc(f)}
      _ -> {:error, :invalid_integer}
    end
  end
end
