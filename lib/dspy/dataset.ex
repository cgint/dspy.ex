defmodule Dspy.Dataset do
  @moduledoc """
  A dataset with lazily split `train` / `dev` / `test` sets (M1-e, contract
  A3; upstream `dspy/datasets/dataset.py:13-139`).

  A `Dspy.Dataset` holds RAW rows (string-keyed maps or `%Dspy.Example{}`)
  per split plus the split parameters. `train/1`, `dev/1` and `test/1`
  shuffle each split with its seed (`train_seed`, and `eval_seed` for BOTH
  dev and test — upstream `:25-27`), keep the first `size` rows
  (`nil` = all, `0` = none, larger = all) and build one `Example` per row,
  applying `input_keys` when given.

  ## Deviations from upstream (declared in `docs/COMPATIBILITY.md`)

  - **E5:** no random `dspy_uuid` per example; the split name goes into
    `Example.metadata["dspy_split"]` instead of an attrs key.
  - **E6:** a negative size raises `ArgumentError` (upstream's Python
    slicing would drop elements from the end).
  - **Q1 (ruling 2026-10-02):** user rows that hold BOTH `:k` and `"k"`
    pass through `Example.new/1` unchanged; reads follow the `Dspy.Attrs`
    atom-wins rule. Loaders never produce dual-form rows (R1).

  ## Seeded randomness

  Ordering comes from `Dspy.Random` (bit-exact CPython MT19937, M1-e
  phase 1) — never `:rand`, so the caller's random state is untouched and
  the same seed gives the same order on every Elixir/OTP version and the
  same split as Python DSPy.

  Rows that are maps become `Example.new(row)`; an `%Example{}` is kept
  as-is. The result is a pure function of the dataset: repeated calls
  return equal lists (E5).
  """

  @type t :: %__MODULE__{
          train: [map() | Dspy.Example.t()] | nil,
          dev: [map() | Dspy.Example.t()] | nil,
          test: [map() | Dspy.Example.t()] | nil,
          train_seed: integer(),
          train_size: non_neg_integer() | nil,
          eval_seed: integer(),
          dev_size: non_neg_integer() | nil,
          test_size: non_neg_integer() | nil,
          input_keys: [atom() | String.t()],
          shuffle: boolean()
        }

  defstruct [
    :train,
    :dev,
    :test,
    train_seed: 0,
    train_size: nil,
    eval_seed: 0,
    dev_size: nil,
    test_size: nil,
    input_keys: [],
    shuffle: true
  ]

  @doc """
  Create a dataset.

  Options:

    - `:train`, `:dev`, `:test` — raw rows per split: a list of maps or
      `Example`s, or `nil` for a split that was never given (accessing an
      `nil` split raises `ArgumentError`; an empty list is a valid empty
      split).
    - `:train_seed` (default `0`), `:eval_seed` (default `0`, used by BOTH
      dev and test), `:train_size`, `:dev_size`, `:test_size`
      (default `nil` = all rows), `:input_keys` (default `[]`),
      `:shuffle` (default `true`, upstream `do_shuffle`).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      train: Keyword.get(opts, :train),
      dev: Keyword.get(opts, :dev),
      test: Keyword.get(opts, :test),
      train_seed: Keyword.get(opts, :train_seed, 0),
      train_size: Keyword.get(opts, :train_size),
      eval_seed: Keyword.get(opts, :eval_seed, 0),
      dev_size: Keyword.get(opts, :dev_size),
      test_size: Keyword.get(opts, :test_size),
      input_keys: Keyword.get(opts, :input_keys, []),
      shuffle: Keyword.get(opts, :shuffle, true)
    }
  end

  @doc "The `train` split: shuffled with `train_seed`, first `train_size` rows."
  @spec train(t()) :: [Dspy.Example.t()]
  def train(%__MODULE__{} = ds) do
    split_examples(ds, "train", ds.train, ds.train_size, ds.train_seed)
  end

  @doc "The `dev` split: shuffled with `eval_seed`, first `dev_size` rows."
  @spec dev(t()) :: [Dspy.Example.t()]
  def dev(%__MODULE__{} = ds) do
    split_examples(ds, "dev", ds.dev, ds.dev_size, ds.eval_seed)
  end

  @doc "The `test` split: shuffled with `eval_seed` (same seed as dev), first `test_size` rows."
  @spec test(t()) :: [Dspy.Example.t()]
  def test(%__MODULE__{} = ds) do
    split_examples(ds, "test", ds.test, ds.test_size, ds.eval_seed)
  end

  @doc """
  Change seeds and/or sizes, keeping every value not present in `opts`.

  A key that is present with an explicit `nil` KEEPS the old value (upstream
  cannot tell `None` from omitted — parity, pinned by row 5b). `0` is a
  value. `eval_seed` sets BOTH the dev and test seeds. Upstream's
  `reset_seeds` also deletes the cached splits; our splits are computed on
  demand, so there is nothing to invalidate.
  """
  @spec reset_seeds(t(), keyword()) :: t()
  def reset_seeds(%__MODULE__{} = ds, opts \\ []) do
    ds =
      if Keyword.has_key?(opts, :train_seed) and not is_nil(Keyword.get(opts, :train_seed)),
        do: %{ds | train_seed: Keyword.fetch!(opts, :train_seed)},
        else: ds

    ds =
      if Keyword.has_key?(opts, :train_size) and not is_nil(Keyword.get(opts, :train_size)),
        do: %{ds | train_size: Keyword.fetch!(opts, :train_size)},
        else: ds

    ds =
      if Keyword.has_key?(opts, :eval_seed) and not is_nil(Keyword.get(opts, :eval_seed)),
        do: %{ds | eval_seed: Keyword.fetch!(opts, :eval_seed)},
        else: ds

    ds =
      if Keyword.has_key?(opts, :dev_size) and not is_nil(Keyword.get(opts, :dev_size)),
        do: %{ds | dev_size: Keyword.fetch!(opts, :dev_size)},
        else: ds

    ds =
      if Keyword.has_key?(opts, :test_size) and not is_nil(Keyword.get(opts, :test_size)),
        do: %{ds | test_size: Keyword.fetch!(opts, :test_size)},
        else: ds

    ds
  end

  @doc """
  Prepare train/eval sets for cross-validation (upstream `prepare_by_seed`
  `:105-139`).

  One eval set from `dev` (shuffled with `eval_seed`), cut into one slice
  per train seed (`dev_size / length(train_seeds)` rows each, when
  `divide_eval_per_seed`), and one train set per train seed. A length
  mismatch raises `ArgumentError` (upstream `assert`).

  Options: `:train_seeds` (default `[1, 2, 3, 4, 5]`), `:train_size`
  (default `16`), `:dev_size` (default `1000`), `:divide_eval_per_seed`
  (default `true`), `:eval_seed` (default `2023`).
  """
  @spec prepare_by_seed(t(), keyword()) :: %{
          train_sets: [[Dspy.Example.t()]],
          eval_sets: [[Dspy.Example.t()]]
        }
  def prepare_by_seed(%__MODULE__{} = ds, opts \\ []) do
    train_seeds = Keyword.get(opts, :train_seeds, [1, 2, 3, 4, 5])
    train_size = Keyword.get(opts, :train_size, 16)
    dev_size = Keyword.get(opts, :dev_size, 1000)
    divide_eval_per_seed = Keyword.get(opts, :divide_eval_per_seed, true)
    eval_seed = Keyword.get(opts, :eval_seed, 2023)

    if train_seeds == [] do
      raise ArgumentError, "prepare_by_seed/2: train_seeds must not be empty"
    end

    ds = %{ds | eval_seed: eval_seed, dev_size: dev_size}

    eval_set = dev(ds)

    examples_per_seed =
      if divide_eval_per_seed, do: div(dev_size, length(train_seeds)), else: dev_size

    {eval_sets, train_sets, _offset} =
      Enum.reduce(train_seeds, {[], [], 0}, fn seed, {acc_eval, acc_train, offset} ->
        slice =
          if length(eval_set) >= offset + examples_per_seed do
            Enum.slice(eval_set, offset, examples_per_seed)
          else
            raise ArgumentError,
                  "prepare_by_seed/2: dev data holds #{length(eval_set)} examples, " <>
                    "but the eval slice at offset #{offset} needs #{examples_per_seed} more " <>
                    "(dev_size: #{dev_size}, #{length(train_seeds)} train seeds)"
          end

        train_ds = %{ds | train_seed: seed, train_size: train_size}

        train_set =
          if length(train_rows(ds)) >= train_size do
            train(train_ds)
          else
            raise ArgumentError,
                  "prepare_by_seed/2: train data holds #{length(train_rows(ds))} examples, " <>
                    "but train_size is #{train_size}"
          end

        next_offset = if divide_eval_per_seed, do: offset + examples_per_seed, else: offset
        {[slice | acc_eval], [train_set | acc_train], next_offset}
      end)

    # the reduce prepends; restore the upstream (train_seed order) sequence
    %{eval_sets: Enum.reverse(eval_sets), train_sets: Enum.reverse(train_sets)}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp train_rows(%__MODULE__{} = ds), do: ds.train || []

  defp split_examples(_ds, name, nil, _size, _seed) do
    raise ArgumentError,
          "Dspy.Dataset: the #{name} split was never given (nil); " <>
            "pass a list of rows (possibly []) to Dspy.Dataset.new/1"
  end

  defp split_examples(ds, name, rows, size, seed) do
    validate_size!(size, name)
    # Row 10: shuffle: false keeps row order (no seed, no shuffle).
    ordered =
      if ds.shuffle do
        {state, _} = Dspy.Random.seed(seed)
        {_state, shuffled} = Dspy.Random.shuffle(state, rows)
        shuffled
      else
        rows
      end

    limited = take_limited(ordered, size)
    Enum.map(limited, fn row -> build_example(row, name, ds) end)
  end

  defp validate_size!(size, name) do
    unless (is_integer(size) and size >= 0) or is_nil(size) do
      raise ArgumentError,
            "Dspy.Dataset: #{name}_size must be nil or a non-negative integer, got: #{inspect(size)}"
    end

    :ok
  end

  defp take_limited(rows, nil), do: rows
  defp take_limited(rows, n) when is_integer(n), do: Enum.take(rows, n)

  defp build_example(%Dspy.Example{} = example, name, ds) do
    example = %{example | metadata: put_split_name(example.metadata || %{}, name)}
    apply_input_keys(example, ds.input_keys)
  end

  defp build_example(row, name, ds) when is_map(row) do
    example = Dspy.Example.new(row)
    build_example(%{example | metadata: put_split_name(example.metadata || %{}, name)}, name, ds)
  end

  defp put_split_name(metadata, name), do: Map.put(metadata, "dspy_split", name)

  defp apply_input_keys(example, []), do: example

  defp apply_input_keys(example, input_keys) do
    Dspy.Example.with_inputs(example, input_keys)
  end
end
