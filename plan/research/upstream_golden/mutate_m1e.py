#!/usr/bin/env python3
"""Mutation harness — M1-e: Dspy.Random (phase 1) + Dataset/DataLoader (phase 2).

Built on `plan/research/harness/mutlib.py` (H20-C2). The normative mutation
table is contract section (c2) of
`openspec/changes/m1e-dataset-dataloader/proposal.md`. This harness
implements exactly the phase-2 slice of that table:

  phase 1 (random.ex)      : MG1, MG2, MG3, MG4, MG5, MG6, MG7
  phase 2 (dataset.ex)     : MD1, MD2, MD3, MD4, MD5, MD6, MD7, MD8, MD8b,
                             MD9, MC1 (caller revert)
  phase 2 (data_loader.ex) : ML0, ML1, ML2, ML3, ML4, ML5, ML6, ML6b, ML7,
                             ML8, ML9, ML10, MJ0, MJ1, MJ2, MJ2b, MJ3, MJ4,
                             MT1, MT2, MT3, MT4, MB1, MB2, MB3, MC2, MC3,
                             MC4 (caller reverts + seed fallback)
  phase 2 (shipped H15)    : MD7b (example.ex, expect row 11)

The `CONTRACT_IDS` set below is a LITERAL copy of the phase-2 scope. `main`
FAILS (exit 1) if the set of defined mutation IDs differs from it. This is
the check that would have caught the 2026-10-06 first attempt, which
repurposed the MD1–MD4 / MC1 / MB2 IDs for other edits and exempted 33
tests the contract assigns mutations to.

The consumer-row mutations (MC5, MX1, MX2, MX3, MX3b, MP1, MV1) target test
rows 20a/b, 22, 24–29, 34 that do not exist in this tree yet (phase 3, per
handoff-phase2.md rulings 4 and Greta's scope ruling). They are NOT in
CONTRACT_IDS and must NOT be defined in this harness.

Every `also` list starts EMPTY and is filled only from observed failures
(H15 lesson 2026-10-02); the review checks `also == failed − expect`
mechanically.

`exempt` = the contract's exempt rows 5, 31–33, 35 (listed as a record;
rows 31–33 and 35 have no test in this tree — they are static checks),
plus the phase-1 random_test.exs edge/raise tests (no contract row).
Nothing else is exempt.
"""

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "plan" / "research" / "harness"))
import mutlib  # noqa: E402

TARGET_LIB = REPO / "lib" / "dspy" / "random.ex"
TARGET_LOADER = REPO / "lib" / "dspy" / "data_loader.ex"
TARGET_DATASET = REPO / "lib" / "dspy" / "dataset.ex"
TARGET_EXAMPLE = REPO / "lib" / "dspy" / "example.ex"

TESTS = REPO / "test" / "dspy" / "random_test.exs"
TESTS_PHASE2 = REPO / "test" / "dspy" / "dataset_dataloader_test.exs"

# ---------------------------------------------------------------------------
# Phase-1 test names
# ---------------------------------------------------------------------------

T_FIRST5 = "getrandbits k=32 matches CPython first5 for all fixture seeds"
T_ABS = "abs_seed_parity negative seeds match positive"
T_SEED = "seed negative seed uses abs(seed)"
T_SHUFFLE = "shuffle matches CPython for n=0,1,2,10,100,1000"
T_SAMPLE = "sample matches CPython for all fixture vectors"
T_BOUNDARY_85_K6 = "sample fixture n=85 k=6 seed 5 pins the set branch (divergence)"
T_BOUNDARY_21_K5 = "sample fixture n=21 k=5 seed 2 pins the pool branch at the boundary"
T_BOUNDARY_22_K5 = "sample fixture n=22 k=5 seed 2 pins the set branch just past the boundary"
T_BOUNDARY_86_K6 = "sample fixture n=86 k=6 seed 5 pins the set branch one past the k=6 boundary"
T_RANDBELOW = "randbelow matches CPython randrange (step 1)"

# ---------------------------------------------------------------------------
# Phase-2 test names (exact ExUnit names)
# ---------------------------------------------------------------------------

