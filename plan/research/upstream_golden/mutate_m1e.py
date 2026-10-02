#!/usr/bin/env python3
"""Mutation harness — M1-e phase 1: Dspy.Random only (contract A2 / (c2)).

Phase 1 ships lib/dspy/random.ex and test/dspy/random_test.exs against the
CPython fixture test/fixtures/upstream_m1e_random_3_4_0.json. No Dataset /
DataLoader / loader code exists in this tree, so the caller-revert mutations
MC1, MC2, MC3, MC4, MC5 and the loader/consumer mutations (MD*, ML*, MJ*,
MB*, MT*, MX*, MP*, MV*) are NOT APPLICABLE in phase 1 and are excluded from
the harness. They belong to the later M1-e phases (handoff.md: work in three
phases; MC1/MC2/MC3 target files that do not exist yet).

Phase-1 mutations (all `assertion` kind except MG2; every `also` starts EMPTY and is
filled only from observed failures — H15 lesson 2026-10-02):

  MG1  init_by_array key words most-significant first (row 1: golden uint32)
  MG2  seed used without abs (row 1 + the negative-seed contract row)
  MG3  randbelow uses bit_length(n - 1) (rows 2 + 3: golden shuffle/sample)
  MG4  shuffle loop runs upward (row 2)
  MG5  sample always takes the pool branch (row 3)
  MG6  sample always takes the set branch (row 3)
  MG7  sample branch condition off-by-one: n < setsize instead of n <= setsize
       (row 3: the n = 21 (k <= 5) and n = 85 (k = 6) boundary-divergence
       rows flip; verified 2026-10-06)

Test names are the EXACT ExUnit names of the 25 tests in
test/dspy/random_test.exs (no "test " prefix), per the contract. Phase 1 has
no row 31-33 style static checks, so `exempt` is empty and coverage must be
0 UNCLAIMED.
"""

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "plan" / "research" / "harness"))
import mutlib  # noqa: E402

TARGET_LIB = REPO / "lib" / "dspy" / "random.ex"
TESTS = REPO / "test" / "dspy" / "random_test.exs"

# Exact ExUnit test names (the `test "..."` clauses in random_test.exs).
# The name includes the `describe` prefix: e.g. "seed negative seed uses abs(seed)".
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

MUTATIONS = [
    mutlib.Mutation(
        id="MG1",
        file=TARGET_LIB,
        old="key = seed |> abs() |> key_words() |> Enum.reverse()",
        new="key = seed |> abs() |> key_words() # MUTATION MG1",
        expect=[T_FIRST5],
        also=[],
        kind="assertion",
        why="key words most-significant first (contract (c2) MG1)",
    ),
    mutlib.Mutation(
        id="MG2",
        file=TARGET_LIB,
        old="key = seed |> abs() |> key_words() |> Enum.reverse()",
        new="key = seed |> key_words() |> Enum.reverse()",
        expect=[T_FIRST5, T_ABS, T_SEED],
        also=[],
        kind="raise:ExUnit.TimeoutError",
        # kind=raise:ExUnit.TimeoutError: without abs, seed(-5) enters
        # do_key_words(-5) and loops forever (bsr of a negative integer
        # never reaches 0 in Elixir's arbitrary-precision arithmetic), so
        # the test hangs and ExUnit's test-level timeout (tag: timeout: 2000
        # on the two seed -5 tests) raises ExUnit.TimeoutError rather than
        # an assertion error.
        why="seed used without abs (contract (c2) MG2)",
    ),
    mutlib.Mutation(
        id="MG3",
        file=TARGET_LIB,
        old=(
            "def randbelow(state, n) when is_integer(n) and n > 0 do\n"
            "    do_randbelow(state, n, bit_length(n))\n"
            "  end"
        ),
        new=(
            "def randbelow(state, n) when is_integer(n) and n > 0 do\n"
            "    do_randbelow(state, n, bit_length(n - 1))\n"
            "  end"
        ),
        expect=[T_SHUFFLE, T_SAMPLE],
        also=[
            "randbelow matches CPython randrange (step 1)",
            "randrange step 1 matches CPython",
            "sample k=n returns a permutation",
        ],
        kind="assertion",
        why="shared break: randbelow uses bit_length(n - 1) (contract (c2) MG3)",
    ),
    mutlib.Mutation(
        id="MG4",
        file=TARGET_LIB,
        old=(
            "      do_shuffle(state, list, len - 1)\n"
            "    end\n"
            "  end\n"
            "\n"
            "  defp do_shuffle(state, list, 0), do: {state, list}\n"
            "\n"
            "  defp do_shuffle(state, list, i) do\n"
            "    {state, j} = randbelow(state, i + 1)\n"
            "    do_shuffle(state, swap(list, i, j), i - 1)\n"
            "  end"
        ),
        new=(
            "      do_shuffle_upward(state, list, 1)\n"
            "    end\n"
            "  end\n"
            "\n"
            "  defp do_shuffle_upward(state, list, i) when i >= length(list), do: {state, list}\n"
            "\n"
            "  defp do_shuffle_upward(state, list, i) do\n"
            "    {state, j} = randbelow(state, i + 1)\n"
            "    do_shuffle_upward(state, swap(list, i, j), i + 1)\n"
            "  end"
        ),
        expect=[T_SHUFFLE],
        also=[],
        kind="assertion",
        why="shuffle loop runs upward (contract (c2) MG4)",
    ),
    mutlib.Mutation(
        id="MG5",
        file=TARGET_LIB,
        old=(
            "    if n <= setsize(k) do\n"
            "      sample_pool(state, population, k, n)\n"
            "    else\n"
            "      sample_set(state, population, k, n)\n"
            "    end"
        ),
        new="sample_pool(state, population, k, n) # MUTATION MG5",
        expect=[T_SAMPLE],
        also=[T_BOUNDARY_22_K5, T_BOUNDARY_86_K6],
        kind="assertion",
        why="sample always takes the pool branch (contract (c2) MG5)",
    ),
    mutlib.Mutation(
        id="MG6",
        file=TARGET_LIB,
        old=(
            "    if n <= setsize(k) do\n"
            "      sample_pool(state, population, k, n)\n"
            "    else\n"
            "      sample_set(state, population, k, n)\n"
            "    end"
        ),
        new="sample_set(state, population, k, n) # MUTATION MG6",
        expect=[T_SAMPLE],
        also=[T_BOUNDARY_21_K5, T_BOUNDARY_85_K6],
        kind="assertion",
        why="sample always takes the set branch (contract (c2) MG6)",
    ),
    mutlib.Mutation(
        id="MG7",
        file=TARGET_LIB,
        old=(
            "    if n <= setsize(k) do\n"
            "      sample_pool(state, population, k, n)\n"
            "    else\n"
            "      sample_set(state, population, k, n)\n"
            "    end"
        ),
        new=(
            "    if n < setsize(k) do\n"
            "      sample_pool(state, population, k, n)\n"
            "    else\n"
            "      sample_set(state, population, k, n)\n"
            "    end"
        ),
        expect=[T_BOUNDARY_21_K5, T_BOUNDARY_85_K6],
        also=[T_SAMPLE],
        kind="assertion",
        why=(
            "sample branch condition off-by-one: n < setsize instead of n <= setsize "
            "(added 2026-10-06; only n == setsize flips — n = 21 for k <= 5, "
            "n = 85 for k = 6..8 — so those boundary rows are the killers; "
            "the just-past-boundary rows n = 22 / n = 86 are regression pins)"
        ),
    ),
]


