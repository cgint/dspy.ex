defmodule Dspy.RandomTest do
  use ExUnit.Case, async: true

  @moduletag :m1e_random

  @fixture Path.join([__DIR__, "..", "fixtures", "upstream_m1e_random_3_4_0.json"])

  setup_all do
    fixture =
      @fixture
      |> Path.expand()
      |> File.read!()
      |> Jason.decode!()

    {:ok, fixture: fixture}
  end

  # Parse "n100_seed0" -> {100, 0}
  defp parse_randrange_key("n" <> rest) do
    [n_str, seed_str] = String.split(rest, "_seed")
    {String.to_integer(n_str), String.to_integer(seed_str)}
  end

  # Parse "n10_k3_seed0" -> {10, 3, 0}
  defp parse_sample_key(key) do
    [n_part, k_part, seed_part] = String.split(key, "_")
    n = n_part |> String.trim_leading("n") |> String.to_integer()
    k = k_part |> String.trim_leading("k") |> String.to_integer()
    seed = seed_part |> String.trim_leading("seed") |> String.to_integer()
    {n, k, seed}
  end

  test "seed integer seed produces a state struct with 624 words and mti=0" do
    {state, nil} = Dspy.Random.seed(0)
    assert state.mti == 0
    assert map_size(state.mt) == 624
  end

  # Without abs (mutation MG2), seed(-5) loops forever in do_key_words/2 and
  # the test hangs; the per-test timeout turns that into ExUnit.TimeoutError.
  @tag timeout: 2000
  test "seed negative seed uses abs(seed)" do
    {pos, nil} = Dspy.Random.seed(5)
    {neg, nil} = Dspy.Random.seed(-5)
    assert pos.mt == neg.mt
  end

  test "seed non-integer seed raises ArgumentError" do
    assert_raise ArgumentError, fn -> Dspy.Random.seed("hello") end
    assert_raise ArgumentError, fn -> Dspy.Random.seed(1.5) end
  end

  test "getrandbits k=32 matches CPython first5 for all fixture seeds", %{fixture: fixture} do
    for {seed_str, expected_first5} <- fixture["first5"] do
      seed = String.to_integer(seed_str)
      {state, _} = Dspy.Random.seed(seed)
      {s1, w1} = Dspy.Random.getrandbits(state, 32)
      {s2, w2} = Dspy.Random.getrandbits(s1, 32)
      {s3, w3} = Dspy.Random.getrandbits(s2, 32)
      {s4, w4} = Dspy.Random.getrandbits(s3, 32)
      {s5, w5} = Dspy.Random.getrandbits(s4, 32)

      assert [w1, w2, w3, w4, w5] == expected_first5,
             "seed #{seed}: got [#{w1}, #{w2}, #{w3}, #{w4}, #{w5}], expected #{inspect(expected_first5)}"
    end
  end

  test "getrandbits k=1 and k=32 are valid ranges" do
    {state, _} = Dspy.Random.seed(42)
    {state, w32} = Dspy.Random.getrandbits(state, 32)
    {state, w1} = Dspy.Random.getrandbits(state, 1)
    assert w32 in 0..0xFFFF_FFFF
    assert w1 in [0, 1]
  end

  test "getrandbits k=0 raises" do
    {state, _} = Dspy.Random.seed(0)
    assert_raise FunctionClauseError, fn -> Dspy.Random.getrandbits(state, 0) end
  end

  test "getrandbits k=33 raises" do
    {state, _} = Dspy.Random.seed(0)
    assert_raise FunctionClauseError, fn -> Dspy.Random.getrandbits(state, 33) end
  end

  test "randbelow matches CPython randrange (step 1)", %{fixture: fixture} do
    for {key, expected} <- fixture["randrange"] do
      {n, seed} = parse_randrange_key(key)
      {state, _} = Dspy.Random.seed(seed)
      {_, result} = Dspy.Random.randbelow(state, n)

      assert result == expected,
             "randbelow(#{n}) seed #{seed}: got #{result}, expected #{expected}"
    end
  end

  test "randbelow n=0 raises" do
    {state, _} = Dspy.Random.seed(0)
    assert_raise FunctionClauseError, fn -> Dspy.Random.randbelow(state, 0) end
  end

  test "randrange step 1 matches CPython", %{fixture: fixture} do
    for {key, expected} <- fixture["randrange"] do
      {n, seed} = parse_randrange_key(key)
      {state, _} = Dspy.Random.seed(seed)
      {_, result} = Dspy.Random.randrange(state, n)

      assert result == expected,
             "randrange(#{n}) seed #{seed}: got #{result}, expected #{expected}"
    end
  end

  test "randrange start/stop/step form" do
    {state, _} = Dspy.Random.seed(0)
    {_, result} = Dspy.Random.randrange(state, 5, 15, 2)
    assert result == 11
  end

  test "randrange empty range raises" do
    {state, _} = Dspy.Random.seed(0)
    assert_raise ArgumentError, fn -> Dspy.Random.randrange(state, 10, 5, 1) end
  end

  test "randrange step=0 raises" do
    {state, _} = Dspy.Random.seed(0)
    assert_raise ArgumentError, fn -> Dspy.Random.randrange(state, 5, 15, 0) end
  end

  test "shuffle matches CPython for n=0,1,2,10,100,1000", %{fixture: fixture} do
    for {n_str, expected} <- fixture["shuffle"] do
      n = String.to_integer(n_str)
      population = if n == 0, do: [], else: Enum.to_list(0..(n - 1))
      {state, result} = Dspy.Random.shuffle(Dspy.Random.seed(0) |> elem(0), population)

      assert result == expected,
             "shuffle n=#{n}: got #{inspect(Enum.take(result, 10))}, expected #{inspect(Enum.take(expected, 10))}"
    end
  end

  test "shuffle empty list" do
    {state, result} = Dspy.Random.shuffle(Dspy.Random.seed(0) |> elem(0), [])
    assert result == []
  end

  test "shuffle single element" do
    {state, result} = Dspy.Random.shuffle(Dspy.Random.seed(0) |> elem(0), [42])
    assert result == [42]
  end

  test "sample matches CPython for all fixture vectors", %{fixture: fixture} do
    for {key, expected} <- fixture["sample"] do
      {n, k, seed} = parse_sample_key(key)

      {state, result} =
        Dspy.Random.sample(Dspy.Random.seed(seed) |> elem(0), Enum.to_list(0..(n - 1)), k)

      assert result == expected,
             "sample n=#{n} k=#{k} seed=#{seed}: got #{inspect(result)}, expected #{inspect(expected)}"
    end
  end

  # Boundary pins (fixture rows, verified CPython pool/set divergences —
  # gen_m1e_random_golden.py): the pool branch applies while n <= setsize,
  # the set branch for n > setsize (k <= 5 -> setsize 21, k = 6 -> setsize
  # 21 + 4**ceil(log(18, 4)) = 85).
  # An off-by-one in the branch condition (n < setsize) flips n = 21 and
  # n = 22 into the wrong branch; the divergent seeds make that a
  # different result, so the assertion fails.
  test "sample fixture n=85 k=6 seed 5 pins the set branch (divergence)" do
    {state, _} = Dspy.Random.seed(5)
    {_, result} = Dspy.Random.sample(state, Enum.to_list(0..84), 6)
    assert result == [79, 32, 45, 67, 3, 59]
  end

  test "sample fixture n=21 k=5 seed 2 pins the pool branch at the boundary" do
    {state, _} = Dspy.Random.seed(2)
    {_, result} = Dspy.Random.sample(state, Enum.to_list(0..20), 5)
    assert result == [1, 2, 19, 11, 5]
  end

  test "sample fixture n=22 k=5 seed 2 pins the set branch just past the boundary" do
    {state, _} = Dspy.Random.seed(2)
    {_, result} = Dspy.Random.sample(state, Enum.to_list(0..21), 5)
    assert result == [1, 2, 11, 5, 21]
  end

  test "sample fixture n=86 k=6 seed 5 pins the set branch one past the k=6 boundary" do
    {state, _} = Dspy.Random.seed(5)
    {_, result} = Dspy.Random.sample(state, Enum.to_list(0..85), 6)
    assert result == [79, 32, 45, 83, 67, 3]
  end

  test "sample k=0 returns empty list" do
    {state, result} = Dspy.Random.sample(Dspy.Random.seed(0) |> elem(0), [1, 2, 3], 0)
    assert result == []
  end

  test "sample k=n returns a permutation" do
    {state, result} = Dspy.Random.sample(Dspy.Random.seed(0) |> elem(0), [1, 2, 3, 4], 4)
    assert Enum.sort(result) == [1, 2, 3, 4]
  end

  test "sample k>n raises" do
    {state, _} = Dspy.Random.seed(0)
    assert_raise ArgumentError, fn -> Dspy.Random.sample(state, [1, 2, 3], 4) end
  end

  # Per-test timeout: same as "seed negative seed uses abs(seed)" above —
  # without abs (mutation MG2), seed(-5) hangs and the timeout fires.
  @tag timeout: 2000
  test "abs_seed_parity negative seeds match positive", %{fixture: fixture} do
    expected = fixture["abs_seed_parity"]["-5"]
    {state, _} = Dspy.Random.seed(-5)
    {s1, w1} = Dspy.Random.getrandbits(state, 32)
    {s2, w2} = Dspy.Random.getrandbits(s1, 32)
    {s3, w3} = Dspy.Random.getrandbits(s2, 32)
    {s4, w4} = Dspy.Random.getrandbits(s3, 32)
    {s5, w5} = Dspy.Random.getrandbits(s4, 32)
    assert [w1, w2, w3, w4, w5] == expected
  end
end