P2_ROW3B = "row 3b: DataLoader.sample(examples, 3, seed: 0) returns the rows CPython's sample picks"
P2_ROW3B2 = "row 3b: DataLoader.sample seed 1 and seed 2 match the fixture"
P2_ROW4A = "row 4a: Dataset.train/1 leaves the caller's :rand state unchanged (seeded)"
P2_ROW4A2 = "row 4a: Dataset.train/1 leaves the caller's :rand state unchanged (caller never seeded)"
P2_ROW4B = "row 4b: DataLoader.sample/3 leaves the caller's :rand state unchanged (seeded, unseeded, seed: nil)"
P2_ROW4C = "row 4c: train_test_split/2 leaves the caller's :rand state unchanged (seeded, unseeded, seed: nil)"
P2_ROW5B = "row 5b: reset_seeds(ds, train_size: nil) keeps the old size; an absent key keeps its value"
P2_ROW6 = "row 6: reset_seeds(train_seed: 1) keeps train_size, dev/test seeds and sizes"
P2_ROW7 = "row 7: dev and test with identical rows and eval_seed: 7 return the same order"
P2_ROW8 = "row 8: train/1 seed 0, size 7 over rows 0..9 returns the CPython permutation"
P2_ROW9 = "row 9: size nil returns all; 0 returns []; larger returns all; negative raises"
P2_ROW10 = "row 10: shuffle: false keeps row order"
P2_ROW11 = "row 11: input_keys as strings and as atoms both give inputs with those keys, on loaded rows"
P2_ROW12 = "row 12: train/1 twice returns equal lists"
P2_ROW12B = 'row 12b: the split name is in metadata["dspy_split"] and in no attrs key'
P2_ROW13 = "row 13: prepare_by_seed gives 5 disjoint eval slices and 5 train sets"
P2_ROW13RAISE = "row 13: too little dev data raises ArgumentError"
P2_ROW14A = "row 14a: a leading UTF-8 BOM is stripped"
P2_ROW14B = "row 14b: a blank line is skipped"
P2_ROW14C = "row 14c: CRLF line endings are accepted"
P2_ROW14D = "row 14d: an embedded newline and a double-quote escape survive"
P2_ROW14E = "row 14e: an empty cell and a quoted empty cell both read as nil"
P2_ROW14F = "row 14f: a short row's missing cells are nil"
P2_ROW14G = "row 14g: surrounding whitespace is kept"
P2_ROW14H = "row 14h: fields: subset is returned in the given order"
P2_ROW14I = "row 14i: an unknown field in fields: raises ArgumentError naming it"
P2_ROW14J = "row 14j: input_keys on from_csv"
P2_ROW15 = "row 15: a long row raises ArgumentError naming the line"
P2_ROW15B = "row 15: a long row in the last position raises too"
P2_ROW16 = "row 16: a duplicate header raises ArgumentError naming the column"
P2_ROW17 = "row 17: CSV values stay strings even when they look like numbers or booleans"
P2_ROW18 = "row 18: a never-seen header name still makes String.to_existing_atom/1 raise"
P2_ROW19A = "row 19a: a JSON array of objects loads"
P2_ROW19B = "row 19b: JSON Lines with a blank line loads"
P2_ROW19C = "row 19c: keys missing in some records are filled with nil (union of keys)"
P2_ROW19D = "row 19d: nested objects and lists are kept with string keys"
P2_ROW19E = "row 19e: JSON null reads as nil"
P2_ROW19F = "row 19f: a record that is not an object raises ArgumentError naming the record"
P2_ROW19G = "row 19g: input_keys on from_json"
P2_ROW21 = "row 21: train_test_split sizes — 0.75 of 10 -> 7/3; int 3 -> 3/7; overflow raises; 1.0 raises"
P2_ROW21B = "row 21b: train_test_split(rows 0..9, 0.7, seed: 0) matches upstream"
P2_ROW30 = "row 30: from_csv types: parses integer and float columns via the H12 NumberParser"
P2_ROW30RAISE = "row 30: a bad typed cell raises ArgumentError naming line and column"
P2_ROW30UNTYPE = "row 30: untyped columns stay strings even when types: is given for others"
P2_ROW30C = "row 30c: the from_csv docstring names the silent-0 pitfall and types:"

# ---------------------------------------------------------------------------
# MJ2b helper: full-function replacement
# ---------------------------------------------------------------------------

MJ2B_OLD = (
    "  defp decode_json_records!(content, path) do\n"
    "    trimmed = String.trim_leading(content)\n"
    "\n"
    "    cond do\n"
    '      String.starts_with?(trimmed, "[") ->\n'
    "        case Jason.decode(content) do\n"
    "          {:ok, list} when is_list(list) ->\n"
    "            list\n"
    "\n"
    "          {:ok, other} ->\n"
    "            raise ArgumentError,\n"
    '                  "Dspy.DataLoader.from_json/2: #{path}: top-level JSON must be an array of objects, got #{inspect(other)}"\n'
    "\n"
    "          {:error, reason} ->\n"
    "            raise ArgumentError,\n"
    '                  "Dspy.DataLoader.from_json/2: #{path}: invalid JSON: #{inspect(reason)}"\n'
    "        end\n"
    "\n"
    "      true ->\n"
    "        content\n"
    '        |> String.split("\\n")\n'
    "        |> Enum.with_index(1)\n"
    '        |> Enum.reject(fn {line, _i} -> String.trim(line) == "" end)\n'
    "        |> Enum.map(fn {line, i} ->\n"
    "          case Jason.decode(line) do\n"
    "            {:ok, map} when is_map(map) ->\n"
    "              map\n"
    "\n"
    "            {:ok, other} ->\n"
    "              raise ArgumentError,\n"
    '                    "Dspy.DataLoader.from_json/2: #{path} line #{i}: record is not a JSON object (got #{inspect(other)})"\n'
    "\n"
    "            {:error, reason} ->\n"
    "              raise ArgumentError,\n"
    '                    "Dspy.DataLoader.from_json/2: #{path} line #{i}: invalid JSON: #{inspect(reason)}"\n'
    "          end\n"
    "        end)\n"
    "    end\n"
    "  end"
)

MJ2B_NEW = (
    "  defp decode_json_records!(content, path) do\n"
    "    # MUTATION MJ2b: always JSONL (array input fails)\n"
    "    content\n"
    '    |> String.split("\\n")\n'
    "    |> Enum.with_index(1)\n"
    '    |> Enum.reject(fn {line, _i} -> String.trim(line) == "" end)\n'
    "    |> Enum.map(fn {line, i} ->\n"
    "      case Jason.decode(line) do\n"
    "        {:ok, map} when is_map(map) ->\n"
    "          map\n"
    "\n"
    "        {:ok, other} ->\n"
    "          raise ArgumentError,\n"
    '              "Dspy.DataLoader.from_json/2: #{path} line #{i}: record is not a JSON object (got #{inspect(other)})"\n'
    "\n"
    "        {:error, reason} ->\n"
    "          raise ArgumentError,\n"
    '              "Dspy.DataLoader.from_json/2: #{path} line #{i}: invalid JSON: #{inspect(reason)}"\n'
    "      end\n"
    "    end)\n"
    "  end"
)

# ---------------------------------------------------------------------------
# Phase-1 mutations
# ---------------------------------------------------------------------------

