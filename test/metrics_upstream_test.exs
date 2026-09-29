defmodule Dspy.MetricsUpstreamTest do
  use ExUnit.Case, async: true

  @moduledoc """
  M1-b acceptance rows 5, 6, 7, 9, 10, 11, 14, 16, 17. Oracle: upstream 3.4.0
  golden fixture `test/fixtures/upstream_metrics_3_4_0.json`.
  """

  test "Row 5 (D, ordinary): em/2 cases" do
    assert Dspy.Metrics.em("The Eiffel Tower", ["Eiffel Tower", "Louvre"]) == true
    assert Dspy.Metrics.em("paris", ["Paris"]) == true
    assert Dspy.Metrics.em("paris", ["Paris, France"]) == false
    # Discriminating additions (SS2b): kill the legacy-normaliser mutation and
    # the "first answer only" / "token-set overlap" variants.
    assert Dspy.Metrics.em("the cat", ["cat"]) == true
    assert Dspy.Metrics.em("CAT", ["cat"]) == true
    assert Dspy.Metrics.em("cat", ["cat", "dog"]) == true
    assert Dspy.Metrics.em("cat cat", ["cat"]) == false
  end

  test "Row 6 (D, ordinary): f1/2 case" do
    assert Float.round(Dspy.Metrics.f1("Eiffel Tower is in Paris", ["Paris"]), 2) == 0.33
  end

  test "Row 7 (D, ordinary): Dspy.Metrics.normalize_text(\"The,  Eiffel  Tower!\") == \"eiffel tower\"" do
    assert Dspy.Metrics.normalize_text("The,  Eiffel  Tower!") == "eiffel tower"
  end

  test "Row 10 (G): golden table for normalize_text" do
    fixture_path = "test/fixtures/upstream_metrics_3_4_0.json"
    data = File.read!(fixture_path) |> Jason.decode!()

    for {k, expected} <- data["normalize_text"] do
      assert Dspy.Metrics.normalize_text(k) == expected
    end
  end

  test "Row 11 (G): f1 golden table" do
    fixture_path = "test/fixtures/upstream_metrics_3_4_0.json"
    data = File.read!(fixture_path) |> Jason.decode!()

    for {k, fixture_value} <- data["f1"] do
      # Skip the TypeError record
      if fixture_value != "normalize() argument 2 must be str, not list" do
        [pred, gt] = String.split(k, " | ")

        if k == "  |  " do
          res = Dspy.Metrics.f1(" ", [" "])
          assert res == 0.0
          assert is_float(res)
        else
          assert Float.round(Dspy.Metrics.f1(pred, [gt]), 6) ==
                   Float.round(fixture_value * 1.0, 6)
        end
      end
    end

    # Explicit discriminator for the fixture entry "cat cat dog | cat cat bird"
    # (both sides carry "cat" twice): multiset overlap is min(2, 2) = 2 ->
    # F1 = 0.6667; set-based overlap counts the shared token once -> 0.3333.
    # This is the mutation row 11 exists to kill.
    assert Float.round(Dspy.Metrics.f1("cat cat dog", ["cat cat bird"]), 4) == 0.6667
  end

  test "Row 11b: f1/2 list-taking API (f1_list golden table)" do
    fixture_path = "test/fixtures/upstream_metrics_3_4_0.json"
    data = File.read!(fixture_path) |> Jason.decode!()

    for {k, expected} <- data["f1_list"] do
      [pred, answers_str] = String.split(k, " | ", parts: 2)

      # answers_str is a Python-list repr of single-quoted strings (the fixture
      # writer controls the shape); parse the quoted entries. `[^']*` (not
      # `[^']+`) so an empty entry (`" | ['']"` -> `"['']"`) also parses.
      answers =
        Regex.scan(~r/'([^']*)'/u, answers_str) |> Enum.map(fn m -> Enum.at(m, 1) end)

      assert answers != [], "f1_list key #{inspect(k)} did not parse to answers"

      assert Float.round(Dspy.Metrics.f1(pred, answers), 6) ==
               Float.round(expected * 1.0, 6),
             "f1_list key #{inspect(k)}"
    end
  end

  test "Row 16: return types" do
    true_res = Dspy.Metrics.em("paris", ["Paris"])
    false_res = Dspy.Metrics.em("paris", ["France"])
    assert is_boolean(true_res)
    assert is_boolean(false_res)

    f1_res = Dspy.Metrics.f1("cat", ["bird"])
    assert is_float(f1_res)
    assert f1_res == 0.0
  end

  test "Row 17 (legacy pin, second half): Dspy.Metrics.exact_match keeps articles" do
    example = Dspy.Example.new(%{answer: "The cat"})
    pred = Dspy.Prediction.new(%{answer: "cat"})

    assert Dspy.Metrics.exact_match(example, pred) == 0.0
  end

  # --- SS3: answer_exact_match/3 ------------------------------------------

  defp aem_fixture do
    "test/fixtures/upstream_metrics_3_4_0.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("answer_exact_match_tests")
  end

  test "Row 1 (T, oracle port test_answer_exact_match_string): binary answer, exact -> true" do
    example = Dspy.Example.new(%{question: "What is 1+1?", answer: "2"})
    pred = Dspy.Prediction.new(%{answer: "2"})

    assert Dspy.Metrics.answer_exact_match(example, pred) == true
    assert Dspy.Metrics.answer_exact_match(example, pred) == aem_fixture()["2 | 2"]
  end

  test "Row 2 (T, oracle port test_answer_exact_match_list): list answer, first matches -> true" do
    example = Dspy.Example.new(%{question: "What is 1+1?", answer: ["2", "two"]})
    pred = Dspy.Prediction.new(%{answer: "2"})

    assert Dspy.Metrics.answer_exact_match(example, pred) == true
    assert Dspy.Metrics.answer_exact_match(example, pred) == aem_fixture()["['2', 'two'] | 2"]
  end

  test "Row 3 (T, oracle port test_answer_exact_match_no_match): no match -> false" do
    example = Dspy.Example.new(%{question: "What is 1+1?", answer: "2"})
    pred = Dspy.Prediction.new(%{answer: "3"})

    assert Dspy.Metrics.answer_exact_match(example, pred) == false
    assert Dspy.Metrics.answer_exact_match(example, pred) == aem_fixture()["2 | 3"]
  end

  test "Row 4 (G): any answer in the list matches (kills first-answer-only)" do
    example = Dspy.Example.new(%{answer: ["2", "two"]})
    pred = Dspy.Prediction.new(%{answer: "two"})

    assert Dspy.Metrics.answer_exact_match(example, pred) == true
    assert Dspy.Metrics.answer_exact_match(example, pred) == aem_fixture()["['2', 'two'] | two"]
  end

  test "Row 8 (D): Eiffel Tower docstring example, both frac calls true" do
    example = Dspy.Example.new(%{answer: ["Eiffel Tower", "Louvre"]})
    pred = Dspy.Prediction.new(%{answer: "The Eiffel Tower"})

    assert Dspy.Metrics.answer_exact_match(example, pred, frac: 1.0) == true
    assert Dspy.Metrics.answer_exact_match(example, pred, frac: 0.5) == true
  end

  test "Row 12: frac boundaries" do
    # F1("cat dog", ["cat bird"]) == 0.5 exactly — threshold is inclusive.
    example = Dspy.Example.new(%{answer: "cat bird"})
    pred = Dspy.Prediction.new(%{answer: "cat dog"})

    assert Dspy.Metrics.answer_exact_match(example, pred, frac: 0.5) == true
    assert Dspy.Metrics.answer_exact_match(example, pred, frac: 0.5000001) == false

    # frac: 1.0 exactly takes the EM path (contract: `frac >= 1.0`). Documents
    # the boundary; the dispatch itself is pinned by the frac: 1.5 case below
    # (only the EM path can return true there) and proven by the SS3
    # always-F1 mutation (logs/mut-row12-mut1.log).
    assert Dspy.Metrics.answer_exact_match(example, pred, frac: 1.0) == false

    # frac >= 1.0 takes the EM path (the F1 path would give 1.0 >= 1.5 -> false).
    exact_example = Dspy.Example.new(%{answer: "2"})
    exact_pred = Dspy.Prediction.new(%{answer: "2"})
    assert Dspy.Metrics.answer_exact_match(exact_example, exact_pred, frac: 1.5) == true

    # F3 quirk (pinned): zero-overlap pair with frac: 0.0 -> true.
    zero_example = Dspy.Example.new(%{answer: "bird"})
    zero_pred = Dspy.Prediction.new(%{answer: "cat"})
    assert Dspy.Metrics.answer_exact_match(zero_example, zero_pred, frac: 0.0) == true
  end

  test "Row 13: A4 errors each name the offending field" do
    no_answer_example = Dspy.Example.new(%{question: "What is 1+1?"})
    no_answer_prediction = Dspy.Prediction.new(%{question: "what"})

    # 1. example without :answer key
    assert_raise ArgumentError, ~r/example.*answer/, fn ->
      Dspy.Metrics.answer_exact_match(no_answer_example, Dspy.Prediction.new(%{answer: "2"}))
    end

    # 2. prediction without :answer key
    assert_raise ArgumentError, ~r/prediction.*answer/, fn ->
      Dspy.Metrics.answer_exact_match(Dspy.Example.new(%{answer: "2"}), no_answer_prediction)
    end

    # 3. example answer is an integer
    assert_raise ArgumentError, ~r/example.*answer/, fn ->
      Dspy.Metrics.answer_exact_match(
        Dspy.Example.new(%{answer: 42}),
        Dspy.Prediction.new(%{answer: "2"})
      )
    end

    # 4. example answer is an empty list
    assert_raise ArgumentError, ~r/example.*answer/, fn ->
      Dspy.Metrics.answer_exact_match(
        Dspy.Example.new(%{answer: []}),
        Dspy.Prediction.new(%{answer: "2"})
      )
    end

    # 5. example answer is a list containing a non-binary
    assert_raise ArgumentError, ~r/example.*answer/, fn ->
      Dspy.Metrics.answer_exact_match(
        Dspy.Example.new(%{answer: ["ok", 7]}),
        Dspy.Prediction.new(%{answer: "2"})
      )
    end

    # 6. prediction answer is a list, not a binary
    assert_raise ArgumentError, ~r/prediction.*answer/, fn ->
      Dspy.Metrics.answer_exact_match(
        Dspy.Example.new(%{answer: "2"}),
        Dspy.Prediction.new(%{answer: ["2"]})
      )
    end

    # 7. prediction answer is nil
    assert_raise ArgumentError, ~r/prediction.*answer/, fn ->
      Dspy.Metrics.answer_exact_match(
        Dspy.Example.new(%{answer: "2"}),
        Dspy.Prediction.new(%{answer: nil})
      )
    end

    # 8. frac is a string
    assert_raise ArgumentError, ~r/frac.*number/, fn ->
      Dspy.Metrics.answer_exact_match(
        Dspy.Example.new(%{answer: "2"}),
        Dspy.Prediction.new(%{answer: "2"}),
        frac: "0.5"
      )
    end

    # 9. frac is a boolean
    assert_raise ArgumentError, ~r/frac.*number/, fn ->
      Dspy.Metrics.answer_exact_match(
        Dspy.Example.new(%{answer: "2"}),
        Dspy.Prediction.new(%{answer: "2"}),
        frac: true
      )
    end
  end

  # --- SS4: answer_passage_match/2 -----------------------------------------

  defp apm_fixture do
    "test/fixtures/upstream_metrics_3_4_0.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("answer_passage_match")
  end

  test "Row 9 (D, upstream docstring): answer found in a passage -> true" do
    # Upstream docstring, metrics.py:337-340.
    example = Dspy.Example.new(%{answer: "Eiffel Tower"})
    pred = Dspy.Prediction.new(%{context: ["The Eiffel Tower is in Paris.", "..."]})

    assert Dspy.Metrics.answer_passage_match(example, pred) == true

    # Ordinary non-match: same context, answer absent from every passage.
    louvre_example = Dspy.Example.new(%{answer: "Louvre"})
    assert Dspy.Metrics.answer_passage_match(louvre_example, pred) == false
  end

  test "Row 14 (G, F5 ruled): a binary context raises ArgumentError naming :context" do
    # Fixture case_5: upstream 3.4.0 iterates the bare string's characters and
    # returns the fixture's `expected: false`. F5: stricter than upstream —
    # Elixir binaries are not enumerable, so a bare string context raises.
    # Declared in docs/COMPATIBILITY.md; the fixture keeps the upstream value
    # as documentation only (documented, not asserted here).
    example = Dspy.Example.new(%{answer: "ans"})
    pred = Dspy.Prediction.new(%{context: "bare string context"})

    assert_raise ArgumentError, ~r/context/, fn ->
      Dspy.Metrics.answer_passage_match(example, pred)
    end
  end

  test "Row 14 (G): answer_passage_match golden table (fixture)" do
    # case_5 (bare string context) is excluded here and asserted separately
    # above (F5).
    for {name, entry} <- apm_fixture(), name != "case_5" do
      ans = entry["case"]["ans"]
      ctx = entry["case"]["ctx"]
      expected = entry["expected"]

      example = Dspy.Example.new(%{answer: ans})
      pred = Dspy.Prediction.new(%{context: ctx})

      assert Dspy.Metrics.answer_passage_match(example, pred) == expected, "case #{name}"
    end

    # Explicit discriminator (SS4): case_6 kills a String.contains?-on-the-
    # token-joined-passage implementation ("eiffel tower" is NOT a substring
    # of "eiffel a tower building"). Note: no fixture/inline case kills a
    # token-SET-overlap implementation, because normalize_text/1 strips ASCII
    # punctuation — a passage "a dog cat, bird" already tokenizes to the
    # contiguous run [dog, cat, bird]. The set-vs-run distinction is pinned
    # by f1's multiset row (row 11) instead, and upstream 3.4.0's own
    # has_answer (token runs) is what the implementation mirrors.
    assert Dspy.Metrics.answer_passage_match(
             Dspy.Example.new(%{answer: "Eiffel Tower"}),
             Dspy.Prediction.new(%{context: ["This is the eiffel a tower building."]})
           ) == true
  end

  test "Row 16 (half, APM): answer_passage_match/2 returns exact booleans" do
    true_res =
      Dspy.Metrics.answer_passage_match(
        Dspy.Example.new(%{answer: "Eiffel Tower"}),
        Dspy.Prediction.new(%{context: ["The Eiffel Tower is in Paris."]})
      )

    false_res =
      Dspy.Metrics.answer_passage_match(
        Dspy.Example.new(%{answer: "Louvre"}),
        Dspy.Prediction.new(%{context: ["The Eiffel Tower is in Paris."]})
      )

    assert is_boolean(true_res)
    assert is_boolean(false_res)
  end

  test "Row 16 (half, AEM): answer_exact_match/3 returns exact booleans" do
    true_res =
      Dspy.Metrics.answer_exact_match(
        Dspy.Example.new(%{answer: "2"}),
        Dspy.Prediction.new(%{answer: "2"})
      )

    false_res =
      Dspy.Metrics.answer_exact_match(
        Dspy.Example.new(%{answer: "2"}),
        Dspy.Prediction.new(%{answer: "3"})
      )

    assert is_boolean(true_res)
    assert is_boolean(false_res)
  end
end
