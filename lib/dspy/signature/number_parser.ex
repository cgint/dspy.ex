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
  - hex / binary literal forms, SIGNED: "0x10" == 16, "0x10_0" == 256,
    "0b101" == 5, "-0x10" == -16, "+0b1" == 1, "-0X10" == -16
  - a single layer of double-quotes on BOTH paths: "\"0.8\"" -> 0.8,
    "\"5\"" -> 5 / 5.0, "\" 5 \"" -> 5 (inner whitespace trimmed),
    "\"2.0\"" -> 2 (int), "\"1_000\"" -> 1000
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
  - malformed hex / binary: "0x", "0b", "0xG", "0x10G"
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
    case unwrap(raw) do
      {:ok, inner, quoted} ->
        if strict_shape?(inner) and not (quoted and is_radix_form?(inner)),
          do: parse_float_lex(inner),
          else: {:error, :invalid_number}

      {:ok_paren, inner, _quoted} ->
        # Upstream (float path only) also unwraps a single layer of parens:
        # "(0.8)" -> 0.8, but "(0.8)" as :integer rejects. Handled here so the
        # :integer path does NOT unwrap parens (HB2 parity: quotes yes on both,
        # parens only on float). Quoted hex/binary is rejected on both paths
        # (upstream divergence, HB2).
        if strict_shape?(inner) and not is_radix_form?(inner),
          do: parse_float_lex(inner),
          else: {:error, :invalid_number}
    end
  end

  defp do_parse(raw, :int) do
    t = String.trim(raw)

    cond do
      # Quoted single value on the :integer path (HB2: parity with :float).
      # Upstream accepts '"5"' -> 5, '"010"' -> 10, '"2.0"' -> 2, '"1_000"' -> 1000,
      # '" 5 "' -> 5; rejects '"0.8"' (non-integral), '"1E3"' (quoted exponent
      # form), '"0x10"' / '"0o17"' (quoted radix — rejected on BOTH paths, HB2/HB8).
      quoted_single?(t) ->
        inner = String.trim(binary_part(t, 1, byte_size(t) - 2))

        if strict_shape?(inner) and not is_radix_form?(inner) and
             not String.match?(inner, ~r/[eE]/),
           do: parse_int_lex(inner),
           else: {:error, :invalid_integer}

      # Parenthesised single value on the :integer path (HB7b/HB8 2026-09-29):
      # upstream ACCEPTS "(5)" -> 5 and "(-2)" -> -2 (integer-valued), and
      # REJECTS "(0.8)" because it is FRACTIONAL — not because of the parens.
      # Unwrap one paren layer and parse; integral forms pass, fractional fail.
      paren_single?(t) ->
        inner = String.trim(binary_part(t, 1, byte_size(t) - 2))

        if strict_shape?(inner) and not is_radix_form?(inner),
          do: parse_int_lex(inner),
          else: {:error, :invalid_integer}

      strict_shape?(t) ->
        parse_int_lex(t)

      true ->
        {:error, :invalid_integer}
    end
  end

  # True when t is exactly a parenthesised single value (HB7b/HB8 2026-09-29):
  # upstream accepts "(5)" / "(-2)" on :integer (integer-valued) and rejects
  # "(0.8)" (fractional). The parens themselves are NOT the reason for the
  # reject — only the fractional value is.
  defp paren_single?(t) do
    byte_size(t) >= 2 and String.starts_with?(t, "(") and String.ends_with?(t, ")")
  end

  # ---------------------------------------------------------------------------
  # Shape / unwrap helpers
  # ---------------------------------------------------------------------------

  # Unwrap a single layer of double-quotes OR parens (float path only) and
  # verify the inner content is non-empty. Trims BOTH the outer whitespace AND
  # the inner content, so `  "5"  ` -> "5" (HB2: whitespace inside and around
  # quotes). Returns {:ok, inner, quoted?} / {:ok_paren, inner, quoted?}.
  defp unwrap(t) do
    trimmed = String.trim(t)

    cond do
      byte_size(trimmed) >= 2 and String.starts_with?(trimmed, "\"") and
          String.ends_with?(trimmed, "\"") ->
        {:ok, String.trim(binary_part(trimmed, 1, byte_size(trimmed) - 2)), true}

      byte_size(trimmed) >= 2 and String.starts_with?(trimmed, "(") and
          String.ends_with?(trimmed, ")") ->
        {:ok_paren, String.trim(binary_part(trimmed, 1, byte_size(trimmed) - 2)), false}

      true ->
        {:ok, trimmed, false}
    end
  end

  # True when t is exactly a double-quoted single value (used on the int path
  # so quotes are unwrapped identically to the float path — HB2 parity).
  defp quoted_single?(t) do
    byte_size(t) >= 2 and String.starts_with?(t, "\"") and String.ends_with?(t, "\"")
  end

  # True when the (already unwrapped/trimmed) value is a hex, binary, or OCTAL
  # literal form (0x... / 0b... / 0o..., optionally signed). Upstream rejects
  # these when they arrived in a QUOTED string ("0x10", "0o17" reject on both
  # :float and :integer), but accepts them unquoted (0x10 -> 16, 0o17 -> 15).
  # HB2 2026-09-29; octal added HB8 2026-09-29.
  defp is_radix_form?(s) do
    String.match?(s, ~r/^[+-]?0[xX][0-9A-Fa-f][0-9A-Fa-f_]*$/) or
      String.match?(s, ~r/^[+-]?0[bB][01][01_]*$/) or
      String.match?(s, ~r/^[+-]?0[oO][0-7][0-7_]*$/)
  end

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
      ~r/^
        [+-]?                                   # at most ONE sign
        (?:
          0[xX][0-9A-Fa-f][0-9A-Fa-f_]*         # hex (signed, underscore)
        | 0[bB][01][01_]*                       # binary (signed, underscore)
        | 0[oO][0-7][0-7_]*                     # octal (HB8 2026-09-29)
        | (?:\d+(?:_\d+)*)(?:\.\d*(?:_\d+)*)?   # int or float, trailing "." ok
        | \.\d+(?:_\d+)*                        # ".5"
        )
        (?:[eE][+-]?\d*(?:_\d+)*)?              # exponent: "1e", "1e-1", "1e1_0", "1e_1"
      $/x
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
        # "5.e3" -> "5.0e3" (dot immediately before the exponent). Use a
        # non-capturing sign to keep the group count at 2.
        [_, digits, exp] = Regex.run(~r/^(?:[+-]?)(\d+)\.((?:[eE][+-]?\d+))$/, s)
        digits <> ".0" <> exp

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
        case parse_radix(s, 16, :int) do
          {:ok, int} -> {:ok, int}
          _ -> {:error, :invalid_integer}
        end

      String.match?(s, ~r/^[+-]?0[bB]/) ->
        case parse_radix(s, 2, :int) do
          {:ok, int} -> {:ok, int}
          _ -> {:error, :invalid_integer}
        end

      String.match?(s, ~r/^[+-]?0[oO]/) ->
        # Octal (HB8 2026-09-29): "0o17" -> 15, matching upstream.
        case parse_radix(s, 8, :int) do
          {:ok, int} -> {:ok, int}
          _ -> {:error, :invalid_integer}
        end

      true ->
        case Integer.parse(s) do
          {int, ""} -> {:ok, int}
          _ -> parse_int_from_float(s)
        end
    end
  end

  defp parse_radix(s, base, :float) do
    {sign, digits} =
      cond do
        String.starts_with?(s, "+") -> {1, binary_part(s, 1, byte_size(s) - 1)}
        String.starts_with?(s, "-") -> {-1, binary_part(s, 1, byte_size(s) - 1)}
        true -> {1, s}
      end

    digits =
      digits
      |> String.replace_prefix("0x", "")
      |> String.replace_prefix("0X", "")
      |> String.replace_prefix("0b", "")
      |> String.replace_prefix("0B", "")
      |> String.replace_prefix("0o", "")
      |> String.replace_prefix("0O", "")

    case Integer.parse(digits, base) do
      {int, ""} -> {:ok, sign * int * 1.0}
      :error -> {:error, :invalid_number}
    end
  end

  defp parse_radix(s, base, :int) do
    {sign, digits} =
      cond do
        String.starts_with?(s, "+") -> {1, binary_part(s, 1, byte_size(s) - 1)}
        String.starts_with?(s, "-") -> {-1, binary_part(s, 1, byte_size(s) - 1)}
        true -> {1, s}
      end

    digits =
      digits
      |> String.replace_prefix("0x", "")
      |> String.replace_prefix("0X", "")
      |> String.replace_prefix("0b", "")
      |> String.replace_prefix("0B", "")
      |> String.replace_prefix("0o", "")
      |> String.replace_prefix("0O", "")

    case Integer.parse(digits, base) do
      {int, ""} -> {:ok, sign * int}
      :error -> {:error, :invalid_integer}
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