MUTATIONS_PHASE1 = [
    mutlib.Mutation(
        id="MG1",
        file=TARGET_LIB,
        old="key = seed |> abs() |> key_words() |> Enum.reverse()",
        new="key = seed |> abs() |> key_words() # MUTATION MG1",
        expect=[T_FIRST5],
        also=[],
        kind="assertion",
        why="init_by_array key words most-significant first (contract (c2) MG1)",
    ),
    mutlib.Mutation(
        id="MG2",
        file=TARGET_LIB,
        old="key = seed |> abs() |> key_words() |> Enum.reverse()",
        new="key = seed |> key_words() |> Enum.reverse()",
        expect=[T_FIRST5, T_ABS, T_SEED],
        also=[],
        kind="raise:ExUnit.TimeoutError",
        why="seed used without abs (contract (c2) MG2)",
    ),
    mutlib.Mutation(
        id="MG3",
        file=TARGET_LIB,
        old="def randbelow(state, n) when is_integer(n) and n > 0 do\n    do_randbelow(state, n, bit_length(n))\n  end",
        new="def randbelow(state, n) when is_integer(n) and n > 0 do\n    do_randbelow(state, n, bit_length(n - 1))\n  end",
        expect=[T_SHUFFLE, T_SAMPLE, "randrange step 1 matches CPython"],
        also=["sample k=n returns a permutation", T_RANDBELOW, P2_ROW13, P2_ROW21B, P2_ROW3B2, P2_ROW8],
        kind="assertion",
        why="shared break: randbelow uses bit_length(n - 1) (contract (c2) MG3)",
    ),
    mutlib.Mutation(
        id="MG3b",
        file=TARGET_LIB,
        old="def randbelow(state, n) when is_integer(n) and n > 0 do\n    do_randbelow(state, n, bit_length(n))\n  end",
        new="def randbelow(state, n) when is_integer(n) and n > 0 do\n    do_randbelow(state, n, bit_length(n - 1))\n  end",
        expect=["sample k=n returns a permutation"],
        also=[T_SHUFFLE, T_SAMPLE, "randrange step 1 matches CPython", T_RANDBELOW, P2_ROW13, P2_ROW21B, P2_ROW3B2, P2_ROW8],
        kind="raise:FunctionClauseError",
        why="shared break, raise path (contract MG3b)",
    ),
    mutlib.Mutation(
        id="MG4",
        file=TARGET_LIB,
        old="      do_shuffle(state, list, len - 1)\n    end\n  end\n\n  defp do_shuffle(state, list, 0), do: {state, list}\n\n  defp do_shuffle(state, list, i) do\n    {state, j} = randbelow(state, i + 1)\n    do_shuffle(state, swap(list, i, j), i - 1)\n  end",
        new="      do_shuffle_upward(state, list, 1)\n    end\n  end\n\n  defp do_shuffle_upward(state, list, i) when i >= length(list), do: {state, list}\n\n  defp do_shuffle_upward(state, list, i) do\n    {state, j} = randbelow(state, i + 1)\n    do_shuffle_upward(state, swap(list, i, j), i + 1)\n  end",
        expect=[T_SHUFFLE],
        also=[P2_ROW13, P2_ROW21B, P2_ROW8],
        kind="assertion",
        why="shuffle loop runs upward (contract (c2) MG4)",
    ),
    mutlib.Mutation(
        id="MG5",
        file=TARGET_LIB,
        old="    if n <= setsize(k) do\n      sample_pool(state, population, k, n)\n    else\n      sample_set(state, population, k, n)\n    end",
        new="    if n <= setsize(k)\n      do\n        sample_pool(state, population, k, n)\n      else\n        sample_set(state, population, k, n)\n    end\n    if true\n      do\n        sample_pool(state, population, k, n)\n      else\n        _ = sample_set(state, population, k, n)\n    end",
        expect=[T_SAMPLE, T_BOUNDARY_22_K5, T_BOUNDARY_86_K6],
        also=[],
        kind="assertion",
        why="sample always takes the pool branch (contract (c2) MG5)",
    ),
    mutlib.Mutation(
        id="MG6",
        file=TARGET_LIB,
        old="    if n <= setsize(k) do\n      sample_pool(state, population, k, n)\n    else\n      sample_set(state, population, k, n)\n    end",
        new="    if n <= setsize(k)\n      do\n        sample_pool(state, population, k, n)\n      else\n        sample_set(state, population, k, n)\n    end\n    if true\n      do\n        sample_set(state, population, k, n)\n      else\n        _ = sample_pool(state, population, k, n)\n    end",
        expect=[T_SAMPLE],
        also=[P2_ROW3B, P2_ROW3B2, T_BOUNDARY_21_K5, T_BOUNDARY_85_K6],
        kind="assertion",
        why="sample always takes the set branch (contract (c2) MG6)",
    ),
    mutlib.Mutation(
        id="MG7",
        file=TARGET_LIB,
        old="    if n <= setsize(k) do\n      sample_pool(state, population, k, n)\n    else\n      sample_set(state, population, k, n)\n    end",
        new="    if n < setsize(k) do\n      sample_pool(state, population, k, n)\n    else\n      sample_set(state, population, k, n)\n    end",
        expect=[T_BOUNDARY_21_K5, T_BOUNDARY_85_K6],
        also=[T_SAMPLE],
        kind="assertion",
        why="sample branch off-by-one: n < setsize (contract (c2) MG7, added 2026-10-06)",
    ),
]

# ---------------------------------------------------------------------------
# Phase-2 mutations — dataset.ex
# ---------------------------------------------------------------------------