# Tests not claimed by any phase-1 mutation. The phase-1 contract claims only
# the golden rows (1: uint32, 2: shuffle, 3: sample); the rest are edge-case /
# raise / range tests that no phase-1 mutation targets. Exempt with reasons.
EXEMPT = {
    "seed integer seed produces a state struct with 624 words and mti=0":
        "structural; not a golden row (no phase-1 mutation targets it)",
    "seed non-integer seed raises ArgumentError":
        "ArgumentError on bad input; not a golden row",
    "getrandbits k=1 and k=32 are valid ranges": "range check; not a golden row",
    "getrandbits k=0 raises": "range guard; not a golden row",
    "getrandbits k=33 raises": "range guard; not a golden row",
    "randbelow n=0 raises": "range guard; not a golden row",
    "randrange step 1 matches CPython":
        "same fixture as the randbelow golden row; MG3 already claims the randbelow row",
    "randrange start/stop/step form": "start/stop/step form; not a golden row",
    "randrange empty range raises": "ArgumentError on empty range; not a golden row",
    "randrange step=0 raises": "ArgumentError on step 0; not a golden row",
    "shuffle empty list": "n=0 edge case; not a golden row",
    "shuffle single element": "n=1 edge case; not a golden row",
    "sample k=0 returns empty list": "k=0 edge case; not a golden row",
    "sample k=n returns a permutation": "k=n edge case; not a golden row",
    "sample k>n raises": "ArgumentError on k>n; not a golden row",
    # Boundary-divergence regression pin (n = 22 just past the k <= 5
    # boundary; does not flip under MG7, fails under MG5/MG6). Not claimed
    # by any expect list, so exempted.
    "sample fixture n=22 k=5 seed 2 pins the set branch just past the boundary":
        "boundary regression pin; not claimed by any mutation expect list",
    "sample fixture n=86 k=6 seed 5 pins the set branch one past the k=6 boundary":
        "boundary regression pin; not claimed by any mutation expect list",
}


def main() -> int:
    harness = mutlib.Harness(
        mutations=MUTATIONS,
        test_files=[TESTS],
        acceptance_files=[TESTS],
        root=REPO,
        exempt=EXEMPT,
        report_path=REPO / "plan" / "research" / "pi_handoffs" / "m1e"
        / "mutation_report_phase1.json",
        base_green=True,
    )
    return harness.run()


if __name__ == "__main__":
    sys.exit(main())
