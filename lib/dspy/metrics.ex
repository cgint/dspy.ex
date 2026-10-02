defmodule Dspy.Metrics do
  @moduledoc """
  Standard evaluation metrics for DSPy programs.

  Provides common metrics used in language model evaluation:
  - Exact match
  - F1 score (token-level)
  - BLEU score
  - ROUGE scores
  - Accuracy
  - Custom metric composition

  ## Usage

      # Use predefined metrics
      score = Dspy.Metrics.exact_match(example, prediction)
      f1 = Dspy.Metrics.f1_score(example, prediction)
      
      # Create custom metrics
      custom_metric = Dspy.Metrics.create_metric(fn example, pred ->
        # Custom scoring logic
        if String.contains?(pred[:answer], example[:answer]), do: 1.0, else: 0.0
      end)

  """

  alias Dspy.{Example, Prediction}

  @type metric_function :: (Example.t(), Prediction.t() -> number())
  @type metric_result :: %{
          score: number(),
          details: map()
        }

  @doc """
  Upstream 3.4.0 `EM` metric.
  """
  @spec em(String.t(), [String.t()]) :: boolean()
  def em(pred, answers) when is_binary(pred) and is_list(answers) do
    if answers == [] do
      raise ArgumentError, message: "answers must be a non-empty list"
    end

    Enum.any?(answers, fn ans -> pairwise_em(pred, ans) end)
  end

  @doc """
  Upstream 3.4.0 `F1` metric.
  """
  @spec f1(String.t(), [String.t()]) :: float()
  def f1(pred, answers) when is_binary(pred) and is_list(answers) do
    if answers == [] do
      raise ArgumentError, message: "answers must be a non-empty list"
    end

    Enum.map(answers, fn ans -> pairwise_f1(pred, ans) end)
    |> Enum.max()
  end

  @doc """
  Port of upstream 3.4.0 `answer_exact_match` (`dspy/evaluate/metrics.py:285-317`).

  Reads `:answer` from the example (a binary, or a non-empty list of binaries —
  a binary is treated as a single-answer list) and from the prediction (must be
  a binary). Returns exactly `true` or `false`:

  - `frac >= 1.0` (default `frac: 1.0`) → `em/2`;
  - `frac < 1.0` → `f1/2 >= frac` (inclusive). Note the pinned upstream quirk
    (F3): `frac: 0.0` is always `true`.

  Declared deviation from upstream (F4, ruled): there is **no `trace`
  parameter**; `frac` is an option, so `&Dspy.Metrics.answer_exact_match/2`
  is usable as an Evaluate metric.

  Every bad input raises `ArgumentError` naming the offending field — a
  missing field is never defaulted to `""` (A4).

  ## Examples

      iex> example = Dspy.Example.new(%{answer: ["Eiffel Tower", "Louvre"]})
      iex> pred = Dspy.Prediction.new(%{answer: "The Eiffel Tower"})
      iex> Dspy.Metrics.answer_exact_match(example, pred, frac: 1.0)
      true
      iex> Dspy.Metrics.answer_exact_match(example, pred, frac: 0.5)
      true
  """
  @spec answer_exact_match(Example.t(), Prediction.t(), keyword()) :: boolean()
  def answer_exact_match(example, prediction, opts \\ []) do
    frac = valid_frac!(opts)
    answers = example_answers!(fetch_field!(example, "example"))
    pred_answer = prediction_answer!(fetch_field!(prediction, "prediction"))

    if frac >= 1.0 do
      em(pred_answer, answers)
    else
      f1(pred_answer, answers) >= frac
    end
  end

  @doc """
  Port of upstream 3.4.0 `answer_passage_match` (`dspy/evaluate/metrics.py:259-270,320-348`).

  Reads `:answer` from the example (a binary, or a non-empty list of binaries —
  same validation as `answer_exact_match/2,3`) and `:context` from the
  prediction, which MUST be a list of binaries. Returns exactly `true` or
  `false`:

  - `true` iff some answer's DPR-token list appears as a **contiguous token
    run** in some passage's DPR-token list, after `normalize_text/1` on both
    sides;
  - `false` for an empty context list (not an error).

  Matching is token-run based — never substring (`String.contains?`) based
  (A6). A bare string `:context` raises `ArgumentError` naming `:context`
  (F5, ruled: Elixir binaries are not enumerable — upstream would iterate
  its characters; declared in `docs/COMPATIBILITY.md`).

  ## Examples

      iex> example = Dspy.Example.new(%{answer: "Eiffel Tower"})
      iex> pred = Dspy.Prediction.new(%{context: ["The Eiffel Tower is in Paris.", "..."]})
      iex> Dspy.Metrics.answer_passage_match(example, pred)
      true
  """
  @spec answer_passage_match(Example.t(), Prediction.t()) :: boolean()
  def answer_passage_match(example, prediction) do
    answers = example_answers!(fetch_field!(example, "example"))
    context = context_passages!(fetch_context!(prediction, "prediction"))

    answer_tokens = Enum.map(answers, fn ans -> ans |> normalize_text() |> dpr_tokens() end)

    Enum.any?(context, fn passage ->
      passage_tokens = passage |> normalize_text() |> dpr_tokens()
      Enum.any?(answer_tokens, fn run -> contains_token_run?(passage_tokens, run) end)
    end)
  end

  # A4: no silent `""` default — a missing :context field raises, naming the struct.
  # H15: routed through the canonical Dspy.Attrs accessor (string-key fallback).
  defp fetch_context!(%{attrs: attrs}, label) do
    case Dspy.Attrs.fetch(attrs, :context) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{label}[:context] is missing"
    end
  end

  defp context_passages!(context) when is_list(context) do
    unless Enum.all?(context, &is_binary/1) do
      raise ArgumentError,
            "prediction[:context] must be a list of binaries (passages), got: #{inspect(context)}"
    end

    context
  end

  defp context_passages!(context) do
    # F5 (ruled): a bare string context is an error, not a character stream —
    # Elixir binaries are not enumerable (upstream would iterate characters).
    raise ArgumentError,
          "prediction[:context] must be a list of binaries (passages), got: #{inspect(context)}"
  end

  # Upstream DPR tokens (`dpr.py:151-206,231-236`): NFD-normalize, scan with
  # `SimpleTokenizer`'s `ALPHA_NUM | NON_WS`, lowercase each match.
  #
  # Two notes on the form below:
  #
  #   * The NFD result is lowercased before the scan: the local type checker
  #     types `:unicode.characters_to_nfd_binary/1` `dynamic()`, and default
  #     case mapping is per-codepoint and stable across the L/N/M/Z/C classes
  #     in the token regex, so tokenizing the lowercased text yields exactly
  #     the same token sequence as lowercasing each match (the per-match
  #     downcase is kept, mirroring upstream `DPR_normalize`).
  #   * `Regex.scan/2` is called in call form (not pipe) because this
  #     checker mis-types a piped argument.
  defp dpr_tokens(text) when is_binary(text) do
    nfd = :unicode.characters_to_nfd_binary(text)
    lower = String.downcase(nfd)

    Regex.scan(~r/[\p{L}\p{N}\p{M}]+|[^\p{Z}\p{C}]/u, lower)
    |> Enum.map(fn [match] -> String.downcase(match) end)
  end

  # True iff `run` appears as a contiguous slice of `haystack` (upstream
  # `has_answer`, `dpr.py:198-206` — whitespace-span bookkeeping dropped,
  # we only need the token sequence).
  defp contains_token_run?(_haystack, []) do
    # Mirrors upstream: an empty answer run matches at any position.
    true
  end

  defp contains_token_run?(haystack, run) when is_list(haystack) and is_list(run) do
    n = length(run)

    if length(haystack) < n do
      false
    else
      Enum.reduce_while(0..(length(haystack) - n), false, fn i, acc ->
        if Enum.slice(haystack, i, n) == run do
          {:halt, true}
        else
          {:cont, acc}
        end
      end)
    end
  end

  # A4: no silent `""` default — a missing :answer field raises, naming the struct.
  # H15: routed through the canonical Dspy.Attrs accessor (string-key fallback);
  # a key missing in BOTH forms still raises the same message (MR3c pins this).
  defp fetch_field!(%{attrs: attrs}, label) do
    case Dspy.Attrs.fetch(attrs, :answer) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{label}[:answer] is missing"
    end
  end

  defp example_answers!(value) when is_binary(value), do: [value]

  defp example_answers!(list) when is_list(list) do
    if list != [] and Enum.all?(list, fn entry -> is_binary(entry) end) do
      list
    else
      raise ArgumentError,
            "example[:answer] must be a binary or a non-empty list of binaries, got: #{inspect(list)}"
    end
  end

  defp example_answers!(value) do
    raise ArgumentError,
          "example[:answer] must be a binary or a non-empty list of binaries, got: #{inspect(value)}"
  end

  defp prediction_answer!(value) do
    case value do
      binary when is_binary(binary) -> binary
      _ -> raise ArgumentError, "prediction[:answer] must be a binary, got: #{inspect(value)}"
    end
  end

  defp valid_frac!(opts) do
    case Keyword.get(opts, :frac, 1.0) do
      frac when is_number(frac) -> frac
      other -> raise ArgumentError, "frac must be a number, got: #{inspect(other)}"
    end
  end

  defp pairwise_em(pred, ans) do
    normalize_text(pred) == normalize_text(ans)
  end

  defp pairwise_f1(pred, ans) do
    pred_tokens = pred |> normalize_text() |> String.split()
    ans_tokens = ans |> normalize_text() |> String.split()

    if length(pred_tokens) == 0 and length(ans_tokens) == 0 do
      0.0
    else
      pred_freq = Enum.frequencies(pred_tokens)
      ans_freq = Enum.frequencies(ans_tokens)

      common_tokens = Map.keys(pred_freq) |> Enum.filter(&Map.has_key?(ans_freq, &1))

      num_same =
        Enum.reduce(common_tokens, 0, fn token, acc ->
          acc + min(Map.get(pred_freq, token), Map.get(ans_freq, token))
        end)

      if num_same == 0 do
        0.0
      else
        precision = 1.0 * num_same / length(pred_tokens)
        recall = 1.0 * num_same / length(ans_tokens)

        2 * precision * recall / (precision + recall)
      end
    end
  end

  @doc """
  Exact match metric - returns 1.0 if answers match exactly, 0.0 otherwise.

  ## Parameters

  - `example` - Ground truth example
  - `prediction` - Model prediction
  - `field` - Field to compare (default: :answer)

  ## Examples

      score = Dspy.Metrics.exact_match(example, prediction)
      # 1.0 or 0.0

  """
  @spec exact_match(Example.t(), Prediction.t(), atom()) :: number()
  def exact_match(example, prediction, field \\ :answer) do
    truth = get_field_value(example, field)
    pred = get_field_value(prediction, field)

    if legacy_normalize(truth) == legacy_normalize(pred), do: 1.0, else: 0.0
  end

  @doc """
  Token-level F1 score between ground truth and prediction.

  ## Parameters

  - `example` - Ground truth example
  - `prediction` - Model prediction  
  - `field` - Field to compare (default: :answer)

  ## Returns

  F1 score between 0.0 and 1.0

  """
  @spec f1_score(Example.t(), Prediction.t(), atom()) :: number()
  def f1_score(example, prediction, field \\ :answer) do
    truth = get_field_value(example, field)
    pred = get_field_value(prediction, field)

    truth_tokens = tokenize(truth)
    pred_tokens = tokenize(pred)

    if length(truth_tokens) == 0 and length(pred_tokens) == 0 do
      1.0
    else
      common = MapSet.intersection(MapSet.new(truth_tokens), MapSet.new(pred_tokens))

      precision =
        if length(pred_tokens) > 0, do: MapSet.size(common) / length(pred_tokens), else: 0.0

      recall =
        if length(truth_tokens) > 0, do: MapSet.size(common) / length(truth_tokens), else: 0.0

      if precision + recall > 0 do
        2 * precision * recall / (precision + recall)
      else
        0.0
      end
    end
  end

  @doc """
  Accuracy metric for classification tasks.

  ## Parameters

  - `example` - Ground truth example
  - `prediction` - Model prediction
  - `field` - Field to compare (default: :answer)

  """
  @spec accuracy(Example.t(), Prediction.t(), atom()) :: number()
  def accuracy(example, prediction, field \\ :answer) do
    exact_match(example, prediction, field)
  end

  @doc """
  Contains metric - returns 1.0 if prediction contains ground truth.

  Useful for checking if key information is present in longer responses.

  """
  @spec contains(Example.t(), Prediction.t(), atom()) :: number()
  def contains(example, prediction, field \\ :answer) do
    truth = get_field_value(example, field) |> legacy_normalize()
    pred = get_field_value(prediction, field) |> legacy_normalize()

    if String.contains?(pred, truth), do: 1.0, else: 0.0
  end

  @doc """
  Substring match metric with partial credit.

  Returns the ratio of matching substrings.

  """
  @spec substring_match(Example.t(), Prediction.t(), atom()) :: number()
  def substring_match(example, prediction, field \\ :answer) do
    truth = get_field_value(example, field) |> legacy_normalize()
    pred = get_field_value(prediction, field) |> legacy_normalize()

    if String.length(truth) == 0 and String.length(pred) == 0 do
      1.0
    else
      max_len = max(String.length(truth), String.length(pred))
      if max_len == 0, do: 0.0, else: longest_common_substring(truth, pred) / max_len
    end
  end

  @doc """
  BLEU score approximation for text generation evaluation.

  Simplified BLEU-1 implementation based on unigram precision.

  """
  @spec bleu_score(Example.t(), Prediction.t(), atom()) :: number()
  def bleu_score(example, prediction, field \\ :answer) do
    truth = get_field_value(example, field)
    pred = get_field_value(prediction, field)

    truth_tokens = tokenize(truth)
    pred_tokens = tokenize(pred)

    if length(pred_tokens) == 0 do
      0.0
    else
      truth_set = MapSet.new(truth_tokens)
      matches = pred_tokens |> Enum.count(&MapSet.member?(truth_set, &1))

      precision = matches / length(pred_tokens)

      # Add brevity penalty
      brevity_penalty =
        if length(pred_tokens) < length(truth_tokens) do
          :math.exp(1 - length(truth_tokens) / length(pred_tokens))
        else
          1.0
        end

      precision * brevity_penalty
    end
  end

  @doc """
  Numeric accuracy for mathematical problems.

  Compares numeric values with optional tolerance.

  """
  @spec numeric_accuracy(Example.t(), Prediction.t(), atom(), number()) :: number()
  def numeric_accuracy(example, prediction, field \\ :answer, tolerance \\ 1.0e-6) do
    truth = extract_number(get_field_value(example, field))
    pred = extract_number(get_field_value(prediction, field))

    case {truth, pred} do
      {nil, nil} -> 1.0
      {nil, _} -> 0.0
      {_, nil} -> 0.0
      {t, p} -> if abs(t - p) <= tolerance, do: 1.0, else: 0.0
    end
  end

  @doc """
  Create a custom metric function with pre/post processing.

  ## Parameters

  - `metric_fn` - Function that takes (example, prediction) and returns score
  - `opts` - Options: normalize, field, transform

  ## Examples

      custom_metric = Dspy.Metrics.create_metric(fn example, pred ->
        # Custom logic here
        similarity_score(example[:answer], pred[:answer])
      end, normalize: true)

  """
  @spec create_metric(function(), keyword()) :: metric_function()
  def create_metric(metric_fn, opts \\ []) do
    normalize = Keyword.get(opts, :normalize, false)
    field = Keyword.get(opts, :field, :answer)
    transform = Keyword.get(opts, :transform, &Function.identity/1)

    fn example, prediction ->
      try do
        # Apply transformations
        processed_example =
          if normalize do
            update_field(example, field, &legacy_normalize/1)
          else
            example
          end

        processed_prediction =
          if normalize do
            update_field(prediction, field, &legacy_normalize/1)
          else
            prediction
          end

        # Apply custom transform
        final_example = transform.(processed_example)
        final_prediction = transform.(processed_prediction)

        # Run metric
        score = metric_fn.(final_example, final_prediction)
        if is_number(score), do: score, else: 0.0
      rescue
        _ -> 0.0
      end
    end
  end

  @doc """
  Combine multiple metrics with weights.

  ## Parameters

  - `metrics` - List of {metric_function, weight} tuples

  ## Returns

  Combined metric function

  """
  @spec combine_metrics(list({metric_function(), number()})) :: metric_function()
  def combine_metrics(metrics) do
    total_weight = metrics |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    fn example, prediction ->
      weighted_sum =
        metrics
        |> Enum.map(fn {metric_fn, weight} ->
          score = metric_fn.(example, prediction)
          score * weight
        end)
        |> Enum.sum()

      if total_weight > 0, do: weighted_sum / total_weight, else: 0.0
    end
  end

  # Private helper functions

  # H15: the three private copies of the atom→string fallback are deleted and
  # routed through the canonical Dspy.Attrs accessor. (The old
  # `get_field_value(value, _field), do: to_string(value)` clause is
  # unreachable: every caller passes an Example/Prediction/map.)
  defp get_field_value(source, field), do: Dspy.Attrs.get(source, field, "")

  defp update_field(%Example{attrs: attrs} = example, field, transform_fn) do
    new_value = get_field_value(example, field) |> transform_fn.()
    %{example | attrs: Map.put(attrs, field, new_value)}
  end

  defp update_field(%Prediction{attrs: attrs} = prediction, field, transform_fn) do
    new_value = get_field_value(prediction, field) |> transform_fn.()
    %{prediction | attrs: Map.put(attrs, field, new_value)}
  end

  @doc """
  Equal to DSPy 3.4.0 `dspy.evaluate.normalize_text` for every binary; it will never be improved — a better normaliser gets a new name.
  """
  @spec normalize_text(String.t()) :: String.t()
  def normalize_text(text) when is_binary(text) do
    :unicode.characters_to_nfd_binary(text)
    |> String.downcase(:greek)
    |> String.replace(~r/[!"#$%&'()*+,\-.\/:;<=>?@\[\\\]^_`{|}~]/u, "")
    |> String.replace(~r/(?<![\p{L}\p{N}_])(a|an|the)(?![\p{L}\p{N}_])/u, " ")
    |> String.replace(~r/[\s\x{1c}-\x{1f}]+/u, " ")
    |> String.trim()
  end

  defp legacy_normalize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp legacy_normalize(value), do: value |> to_string() |> legacy_normalize()

  defp tokenize(text) when is_binary(text) do
    text
    |> legacy_normalize()
    |> String.split()
    |> Enum.reject(&(&1 == ""))
  end

  defp tokenize(value), do: value |> to_string() |> tokenize()

  defp extract_number(text) when is_binary(text) do
    case Regex.scan(~r/-?\d+\.?\d*/, text) do
      [[number_str] | _] ->
        case Float.parse(number_str) do
          {num, _} ->
            num

          :error ->
            case Integer.parse(number_str) do
              {num, _} -> num * 1.0
              :error -> nil
            end
        end

      _ ->
        nil
    end
  end

  defp extract_number(num) when is_number(num), do: num * 1.0
  defp extract_number(_), do: nil

  defp longest_common_substring(s1, s2) do
    len1 = String.length(s1)
    len2 = String.length(s2)

    if len1 == 0 or len2 == 0 do
      0
    else
      # Dynamic programming approach for LCS length
      dp =
        Enum.reduce(0..len1, %{}, fn i, acc_i ->
          Enum.reduce(0..len2, acc_i, fn j, acc_j ->
            value =
              cond do
                i == 0 or j == 0 ->
                  0

                String.at(s1, i - 1) == String.at(s2, j - 1) ->
                  Map.get(acc_j, {i - 1, j - 1}, 0) + 1

                true ->
                  max(Map.get(acc_j, {i - 1, j}, 0), Map.get(acc_j, {i, j - 1}, 0))
              end

            Map.put(acc_j, {i, j}, value)
          end)
        end)

      Map.get(dp, {len1, len2}, 0)
    end
  end
end