MUTATIONS_DATASET = [
    mutlib.Mutation(
        id="MC1",
        file=TARGET_DATASET,
        old="    ordered =\n      if ds.shuffle do\n        {state, _} = Dspy.Random.seed(seed)\n        {_state, shuffled} = Dspy.Random.shuffle(state, rows)\n        shuffled\n      else\n        rows\n      end",
        new="    :rand.seed(:exsss, {seed, 1, 2})\n    ordered = Enum.shuffle(rows) # MUTATION MC1: :rand + Enum.shuffle",
        expect=[P2_ROW4A, P2_ROW4A2, P2_ROW8],
        also=[P2_ROW10, P2_ROW11, P2_ROW13, P2_ROW6, P2_ROW7],
        kind="assertion",
        why="caller revert: train/1 shuffles with :rand.seed + Enum.shuffle (contract (c2) MC1)",
    ),
    mutlib.Mutation(
        id="MD1",
        file=TARGET_DATASET,
        old='      if Keyword.has_key?(opts, :train_size) and not is_nil(Keyword.get(opts, :train_size)),\n        do: %{ds | train_size: Keyword.fetch!(opts, :train_size)},',
        new='      if true,\n        do: %{ds | train_size: Keyword.get(opts, :train_size, ds.train_size)},',
        expect=[P2_ROW5B],
        also=[],
        kind="assertion",
        why="reset_seeds uses Keyword.get(opts, k, old) (contract (c2) MD1)",
    ),
    mutlib.Mutation(
        id="MD2",
        file=TARGET_DATASET,
        old='      if Keyword.has_key?(opts, :dev_size) and not is_nil(Keyword.get(opts, :dev_size)),\n        do: %{ds | dev_size: Keyword.fetch!(opts, :dev_size)},\n        else: ds',
        new='      %{ds | dev_size: Keyword.get(opts, :dev_size)}  # MUTATION MD2',
        expect=[P2_ROW6],
        also=[],
        kind="assertion",
        why="reset_seeds resets omitted dev_size to nil (contract (c2) MD2)",
    ),
    mutlib.Mutation(
        id="MD2b",
        file=TARGET_DATASET,
        old='      if Keyword.has_key?(opts, :eval_seed) and not is_nil(Keyword.get(opts, :eval_seed)),\n        do: %{ds | eval_seed: Keyword.fetch!(opts, :eval_seed)},\n        else: ds',
        new='      %{ds | eval_seed: Keyword.get(opts, :eval_seed, 0)}  # MUTATION MD2b',
        expect=[P2_ROW6],
        also=[],
        kind="assertion",
        why="reset_seeds resets omitted eval_seed to 0 (contract (c2) MD2b)",
    ),
    mutlib.Mutation(
        id="MD3",
        file=TARGET_DATASET,
        old='    split_examples(ds, "test", ds.test, ds.test_size, ds.eval_seed)',
        new='    split_examples(ds, "test", ds.test, ds.test_size, 0)',
        expect=[P2_ROW7],
        also=[],
        kind="assertion",
        why="test split uses its own seed, defaulting to 0 (contract (c2) MD3)",
    ),
    mutlib.Mutation(
        id="MD4",
        file=TARGET_DATASET,
        old="    limited = take_limited(ordered, size)\n    Enum.map(limited, fn row -> build_example(row, name, ds) end)",
        new="    limited = take_limited(rows, size)\n    _ = ordered\n    Enum.map(limited, fn row -> build_example(row, name, ds) end)",
        expect=[P2_ROW8],
        also=[P2_ROW13, P2_ROW6, P2_ROW7],
        kind="assertion",
        why="take size before shuffling (contract (c2) MD4)",
    ),
    mutlib.Mutation(
        id="MD5",
        file=TARGET_DATASET,
        old="defp validate_size!(size, name) do\n    unless (is_integer(size) and size >= 0) or is_nil(size) do\n      raise ArgumentError,\n            \"Dspy.Dataset: #{name}_size must be nil or a non-negative integer, got: #{inspect(size)}\"\n    end\n\n    :ok\n  end",
        new="defp validate_size!(_size, _name), do: :ok # MUTATION MD5: negative size allowed",
        expect=[P2_ROW9],
        also=[],
        kind="assertion",
        why="validate_size! accepts negative sizes (contract (c2) MD5)",
    ),
    mutlib.Mutation(
        id="MD6",
        file=TARGET_DATASET,
        old="    ordered =\n      if ds.shuffle do",
        new="    ordered =\n      if true do",
        expect=[P2_ROW10],
        also=[],
        kind="assertion",
        why="shuffle: flag ignored (contract (c2) MD6)",
    ),
    mutlib.Mutation(
        id="MD7",
        file=TARGET_DATASET,
        old="  defp apply_input_keys(example, []), do: example\n\n  defp apply_input_keys(example, input_keys) do\n    Dspy.Example.with_inputs(example, input_keys)\n  end",
        new="  defp apply_input_keys(example, _input_keys), do: example",
        expect=[P2_ROW11],
        also=[],
        kind="assertion",
        why="input_keys not applied (contract (c2) MD7)",
    ),
    mutlib.Mutation(
        id="MD8",
        file=TARGET_DATASET,
        old="  defp build_example(%Dspy.Example{} = example, name, ds) do\n    example = %{example | metadata: put_split_name(example.metadata || %{}, name)}\n    apply_input_keys(example, ds.input_keys)\n  end",
        new='  defp build_example(%Dspy.Example{} = example, name, ds) do\n    attrs = Map.merge(example.attrs, %{"dspy_uuid" => :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)})\n    example = %{example | attrs: attrs, metadata: put_split_name(example.metadata || %{}, name)}\n    apply_input_keys(example, ds.input_keys)\n  end',
        expect=[P2_ROW12],
        also=[P2_ROW12B, P2_ROW7, P2_ROW6],
        kind="assertion",
        why='adds attrs["dspy_uuid"] from :crypto (contract (c2) MD8)',
    ),
    mutlib.Mutation(
        id="MD8b",
        file=TARGET_DATASET,
        old='defp put_split_name(metadata, name), do: Map.put(metadata, "dspy_split", name)',
        new='defp put_split_name(_metadata, _name) do\n    %{"dspy_split" => "train"} # MUTATION MD8b: metadata lost, split in attrs\nend',
        expect=[P2_ROW12B],
        also=[],
        kind="assertion",
        why='split name written into attrs "dspy_split" (contract (c2) MD8b)',
    ),
    mutlib.Mutation(
        id="MD9",
        file=TARGET_DATASET,
        old="next_offset = if divide_eval_per_seed, do: offset + examples_per_seed, else: offset",
        new="next_offset = 0",
        expect=[P2_ROW13],
        also=[],
        kind="assertion",
        why="eval slices not offset (contract (c2) MD9)",
    ),
]

# ---------------------------------------------------------------------------
# Phase-2 mutations — data_loader.ex
# ---------------------------------------------------------------------------

