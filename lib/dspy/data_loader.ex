defmodule Dspy.DataLoader do
  @moduledoc """
  Loaders and seeded sampling for M1-e (contract A4, A1; upstream
  `dspy/datasets/dataloader.py:63-104,138-198`).

  `from_csv/2` and `from_json/2` read local files (RFC 4180 CSV and JSON /
  JSON Lines) and return `Example`s with **string keys only** — upstream
  keys are strings, and no atoms are ever created from file data (B2).
  `train_test_split/2` and `sample/3` use `Dspy.Random` (bit-exact CPython
  MT19937, M1-e phase 1): the same integer seed gives the same result on
  every Elixir/OTP version, and the caller's `:rand` state is never
  touched.

  ## Declared deviations from upstream (see `docs/COMPATIBILITY.md`)

  - **E2:** CSV cells stay strings (upstream's pandas type inference
    silently corrupts — one missing cell turns a whole column into
    floats, and the inference breaks upstream's own `answer_exact_match`
    on numeric answers). JSON keeps JSON types.
  - **E3:** a CSV row with more fields than the header raises, naming the
    line (upstream silently shifts the row into garbage).
  - **E4:** a duplicate CSV header raises, naming the column (upstream
    renames it `a.1`).
  - **E7:** `seed: nil` takes a fresh seed from `:crypto.strong_rand_bytes/1`
    — not reproducible, as upstream, but never touching the caller's
    `:rand` state (upstream `train_test_split` re-seeds the GLOBAL
    `random` module; not emulated).
  """

  alias Dspy.Example
  alias Dspy.Signature.NumberParser

  # ---------------------------------------------------------------------------
  # from_csv
  # ---------------------------------------------------------------------------

  @doc """
  Load a local RFC 4180 CSV file into `Example`s with string keys.

  - the first record is the header (required; a duplicate name raises,
    E4; a row with more fields than the header raises, E3);
  - a leading UTF-8 BOM is stripped; blank lines are skipped;
  - empty cells (including quoted `""`) read as `nil`; the missing cells
    of a short row are filled with `nil`;
  - every cell is a **string** (E2) — no type inference;
  - surrounding whitespace is kept; quoted commas, quotes and embedded
    newlines survive (NimbleCSV.RFC4180, the same module M1-a writes with).

  Options:

    - `:fields` — a subset of the header, returned in the given order
      (atoms or strings, matched by `to_string`); an unknown name raises
      `ArgumentError` naming it.
    - `:input_keys` — names passed to `Example.with_inputs/2`.
    - `:types` — opt-in column typing (T1, ruling 2026-09-30): a map of
      column name (`String.t()`) to `:integer` or `:number`, parsed with
      the strict H12 `Dspy.Signature.NumberParser`; a bad cell raises
      `ArgumentError` naming the line and column. Untyped columns stay
      strings (E2 is the default).

  ## The silent-0 pitfall (declared, T1)

  A user metric that compares a typed `:integer` / `:number` output field
  with a CSV string label (e.g. `example["answer"] == pred.answer` with
  `:integer` output and the label `"4"`) **silently scores 0**, where
  upstream's pandas-inferred integer would compare equal. Use `types:`
  (above) to parse the label into the same type as the output field.
  """
  @spec from_csv(Path.t(), keyword()) :: [Example.t()]
  def from_csv(path, opts \\ []) do
    fields = Keyword.get(opts, :fields)
    input_keys = Keyword.get(opts, :input_keys, [])
    types = Keyword.get(opts, :types, %{})

    content =
      case File.read(path) do
        {:ok, binary} ->
          binary

        {:error, reason} ->
          raise ArgumentError,
                "Dspy.DataLoader.from_csv/2: cannot read #{inspect(path)}: #{reason}"
      end

    {header, rows, line_of} = parse_csv!(content, path)
    validate_header!(header)
    columns = resolve_fields!(header, fields, path)
    validate_types!(types, header, path)

    rows
    |> Enum.reject(fn row -> row == [""] end)
    |> Enum.with_index(1)
    |> Enum.map(fn {cells, i} ->
      line = line_of[i]

      if length(cells) > length(header) do
        raise ArgumentError,
              "Dspy.DataLoader.from_csv/2: #{path} line #{line}: #{length(cells)} fields, " <>
                "but the header has #{length(header)} (E3: a long row is not silently corrupted)"
      end

      filled = pad_row(cells, length(header))
      # Normalize empty strings to nil (E2: empty cells read as nil).
      filled = Enum.map(filled, fn cell -> if cell == "", do: nil, else: cell end)
      # Ruling 3: take each field's cell by its header index, not zip with the
      # full row (which pairs selected names with cells in header order).
      header_index = Map.new(Enum.with_index(header, 0))

      base =
        Enum.map(columns, fn column ->
          idx = Map.fetch!(header_index, column)
          {column, Enum.at(filled, idx)}
        end)

      typed =
        Enum.map(base, fn {column, value} ->
          case Map.fetch(types, column) do
            {:ok, :integer} ->
              case NumberParser.parse_integer(value || "") do
                {:ok, int} ->
                  {column, int}

                _ ->
                  raise ArgumentError,
                        "Dspy.DataLoader.from_csv/2: #{path} line #{line}, column #{inspect(column)}: " <>
                          "not a strict integer (#{inspect(value)})"
              end

            {:ok, :number} ->
              case NumberParser.parse_number(value || "") do
                {:ok, float} ->
                  {column, float}

                _ ->
                  raise ArgumentError,
                        "Dspy.DataLoader.from_csv/2: #{path} line #{line}, column #{inspect(column)}: " <>
                          "not a strict number (#{inspect(value)})"
              end

            :error ->
              {column, value}
          end
        end)

      build_example(Map.new(typed), input_keys)
    end)
  end

  # ---------------------------------------------------------------------------
  # from_json
  # ---------------------------------------------------------------------------

  @doc """
  Load a local JSON file into `Example`s with string keys.

  The file is either a **JSON array of objects** (what M1-a's
  `save_as_json` writes) or **JSON Lines** (one object per line; blank
  lines are skipped). The first non-whitespace byte decides (`[` =
  array). JSON types and nesting are kept (string keys all the way down);
  keys missing from some records are filled with `nil` (union of keys);
  a record that is not an object raises `ArgumentError` naming the
  record index (1-based) / line.

  Options: `:fields` (subset, same rules as `from_csv/2`) and
  `:input_keys`.
  """
  @spec from_json(Path.t(), keyword()) :: [Example.t()]
  def from_json(path, opts \\ []) do
    fields = Keyword.get(opts, :fields)
    input_keys = Keyword.get(opts, :input_keys, [])

    content =
      case File.read(path) do
        {:ok, binary} ->
          binary

        {:error, reason} ->
          raise ArgumentError,
                "Dspy.DataLoader.from_json/2: cannot read #{inspect(path)}: #{reason}"
      end

    records = decode_json_records!(content, path)
    columns = union_keys(records)
    resolved = resolve_fields!(columns, fields, path)

    Enum.map(records, fn record ->
      base = Enum.map(resolved, fn column -> {column, Map.get(record, column, nil)} end)
      build_example(Map.new(base), input_keys)
    end)
  end

  # ---------------------------------------------------------------------------
  # sample
  # ---------------------------------------------------------------------------

  @doc """
  Randomly sample `n` examples (CPython's `random.sample`, pinned by the
  phase-1 golden fixture). `seed: nil` takes a fresh `:crypto` seed (E7);
  a given integer seed is reproducible on every Elixir/OTP version and
  leaves the caller's `:rand` state untouched.
  """
  @spec sample([Example.t()], integer(), keyword()) :: [Example.t()]
  def sample(examples, n, opts \\ []) when is_list(examples) and is_integer(n) and n >= 0 do
    seed = resolve_seed!(Keyword.get(opts, :seed))
    {state, _} = Dspy.Random.seed(seed)
    {_state, picked} = Dspy.Random.sample(state, examples, n)
    picked
  end

  # ---------------------------------------------------------------------------
  # train_test_split
  # ---------------------------------------------------------------------------

  @doc """
  Split examples into train/test (upstream `train_test_split`
  `dataloader.py:152-198`, E7 for the seed handling).

  - `train_size`: a float strictly between 0 and 1 → `trunc(len * frac)`
    train rows; an integer → that many train rows. `1.0` and other
    out-of-range values raise `ArgumentError`.
  - `test_size` (optional): same rules; `train_size + test_size` may not
    exceed the data size.
  - `seed`: an integer (reproducible, caller's `:rand` untouched) or
    `nil` (fresh `:crypto` seed, E7).

  Returns `%{train: [...], test: [...]}`.
  """
  @spec train_test_split([Example.t()], keyword()) :: %{train: [Example.t()], test: [Example.t()]}
  def train_test_split(examples, opts \\ []) when is_list(examples) do
    train_size = Keyword.get(opts, :train_size, 0.75)
    test_size = Keyword.get(opts, :test_size)
    seed = resolve_seed!(Keyword.get(opts, :seed))
    n = length(examples)

    train_end = resolve_count!(train_size, n, :train_size)

    test_end =
      case test_size do
        nil ->
          n - train_end

        value ->
          count = resolve_count!(value, n, :test_size)
          check_overflow!(train_end, count, n)
          count
      end

    {state, _} = Dspy.Random.seed(seed)
    {_state, shuffled} = Dspy.Random.shuffle(state, examples)
    train = Enum.take(shuffled, train_end)
    rest = Enum.drop(shuffled, train_end)
    test = Enum.take(rest, test_end)

    %{train: train, test: test}
  end

  # ---------------------------------------------------------------------------
  # The shared row→Example builder (MB1/MB2/MB3 target: one helper, used by
  # BOTH from_csv and from_json)
  # ---------------------------------------------------------------------------

  defp build_example(row_map, input_keys) when is_map(row_map) do
    example = Example.new(row_map)
    if input_keys == [], do: example, else: Example.with_inputs(example, input_keys)
  end

  # ---------------------------------------------------------------------------
  # CSV parsing internals
  # ---------------------------------------------------------------------------

  defp parse_csv!(content, path) do
    content = strip_bom(content)

    result =
      case NimbleCSV.RFC4180.parse_string(content, skip_headers: false) do
        {:ok, rows} ->
          rows

        {:error, reason} ->
          raise ArgumentError,
                "Dspy.DataLoader.from_csv/2: #{path}: invalid CSV: #{inspect(reason)}"

        rows when is_list(rows) ->
          rows
      end

    rows = if is_list(result), do: result, else: Enum.to_list(result)

    case rows do
      [] ->
        raise ArgumentError,
              "Dspy.DataLoader.from_csv/2: #{path}: empty file (a header is required)"

      [header | rest] ->
        if header == [] do
          raise ArgumentError, "Dspy.DataLoader.from_csv/2: #{path}: the header line is empty"
        end

        # The record index in the stream is the CSV row number (header =
        # line 1); embedded newlines inside quotes do not create new
        # records, so the index is what E3's error must name.
        # line_of maps 1-based record index -> line number (2-based).
        line_of = Map.new(1..length(rest), fn i -> {i, i + 1} end)
        {header, rest, line_of}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(<<codepoint::utf8, rest::binary>>) when codepoint == 0xFEFF, do: rest
  defp strip_bom(content), do: content

  defp validate_header!(header) do
    seen = MapSet.new()

    Enum.reduce(header, seen, fn name, acc ->
      if MapSet.member?(acc, name) do
        raise ArgumentError,
              "Dspy.DataLoader.from_csv/2: duplicate column name #{inspect(name)} in the header (E4)"
      end

      MapSet.put(acc, name)
    end)
  end

  defp resolve_fields!(header, nil, _path), do: header

  defp resolve_fields!(header, fields, path) when is_list(fields) do
    known = MapSet.new(header)

    Enum.map(fields, fn field ->
      field = to_string(field)

      if MapSet.member?(known, field) do
        field
      else
        raise ArgumentError,
              "Dspy.DataLoader.from_csv/2: #{path}: fields: names #{inspect(fields)} — " <>
                "unknown field #{inspect(field)} (header: #{inspect(header)})"
      end
    end)
  end

  defp validate_types!(types, header, path) do
    known = MapSet.new(header)

    Enum.each(Map.keys(types), fn column ->
      unless is_binary(column) and MapSet.member?(known, column) do
        raise ArgumentError,
              "Dspy.DataLoader.from_csv/2: #{path}: types: names unknown column #{inspect(column)}"
      end

      :ok
    end)
    |> then(fn _ -> :ok end)
  end

  defp pad_row(cells, total) do
    missing = total - length(cells)
    if missing > 0, do: cells ++ List.duplicate(nil, missing), else: cells
  end

  # ---------------------------------------------------------------------------
  # JSON parsing internals
  # ---------------------------------------------------------------------------

  defp decode_json_records!(content, path) do
    trimmed = String.trim_leading(content)

    cond do
      String.starts_with?(trimmed, "[") ->
        case Jason.decode(content) do
          {:ok, list} when is_list(list) ->
            list

          {:ok, other} ->
            raise ArgumentError,
                  "Dspy.DataLoader.from_json/2: #{path}: top-level JSON must be an array of objects, got #{inspect(other)}"

          {:error, reason} ->
            raise ArgumentError,
                  "Dspy.DataLoader.from_json/2: #{path}: invalid JSON: #{inspect(reason)}"
        end

      true ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reject(fn {line, _i} -> String.trim(line) == "" end)
        |> Enum.map(fn {line, i} ->
          case Jason.decode(line) do
            {:ok, map} when is_map(map) ->
              map

            {:ok, other} ->
              raise ArgumentError,
                    "Dspy.DataLoader.from_json/2: #{path} line #{i}: record is not a JSON object (got #{inspect(other)})"

            {:error, reason} ->
              raise ArgumentError,
                    "Dspy.DataLoader.from_json/2: #{path} line #{i}: invalid JSON: #{inspect(reason)}"
          end
        end)
    end
  end

  # Union of keys, first-seen order preserved (deterministic: record order).
  defp union_keys(records) do
    records
    |> Enum.reduce([], fn record, acc ->
      if is_map(record) do
        Enum.reduce(Map.keys(record), acc, fn key, a ->
          if key in a, do: a, else: [key | a]
        end)
      else
        raise ArgumentError,
              "Dspy.DataLoader.from_json/2: a record is not a JSON object (got #{inspect(record)})"
      end
    end)
    |> Enum.reverse()
  end

  # ---------------------------------------------------------------------------
  # Seeds
  # ---------------------------------------------------------------------------

  defp resolve_seed!(nil) do
    <<bytes::size(32)-integer-native>> = :crypto.strong_rand_bytes(4)
    bytes
  end

  defp resolve_seed!(seed) when is_integer(seed), do: seed

  defp resolve_seed!(other) do
    raise ArgumentError,
          "Dspy.DataLoader: seed must be an integer or nil, got: #{inspect(other)}"
  end

  # ---------------------------------------------------------------------------
  # train_test_split size resolution (row 21 / MT1)
  # ---------------------------------------------------------------------------

  defp resolve_count!(size, n, label) when is_float(size) do
    unless size > 0 and size < 1 do
      raise ArgumentError,
            "Dspy.DataLoader.train_test_split/2: invalid #{inspect(label)}: " <>
              "a float must be strictly between 0 and 1, got: #{inspect(size)}"
    end

    trunc(n * size)
  end

  defp resolve_count!(size, n, label) when is_integer(size) do
    unless size >= 0 and size <= n do
      raise ArgumentError,
            "Dspy.DataLoader.train_test_split/2: invalid #{inspect(label)}: " <>
              "an integer must be within 0..#{n}, got: #{inspect(size)}"
    end

    size
  end

  defp resolve_count!(other, _n, label) do
    raise ArgumentError,
          "Dspy.DataLoader.train_test_split/2: invalid #{inspect(label)}: " <>
            "please provide a float between 0 and 1 or an int, got: #{inspect(other)}"
  end

  defp check_overflow!(train_end, test_end, n) do
    if train_end + test_end > n do
      raise ArgumentError,
            "Dspy.DataLoader.train_test_split/2: train_size (#{train_end}) + test_size (#{test_end}) " <>
              "cannot exceed the total number of samples (#{n})"
    end

    :ok
  end
end
