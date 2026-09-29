defmodule Dspy.MajorityTest do
  @moduledoc """
  Acceptance rows for M1-c (Dspy.majority/2 + Dspy.Majority.default_normalize/1).

  Rows reference plan/SLICE_LOOP.md "M1-c" and the spec at
  openspec/changes/m1c-majority/specs/majority/spec.md.

  The golden fixture (test/fixtures/upstream_majority_3_4_0.json) is generated
  by the committed script plan/research/upstream_golden/gen_majority_golden.py
  against Python DSPy 3.4.0. It carries the row-5 tie vectors and the
  normalisation vectors used by the table test below.

  Declared shape changes (see docs/COMPATIBILITY.md):
    - The two "list of %Dspy.Prediction{}" oracle tests are ported to list form
      (list-only input, C1).
    - Python counts True and 1 as the SAME vote; Elixir == does not (declared
      deviation, C3 corrected 2026-09-29). Pinned by its own test, not in the
      full-match loop.
  """

  use ExUnit.Case
  doctest Dspy

  alias Dspy.Prediction

  describe "Ordinary (rows 1, 13)" do
    test "clear majority returns the first completion with the winning value" do
      result = Dspy.majority([%{answer: "2"}, %{answer: "2"}, %{answer: "3"}])
      assert result == Dspy.prediction(%{answer: "2"})
    end

    test "single shared key is used without :field" do
      result = Dspy.majority([%{other: "1"}, %{other: "1"}, %{other: "2"}])
      assert result == Dspy.prediction(%{other: "1"})
    end
  end

  describe "field: (row 3)" do
    test "honours field: (first-match winner, verified against upstream 3.4.0)" do
      # field: :other -> counts {other: "1" => 2, other: "2" => 1}; winner "1".
      # First completion with other == "1" is index 0 -> %{answer: "1", other: "1"}.
      result =
        Dspy.majority(
          [
            %{answer: "1", other: "1"},
            %{answer: "2", other: "1"},
            %{answer: "3", other: "2"}
          ],
          field: :other
        )

      assert result == Dspy.prediction(%{answer: "1", other: "1"})
    end
  end

  describe "Ties (rows 4, 5, 5b)" do
    test "tie: earliest first appearance wins" do
      # Port of test_majority_with_no_majority: ["2", "3", "4"] is a tie;
      # the earliest first appearance ("2") wins. (The non-alphabetical
      # tie rows are SS3's job.)
      result = Dspy.majority([%{answer: "2"}, %{answer: "3"}, %{answer: "4"}])
      assert result[:answer] == "2"
    end

    test "row 5: THE TIE TRAP — non-alphabetical tie, earliest first appearance wins" do
      # Deliberately NOT alphabetical: the banned Enum.frequencies |> Enum.max_by
      # winner (count-only) breaks ties by smallest key and would return "a" here.
      # Do not reorder.
      result = Dspy.majority([%{answer: "b"}, %{answer: "a"}], normalize: nil)
      assert result[:answer] == "b"
    end

    test "row 5b: interleaved tie — first appearance wins, not last occurrence" do
      # ["x", "y", "y", "x"]: x and y both have count 2. x's first appearance
      # is earlier, so x wins. This pins the largest-value-tie variant of the
      # banned map tally (see URGENT.md entry 3).
      result =
        Dspy.majority(
          [%{answer: "x"}, %{answer: "y"}, %{answer: "y"}, %{answer: "x"}],
          normalize: nil
        )

      assert result[:answer] == "x"
    end
  end

  describe "Prediction elements (row 11)" do
    test "list elements may be %Dspy.Prediction{} and the winning struct is returned as-is" do
      result =
        Dspy.majority([
          Dspy.prediction(%{answer: "2"}),
          Dspy.prediction(%{answer: "2"}),
          Dspy.prediction(%{answer: "3"})
        ])

      assert result == Dspy.prediction(%{answer: "2"})
    end

    test "row 11 (strengthened): winner with populated completions/metadata is returned as-is" do
      # A "rewrap the winner" mutation (e.g. to_prediction resetting completions/metadata)
      # would lose these fields — this test makes that observable.
      winner = %Prediction{
        attrs: %{answer: "42"},
        completions: [%{text: "42", tokens: 5, logprobs: nil, finish_reason: "stop"}],
        metadata: %{lm_usage: %{"openai:gpt-4" => %{prompt_tokens: 10, completion_tokens: 5}}}
      }

      loser = %Prediction{
        attrs: %{answer: "7"},
        completions: [],
        metadata: %{}
      }

      result = Dspy.majority([winner, winner, loser], normalize: nil)
      assert result == winner
    end
  end

  describe "Normalisation (rows 6, 7, 8, 9, 10)" do
    test "row 6: normalises, then returns the ORIGINAL (not the normalised value)" do
      # ["3", " 2", "2"] normalise to ["3", "2", "2"] so "2" wins (count 2).
      # The winner is returned as the ORIGINAL completion: the first original
      # completion whose normalised value equals the winner is " 2" (not the
      # normalised "2", not the last match).
      result =
        Dspy.majority(
          [%{answer: "3"}, %{answer: " 2"}, %{answer: "2"}],
          normalize: &Dspy.Metrics.normalize_text/1
        )

      assert result[:answer] == " 2"
    end

    test "row 7: nil normalised value means ignore that completion" do
      # normalize maps "x" -> nil, so the two "x" completions are dropped; "y" wins.
      result =
        Dspy.majority(
          [%{answer: "x"}, %{answer: "x"}, %{answer: "y"}],
          normalize: fn v -> if v == "x", do: nil, else: v end
        )

      assert result[:answer] == "y"
    end

    test "row 8: every value normalises to nil -> first completion is returned" do
      # Upstream: when every value is None, count over all of them, so the
      # winner is nil and the first completion is returned.
      result =
        Dspy.majority(
          [%{answer: "p"}, %{answer: "q"}],
          normalize: fn _v -> nil end
        )

      assert result[:answer] == "p"
    end

    test "row 9: false is a vote (only nil means ignore)" do
      # A truthiness filter (Enum.reject(&(!&1))) would drop false; it must not.
      result =
        Dspy.majority(
          [%{answer: "x"}, %{answer: "x"}, %{answer: "y"}],
          normalize: fn v -> if v == "x", do: false, else: v end
        )

      assert result[:answer] == "x"
    end

    test "row 10a: default normaliser drops empty-string results" do
      # Default normaliser turns "!!" into "" (dropped); "3" wins.
      result = Dspy.majority([%{answer: "!!"}, %{answer: "!!"}, %{answer: "3"}])
      assert result[:answer] == "3"
    end

    test "row 10b: normalize: nil is identity (no normalisation)" do
      result =
        Dspy.majority(
          [%{answer: "!!"}, %{answer: "!!"}, %{answer: "3"}],
          normalize: nil
        )

      # With identity, "!!" is the clear majority.
      assert result[:answer] == "!!"
    end

    test "row 10c: default_normalize/1 normalises and maps empty result to nil" do
      # Non-empty normalisation -> the normalised string.
      assert Dspy.Majority.default_normalize("hello") == "hello"
      # A value that normalises to "" becomes nil.
      assert Dspy.Majority.default_normalize("The!!") == nil
      assert Dspy.Majority.default_normalize("the") == nil
    end

    test "row 10d: default_normalize/1 raises on non-binary input" do
      assert_raise FunctionClauseError, fn ->
        Dspy.Majority.default_normalize(123)
      end
    end
  end

  @fixture Jason.decode!(File.read!("test/fixtures/upstream_majority_3_4_0.json"))

  defp fixture_vectors do
    @fixture["oracle"]
    |> Map.to_list()
    |> Enum.concat(@fixture["tie"] |> Map.to_list())
    |> Enum.concat(@fixture["normalise"] |> Map.to_list())
    |> Enum.concat(@fixture["vote_equality"] |> Map.to_list())
    |> Enum.map(fn {desc, expected} ->
      {desc, expected, reconstruct(desc)}
    end)
  end

  defp reconstruct(desc) do
    [list_str, opts_str] = String.split(desc, "] ", parts: 2)
    list_str = list_str <> "]"
    opts_str = String.trim(opts_str)
    completions = parse_python_dicts(list_str)
    opts = parse_opts(opts_str)
    {completions, opts}
  end

  defp parse_python_dicts(str) do
    Regex.scan(~r/\{[^{}]*\}/, str)
    |> Enum.map(fn [dict_str] ->
      dict_str
      |> String.trim_leading("{")
      |> String.trim_trailing("}")
      |> String.split(", ", parts: :infinity)
      |> Enum.map(fn pair ->
        [k, v] = String.split(pair, ": ", parts: 2)
        k = k |> String.trim() |> String.trim("'")
        {String.to_atom(k), parse_python_value(v)}
      end)
      |> Map.new()
    end)
  end

  defp parse_python_value(v) do
    v = String.trim(v)

    if quoted = strip_quotes(v) do
      quoted
    else
      parse_python_literal(v)
    end
  end

  defp strip_quotes(v) when is_binary(v) and byte_size(v) >= 2 do
    cond do
      String.starts_with?(v, "'") and String.ends_with?(v, "'") ->
        String.slice(v, 1, byte_size(v) - 2)

      String.starts_with?(v, "\"") and String.ends_with?(v, "\"") ->
        String.slice(v, 1, byte_size(v) - 2)

      true ->
        nil
    end
  end

  defp strip_quotes(_), do: nil

  defp parse_python_literal("True"), do: true
  defp parse_python_literal("False"), do: false
  defp parse_python_literal("None"), do: nil

  defp parse_python_literal(v) when is_binary(v) do
    cond do
      v =~ ~r/^-?\d+$/ -> String.to_integer(v)
      v =~ ~r/^-?\d+\.\d+$/ -> String.to_float(v)
      true -> v
    end
  end

  defp parse_opts(opts_str) do
    case opts_str do
      "default" ->
        []

      "normalize_text" ->
        [normalize: &Dspy.Metrics.normalize_text/1]

      # identity: the vote-equality rows compare raw Elixir terms (numbers as
      # numbers, true distinct from 1) — see docs/COMPATIBILITY.md (M1-c).
      "identity" ->
        [normalize: nil]

      "field='other'" ->
        [field: :other]

      other ->
        raise "Unknown opts in fixture description: #{inspect(other)}"
    end
  end

  describe "Errors (row 12)" do
    test "empty list raises ArgumentError" do
      assert_raise ArgumentError, ~r/empty list/, fn ->
        Dspy.majority([])
      end
    end

    test "%Dspy.Prediction{} as the whole input raises ArgumentError pointing at the list form" do
      assert_raise ArgumentError, ~r/%Dspy\.Prediction\{\}/, fn ->
        Dspy.majority(Dspy.prediction(%{answer: "2"}))
      end
    end

    test "a completion missing the field raises ArgumentError naming the field" do
      assert_raise ArgumentError, ~r/missing field :other/, fn ->
        Dspy.majority(
          [%{answer: "2", other: "1"}, %{answer: "3"}],
          field: :other
        )
      end
    end

    test "two-key completions without :field raise ArgumentError listing the keys seen" do
      assert_raise ArgumentError, fn ->
        Dspy.majority([%{answer: "2", other: "1"}, %{answer: "3", other: "1"}])
      end
    end

    test "two-key completions without :field: message lists both keys" do
      error =
        assert_raise ArgumentError, fn ->
          Dspy.majority([%{answer: "2", other: "1"}, %{answer: "3", other: "1"}])
        end

      message = Exception.message(error)
      assert message =~ ":answer"
      assert message =~ ":other"
    end
  end

  describe "Golden fixture (upstream 3.4.0 oracle)" do
    # Declared deviation (docs/COMPATIBILITY.md, M1-c): Python counts True and
    # 1 as the SAME vote; Elixir == does not. These two rows are therefore
    # excluded from the full-match loop and pinned by their own explicit test
    # below (which documents the deviation instead of asserting parity).
    @deviation_rows MapSet.new([
                      "[{'answer': '2'}, {'answer': True}, {'answer': 1}] identity",
                      "[{'answer': 1}, {'answer': True}, {'answer': '2'}] identity"
                    ])

    test "all golden fixture rows match Dspy.majority/2" do
      vectors =
        for {desc, expected, rest} <- fixture_vectors(),
            not MapSet.member?(@deviation_rows, desc) do
          {desc, expected, rest}
        end

      for {desc, expected, {completions, opts}} <- vectors do
        refute is_binary(expected) and String.starts_with?(expected, "ERROR:"),
               "Fixture value for #{inspect(desc)} is 'ERROR:' — generator artefact?"

        assert is_binary(expected) or expected in [1, 1.0, true, false, nil],
               "Fixture value for #{inspect(desc)} has an unexpected type: #{inspect(expected)}"

        result = Dspy.majority(completions, opts)

        assert %Prediction{} = result,
               "Dspy.majority returned #{inspect(result)} for #{inspect(desc)}, expected %Dspy.Prediction{}"

        assert result[:answer] == expected,
               "For #{inspect(desc)}: expected answer #{inspect(expected)}, got #{inspect(result[:answer])}"
      end
    end

    test "declared deviation: True and 1 are separate votes (Python counts them as one)" do
      # Upstream 3.4.0 (committed fixture): [2, True, 1] -> True (True and 1 are
      # ONE vote in Python, count 2 beats "2"). Elixir == keeps true and 1
      # distinct, so each has count 1 and the earliest first appearance wins.
      # Pinned here, not in the full-match loop (see docs/COMPATIBILITY.md).
      assert Dspy.majority(
               [%{answer: "2"}, %{answer: true}, %{answer: 1}],
               normalize: nil
             )[:answer] == "2"

      assert Dspy.majority(
               [%{answer: 1}, %{answer: true}, %{answer: "2"}],
               normalize: nil
             )[:answer] == 1
    end

    test "BC2: a nil vote with the DEFAULT normaliser raises (upstream: TypeError)" do
      # A present nil value reaches the normaliser; M1-b's normalize_text/1 has
      # no nil clause, mirroring upstream normalize_text(None) -> TypeError.
      assert_raise FunctionClauseError, fn ->
        Dspy.majority([%{answer: nil}, %{answer: "a"}])
      end
    end

    test "BC2: a nil vote with an identity normaliser is ignored" do
      # A present nil value reaches the identity normaliser, which keeps it;
      # nil means "ignore this completion", so "a" wins.
      result = Dspy.majority([%{answer: nil}, %{answer: "a"}], normalize: nil)
      assert result[:answer] == "a"
    end

    test "BD1: a string-keyed %Prediction{} with an atom :field resolves via Prediction.fetch" do
      # Predictions built from JSON carry string keys. Prediction.fetch/2 falls
      # back atom-to-string (like the rest of the codebase); Map.has_key? on
      # attrs would report the field missing for field: :answer.
      p = Dspy.prediction(%{"answer" => "x"})
      result = Dspy.majority([p, p], field: :answer)
      assert result == p
    end

    test "BC1: a string :field raises ArgumentError naming the passed value" do
      # Both the silent-vote-on-:other form and the confusing ":field required"
      # form are gone: any :field that is neither nil nor an atom raises.
      assert_raise ArgumentError, ~r/:field must be an atom/, fn ->
        Dspy.majority([%{other: "x"}], field: "answer")
      end

      assert_raise ArgumentError, ~r/:field must be an atom/, fn ->
        Dspy.majority([%{answer: "1", other: "2"}, %{answer: "3", other: "4"}], field: "answer")
      end
    end
  end
end