MUTATIONS_LOADER = [
    mutlib.Mutation(
        id="MD9b",
        file=TARGET_DATASET,
        old='          if length(eval_set) >= offset + examples_per_seed do',
        new='          if true do  # MUTATION MD9b',
        expect=[P2_ROW13RAISE],
        also=[],
        kind="assertion",
        why="too little dev data: no raise (contract (c2) MD9b)",
    ),
    mutlib.Mutation(
        id="ML0",
        file=TARGET_LOADER,
        old='    result =\n      case NimbleCSV.RFC4180.parse_string(content, skip_headers: false) do\n        {:ok, rows} ->\n          rows\n\n        {:error, reason} ->\n          raise ArgumentError,\n                "Dspy.DataLoader.from_csv/2: #{path}: invalid CSV: #{inspect(reason)}"\n\n        rows when is_list(rows) ->\n          rows\n      end\n\n    rows = if is_list(result), do: result, else: Enum.to_list(result)',
        new='      rows =\n        content\n        |> String.split("\\n", trim: true)\n        |> Enum.map(&String.split(&1, ","))',
        expect=[P2_ROW14C, P2_ROW14D],
        also=[P2_ROW14E],
        kind="assertion",
        why="CSV parsed with String.split instead of NimbleCSV (contract (c2) ML0)",
    ),
    mutlib.Mutation(
        id="ML1",
        file=TARGET_LOADER,
        old="    content = strip_bom(content)\n",
        new="    # MUTATION ML1: BOM not stripped\n    if false, do: strip_bom(content)\n    content = content\n",
        expect=[P2_ROW14A],
        also=[],
        kind="assertion",
        why="BOM not stripped (contract (c2) ML1)",
    ),
    mutlib.Mutation(
        id="ML2",
        file=TARGET_LOADER,
        old='    |> Enum.reject(fn row -> row == [""] end)\n',
        new="    # MUTATION ML2: blank lines no longer rejected\n",
        expect=[P2_ROW14B],
        also=[],
        kind="assertion",
        why="blank lines kept as rows (contract (c2) ML2)",
    ),
    mutlib.Mutation(
        id="ML3",
        file=TARGET_LOADER,
        old='      # Normalize empty strings to nil (E2: empty cells read as nil).\n      filled = Enum.map(filled, fn cell -> if cell == "", do: nil, else: cell end)\n',
        new='      filled = filled # MUTATION ML3: "" kept as ""\n',
        expect=[P2_ROW14E],
        also=[],
        kind="assertion",
        why='"" kept as "" (contract (c2) ML3)',
    ),
    mutlib.Mutation(
        id="ML4",
        file=TARGET_LOADER,
        old="      filled = pad_row(cells, length(header))\n",
        new="      if length(cells) < length(header) do\n        raise ArgumentError,\n              \"Dspy.DataLoader.from_csv/2: #{path} line #{line}: short row (MUTATION ML4)\"\n      end\n      _ = pad_row(cells, length(header))\n      filled = cells\n",
        expect=[P2_ROW14F],
        also=[],
        kind="raise:Elixir.ArgumentError",
        why="short rows raise instead of being padded (contract (c2) ML4)",
    ),
    mutlib.Mutation(
        id="ML5",
        file=TARGET_LOADER,
        old='      # Normalize empty strings to nil (E2: empty cells read as nil).\n      filled = Enum.map(filled, fn cell -> if cell == "", do: nil, else: cell end)\n',
        new='      filled =\n        Enum.map(filled, fn cell ->\n          if cell == "", do: nil, else: String.trim(cell)\n        end)\n',
        expect=[P2_ROW14G],
        also=[P2_ROW14F],
        kind="assertion",
        why="cells String.trimmed (contract (c2) ML5)",
    ),
    mutlib.Mutation(
        id="ML6",
        file=TARGET_LOADER,
        old='      # Ruling 3: take each field\'s cell by its header index, not zip with the\n      # full row (which pairs selected names with cells in header order).\n      header_index = Map.new(Enum.with_index(header, 0))\n\n      base =\n        Enum.map(columns, fn column ->\n          idx = Map.fetch!(header_index, column)\n          {column, Enum.at(filled, idx)}\n        end)',
        new='      base = Enum.zip(columns, filled) # MUTATION ML6: fields in file order',
        expect=[P2_ROW14H],
        also=[],
        kind="assertion",
        why="fields: subset returned in file order (contract (c2) ML6)",
    ),
    mutlib.Mutation(
        id="ML6b",
        file=TARGET_LOADER,
        old='        raise ArgumentError,\n              "Dspy.DataLoader.from_csv/2: #{path}: fields: names #{inspect(fields)} — " <>\n                "unknown field #{inspect(field)} (header: #{inspect(header)})"\n      end',
        new='        _ = path # MUTATION ML6b: unknown field ignored\n      end',
        expect=[P2_ROW14I],
        also=[],
        kind="assertion",
        why="unknown field in fields: ignored (contract (c2) ML6b)",
    ),
    mutlib.Mutation(
        id="ML7",
        file=TARGET_LOADER,
        old='      if length(cells) > length(header) do\n        raise ArgumentError,\n              "Dspy.DataLoader.from_csv/2: #{path} line #{line}: #{length(cells)} fields, " <>\n                "but the header has #{length(header)} (E3: a long row is not silently corrupted)"\n      end\n\n      filled = pad_row(cells, length(header))\n',
        new='      _ = line\n      filled = cells\n      _ = pad_row(cells, length(header)) # MUTATION ML7: long row: extra field dropped\n',
        expect=[P2_ROW15, P2_ROW15B],
        also=[],
        kind="assertion",
        why="long row: extra field dropped (contract (c2) ML7)",
    ),
    mutlib.Mutation(
        id="ML8",
        file=TARGET_LOADER,
        old='  defp validate_header!(header) do\n    seen = MapSet.new()\n\n    Enum.reduce(header, seen, fn name, acc ->\n      if MapSet.member?(acc, name) do\n        raise ArgumentError,\n              "Dspy.DataLoader.from_csv/2: duplicate column name #{inspect(name)} in the header (E4)"\n      end\n\n      MapSet.put(acc, name)\n    end)\n  end',
        new='  defp validate_header!(_header), do: :ok # MUTATION ML8: dup header: last wins\n',
        expect=[P2_ROW16],
        also=[],
        kind="assertion",
        why="duplicate header: last one wins (contract (c2) ML8)",
    ),
    mutlib.Mutation(
        id="ML9",
        file=TARGET_LOADER,
        old='      # Ruling 3: take each field\'s cell by its header index, not zip with the\n      # full row (which pairs selected names with cells in header order).\n      header_index = Map.new(Enum.with_index(header, 0))\n\n      base =\n        Enum.map(columns, fn column ->\n          idx = Map.fetch!(header_index, column)\n          {column, Enum.at(filled, idx)}\n        end)',
        new='      # MUTATION ML9: integer-looking cells -> String.to_integer\n      header_index = Map.new(Enum.with_index(header, 0))\n\n      base =\n        Enum.map(columns, fn column ->\n          idx = Map.fetch!(header_index, column)\n          cell = Enum.at(filled, idx)\n          int = String.to_integer(cell)\n          {column, int}\n        end)',
        expect=[P2_ROW17],
        also=[P2_ROW11, P2_ROW14A, P2_ROW14B, P2_ROW14C, P2_ROW14D, P2_ROW14E, P2_ROW14F, P2_ROW14G, P2_ROW14H, P2_ROW14J, P2_ROW15B, P2_ROW18, P2_ROW30, P2_ROW30RAISE, P2_ROW30UNTYPE],
        kind="raise:Elixir.ArgumentError",
        why="integer-looking cells -> String.to_integer (contract (c2) ML9)",
    ),
    mutlib.Mutation(
        id="ML10",
        file=TARGET_LOADER,
        old='      # Ruling 3: take each field\'s cell by its header index, not zip with the\n      # full row (which pairs selected names with cells in header order).\n      header_index = Map.new(Enum.with_index(header, 0))\n\n      base =\n        Enum.map(columns, fn column ->\n          idx = Map.fetch!(header_index, column)\n          {column, Enum.at(filled, idx)}\n        end)',
        new='      # MUTATION ML10: keys via String.to_atom\n      header_index = Map.new(Enum.with_index(header, 0))\n\n      base =\n        Enum.map(columns, fn column ->\n          idx = Map.fetch!(header_index, column)\n          {String.to_atom(column), Enum.at(filled, idx)}\n        end)',
        expect=[P2_ROW18],
        also=[P2_ROW11, P2_ROW14A, P2_ROW14B, P2_ROW14C, P2_ROW14D, P2_ROW14E, P2_ROW14F, P2_ROW14G, P2_ROW14H, P2_ROW14J, P2_ROW17, P2_ROW30, P2_ROW30RAISE, P2_ROW30UNTYPE],
        kind="assertion",
        why="keys via String.to_atom (contract (c2) ML10)",
    ),
    mutlib.Mutation(
        id="MB1",
        file=TARGET_LOADER,
        old="  defp build_example(row_map, input_keys) when is_map(row_map) do\n    example = Example.new(row_map)\n    if input_keys == [], do: example, else: Example.with_inputs(example, input_keys)\n  end",
        new="  defp build_example(row_map, _input_keys) when is_map(row_map) do\n    Example.new(row_map) # MUTATION MB1: no input_keys\n  end",
        expect=[P2_ROW14J],
        also=[P2_ROW19G],
        kind="assertion",
        why="caller revert: from_csv without shared builder input_keys (contract (c2) MB1)",
    ),
    mutlib.Mutation(
        id="MB2",
        file=TARGET_LOADER,
        old="    Enum.map(records, fn record ->\n      base = Enum.map(resolved, fn column -> {column, Map.get(record, column, nil)} end)\n      build_example(Map.new(base), input_keys)\n    end)",
        new="    # MUTATION MB2: from_json without shared builder (input_keys dropped)\n    _ = input_keys\n    Enum.map(records, fn record ->\n      base = Enum.map(resolved, fn column -> {column, Map.get(record, column, nil)} end)\n      Example.new(Map.new(base))\n    end)",
        expect=[P2_ROW19G],
        also=[],
        kind="assertion",
        why="caller revert: from_json without shared builder (contract (c2) MB2)",
    ),
    mutlib.Mutation(
        id="MB3",
        file=TARGET_LOADER,
        old="  defp build_example(row_map, input_keys) when is_map(row_map) do\n    example = Example.new(row_map)\n    if input_keys == [], do: example, else: Example.with_inputs(example, input_keys)\n  end",
        new="  defp build_example(row_map, _input_keys) when is_map(row_map) do\n    Example.new(row_map) # MUTATION MB3: builder ignores input_keys\n  end",
        expect=[P2_ROW14J, P2_ROW19G],
        also=[],
        kind="assertion",
        why="shared break: builder ignores input_keys (contract (c2) MB3)",
    ),
    mutlib.Mutation(
        id="MJ0",
        file=TARGET_LOADER,
        old="      base = Enum.map(resolved, fn column -> {column, Map.get(record, column, nil)} end)",
        new='      base = Enum.map(resolved, fn column ->\n        v = Map.get(record, column, nil)\n        filled = if is_nil(v), do: "", else: v\n        {column, filled}\n      end)',
        expect=[P2_ROW19E],
        also=[P2_ROW19C],
        kind="assertion",
        why='null -> "" (contract (c2) MJ0)',
    ),
    mutlib.Mutation(
        id="MJ1",
        file=TARGET_LOADER,
        old="    records = decode_json_records!(content, path)\n    columns = union_keys(records)\n    resolved = resolve_fields!(columns, fields, path)\n\n    Enum.map(records, fn record ->\n      base = Enum.map(resolved, fn column -> {column, Map.get(record, column, nil)} end)\n      build_example(Map.new(base), input_keys)\n    end)",
        new="    records = decode_json_records!(content, path)\n    columns = union_keys(records)\n    resolved = resolve_fields!(columns, fields, path)\n\n    # MUTATION MJ1: union-of-keys fill dropped\n    Enum.map(records, fn record ->\n      base = Enum.filter(Map.to_list(record), fn {column, _} -> column in resolved end)\n      build_example(Map.new(base), input_keys)\n    end)",
        expect=[P2_ROW19C],
        also=[],
        kind="assertion",
        why="union-of-keys fill dropped (contract (c2) MJ1)",
    ),
    mutlib.Mutation(
        id="MJ2",
        file=TARGET_LOADER,
        old=MJ2B_OLD,
        new="  defp decode_json_records!(content, path) do\n    # MUTATION MJ2: always JSON array (JSONL fails)\n    case Jason.decode(content) do\n      {:ok, list} when is_list(list) ->\n        list\n      {:ok, other} ->\n        raise ArgumentError,\n              \"Dspy.DataLoader.from_json/2: #{path}: top-level JSON must be an array of objects, got #{inspect(other)}\"\n      {:error, reason} ->\n        raise ArgumentError,\n              \"Dspy.DataLoader.from_json/2: #{path}: invalid JSON: #{inspect(reason)}\"\n    end\n  end",
        expect=[P2_ROW19B],
        also=[P2_ROW18, P2_ROW19C, P2_ROW19D, P2_ROW19E, P2_ROW19G, P2_ROW21, P2_ROW21B, P2_ROW3B, P2_ROW3B2, P2_ROW4B, P2_ROW4C],
        kind="raise:Elixir.ArgumentError",
        why="input always parsed as JSON array (JSONL fails) (contract (c2) MJ2)",
    ),
    mutlib.Mutation(
        id="MJ2b",
        file=TARGET_LOADER,
        old=MJ2B_OLD,
        new=MJ2B_NEW,
        expect=[P2_ROW19A],
        also=[],
        kind="raise:Elixir.ArgumentError",
        why="input always parsed as JSONL (an array fails) (contract (c2) MJ2b)",
    ),
    mutlib.Mutation(
        id="MJ3",
        file=TARGET_LOADER,
        old="      base = Enum.map(resolved, fn column -> {column, Map.get(record, column, nil)} end)",
        new="      base = Enum.map(resolved, fn column ->\n        v = Map.get(record, column, nil)\n        flat = if is_map(v) or is_list(v), do: inspect(v), else: v # MUTATION MJ3\n        {column, flat}\n      end)",
        expect=[P2_ROW19D],
        also=[],
        kind="assertion",
        why="nested objects flattened to strings (contract (c2) MJ3)",
    ),
    mutlib.Mutation(
        id="MJ4",
        file=TARGET_LOADER,
        old='        content\n        |> String.split("\\n")\n        |> Enum.with_index(1)\n        |> Enum.reject(fn {line, _i} -> String.trim(line) == "" end)\n        |> Enum.map(fn {line, i} ->',
        new='        content\n        |> String.split("\\n")\n        |> Enum.with_index(1)\n        |> Enum.reject(fn {line, _i} -> String.trim(line) == "" end)\n        |> Enum.reject(fn {line, _i} ->\n          case Jason.decode(line) do\n            {:ok, map} when is_map(map) -> false\n            _ -> true # MUTATION MJ4: non-object record skipped\n          end\n        end)\n        |> Enum.map(fn {line, i} ->',
        expect=[P2_ROW19F],
        also=[],
        kind="assertion",
        why="non-object record skipped (contract (c2) MJ4)",
    ),
    mutlib.Mutation(
        id="MT1",
        file=TARGET_LOADER,
        old="    trunc(n * size)",
        new="    round(n * size) # MUTATION MT1: round instead of truncation",
        expect=[P2_ROW21],
        also=[P2_ROW21B],
        kind="assertion",
        why="round instead of truncation (contract (c2) MT1)",
    ),
    mutlib.Mutation(
        id="MT2",
        file=TARGET_LOADER,
        old='          case NumberParser.parse_integer(value || "") do\n',
        new='          case (case Integer.parse(value || "") do {int, _rest} -> {:ok, int}; :error -> :error end) do  # MUTATION MT2\n',
        expect=[P2_ROW30RAISE],
        also=[],
        kind="assertion",
        why="types: to_string(value) instead of value || \"\" (contract (c2) MT2)",
    ),
    mutlib.Mutation(
        id="MT3",
        file=TARGET_LOADER,
        old="    types = Keyword.get(opts, :types, %{})",
        new="    types = Keyword.get(opts, :types, %{})\n    types = Map.new(Enum.filter(Map.to_list(types), fn {_k, _v} -> false end)) # MUTATION MT3: types ignored",
        expect=[P2_ROW30, P2_ROW30UNTYPE],
        also=[P2_ROW30RAISE],
        kind="assertion",
        why="types: ignored (contract (c2) MT3)",
    ),
    mutlib.Mutation(
        id="MT4",
        file=TARGET_LOADER,
        old="**silently scores 0**, where\n  upstream's pandas-inferred integer would compare equal. Use `types:`",
        new="**scores 0**, where\n  upstream's integer would compare equal. Use `types:`",
        expect=[P2_ROW30C],
        also=[],
        kind="assertion",
        why="docstring 'silently' capitalized (contract (c2) MT4)",
    ),
    mutlib.Mutation(
        id="MC2",
        file=TARGET_LOADER,
        old="    {state, _} = Dspy.Random.seed(seed)\n    {_state, picked} = Dspy.Random.sample(state, examples, n)\n    picked",
        new="    :rand.seed(:exsss, {seed, 0, 0})\n    Enum.take_random(examples, n) # MUTATION MC2: :rand + Enum.take_random",
        expect=[P2_ROW3B, P2_ROW3B2, P2_ROW4B],
        also=[],
        kind="assertion",
        why="caller revert: sample/3 uses :rand.seed + Enum.take_random (contract (c2) MC2)",
    ),
    mutlib.Mutation(
        id="MC3",
        file=TARGET_LOADER,
        old="    {state, _} = Dspy.Random.seed(seed)\n    {_state, shuffled} = Dspy.Random.shuffle(state, examples)\n    train = Enum.take(shuffled, train_end)\n    rest = Enum.drop(shuffled, train_end)\n    test = Enum.take(rest, test_end)",
        new="    :rand.seed(:exsss, {seed, 1, 1})\n    shuffled = Enum.shuffle(examples) # MUTATION MC3: :rand + Enum.shuffle\n    train = Enum.take(shuffled, train_end)\n    rest = Enum.drop(shuffled, train_end)\n    test = Enum.take(rest, test_end)",
        expect=[P2_ROW4C, P2_ROW21B],
        also=[],
        kind="assertion",
        why="caller revert: train_test_split/2 uses :rand.seed + Enum.shuffle (contract (c2) MC3)",
    ),
    mutlib.Mutation(
        id="MC4",
        file=TARGET_LOADER,
        old="    seed = resolve_seed!(Keyword.get(opts, :seed))\n    {state, _} = Dspy.Random.seed(seed)\n    {_state, picked} = Dspy.Random.sample(state, examples, n)\n    picked",
        new="    seed = Keyword.get(opts, :seed)\n    if is_nil(seed) do\n      Enum.take_random(examples, n) # MUTATION MC4: seed: nil -> process :rand\n    else\n      {state, _} = Dspy.Random.seed(resolve_seed!(seed))\n      {_state, picked} = Dspy.Random.sample(state, examples, n)\n      picked\n    end",
        expect=[P2_ROW4B],
        also=[],
        kind="assertion",
        why="seed: nil falls back to process :rand state (pre-mortem 11) (contract (c2) MC4)",
    ),
]

# ---------------------------------------------------------------------------
# Phase-2 mutations — shipped H15 code (MD7b only; expect row 11 is phase-2)
# ---------------------------------------------------------------------------

MUTATIONS_SHIPPED = [
    mutlib.Mutation(
        id="MD7b",
        file=TARGET_EXAMPLE,
        old="  defp normalize_input_key!(key) when is_atom(key), do: Atom.to_string(key)",
        new='  defp normalize_input_key!(key) when is_atom(key), do: Atom.to_string(key) <> " "',
        expect=[P2_ROW11],
        also=[],
        kind="assertion",
        why="normalize_input_key! keeps atoms as atoms (contract (c2) MD7b)",
    ),
]

# ---------------------------------------------------------------------------
# Contract (c2) scope bookkeeping
# ---------------------------------------------------------------------------

CONTRACT_IDS = {
    "MG1", "MG2", "MG3", "MG3b", "MG4", "MG5", "MG6", "MG7",
    "MC1", "MC2", "MC3", "MC4",
    "MD1", "MD2", "MD2b", "MD3", "MD4", "MD5", "MD6", "MD7", "MD8", "MD8b", "MD9", "MD9b",
    "ML0", "ML1", "ML2", "ML3", "ML4", "ML5", "ML6", "ML6b", "ML7", "ML8",
    "ML9", "ML10",
    "MJ0", "MJ1", "MJ2", "MJ2b", "MJ3", "MJ4",
    "MT1", "MT2", "MT3", "MT4",
    "MB1", "MB2", "MB3",
    "MD7b",
}

CONTRACT_NOT_IN_PHASE2 = {"MC5", "MX1", "MX2", "MX3", "MX3b", "MP1", "MV1"}


def main() -> int:
    all_mutations = MUTATIONS_PHASE1 + MUTATIONS_DATASET + MUTATIONS_LOADER + MUTATIONS_SHIPPED
    defined_ids = [m.id for m in all_mutations]

    missing = CONTRACT_IDS - set(defined_ids)
    if missing:
        print(f"CONTRACT MISMATCH: missing phase-2 contract IDs: {sorted(missing)}")
        return 1
    if set(defined_ids) & CONTRACT_NOT_IN_PHASE2:
        print(
            f"CONTRACT MISMATCH: phase-3 IDs must not be defined: "
            f"{sorted(set(defined_ids) & CONTRACT_NOT_IN_PHASE2)}"
        )
        return 1
    if len(defined_ids) != len(set(defined_ids)):
        dupes = sorted({i for i in defined_ids if defined_ids.count(i) > 1})
        print(f"DUPLICATE MUTATION IDS: {dupes}")
        return 1
    for m in all_mutations:
        if not m.expect:
            print(f"EMPTY EXPECT: {m.id}")
            return 1

    all_tests = [TESTS, TESTS_PHASE2]
    all_acceptance = [TESTS, TESTS_PHASE2]

    all_exempt = {
        "row 5: reset_seeds accepts zero for every key": (
            "oracle port; `0` is truthy in Elixir, so no natural mutation "
            "(row 5b holds the Elixir trap)"
        ),
        "row 31: R6 generator re-runs and its fixture equals the committed one (metadata aside)":
            "static; run in review",
        "row 32: the harness: 0 failures of any verdict, 0 UNCLAIMED, also lists observed":
            "it is the harness itself",
        "row 33: Full suite + consumer canary green; git diff test/ additions only; test/consumer_contract/** unchanged":
            "gate",
        "row 35: static grep: no Map.get/fetch(…attrs…, :atom) and no String.to_atom/List.to_atom in the new modules":
            "static grep, printed",
        "seed integer seed produces a state struct with 624 words and mti=0":
            "structural; not a golden row",
        "seed non-integer seed raises ArgumentError":
            "ArgumentError on bad input; not a golden row",
        "getrandbits k=1 and k=32 are valid ranges": "range check; not a golden row",
        "getrandbits k=0 raises": "range guard; not a golden row",
        "getrandbits k=33 raises": "range guard; not a golden row",
        "randbelow n=0 raises": "range guard; not a golden row",
        "randrange start/stop/step form": "start/stop/step form; not a golden row",
        "randrange empty range raises": "ArgumentError on empty range; not a golden row",
        "randrange step=0 raises": "ArgumentError on step 0; not a golden row",
        "shuffle empty list": "n=0 edge case; not a golden row",
        "shuffle single element": "n=1 edge case; not a golden row",
        "sample k=0 returns empty list": "k=0 edge case; not a golden row",
        "sample k>n raises": "ArgumentError on k>n; not a golden row",
    }

    harness = mutlib.Harness(
        mutations=all_mutations,
        test_files=all_tests,
        acceptance_files=all_acceptance,
        root=REPO,
        exempt=all_exempt,
        report_path=REPO / "plan" / "research" / "pi_handoffs" / "m1e"
        / "mutation_report_phase2.json",
        base_green=True,
    )
    return harness.run()


if __name__ == "__main__":
    sys.exit(main())
