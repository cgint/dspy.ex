defmodule Dspy.Random do
  @moduledoc false
  #
  # CPython-compatible MT19937 generator (M1-e phase 1, contract A2).
  #
  # For the same integer seed it produces exactly the same sequence as
  # CPython's `random.Random(seed)` — pinned by the golden fixture
  # `test/fixtures/upstream_m1e_random_3_4_0.json` (generated from real
  # CPython by plan/research/upstream_golden/gen_m1e_random_golden.py).
  #
  # Pure integer arithmetic: no :rand, no process dictionary, no map
  # iteration order — the same seed gives the same order on every Elixir
  # and OTP version. Internal module; shared generator for Dspy.Dataset
  # and Dspy.DataLoader (M1-e).
  #
  # Ported from CPython Modules/_randommodule.c (init_genrand,
  # init_by_array, genrand_uint32) and Lib/random.py (seed, shuffle,
  # sample, _randbelow, randrange). Stateful calls return
  # {state, result}; the generator is a pure value.
  #
  # State: `mt` is a map from 0..623 to 32-bit words; `mti` is the read
  # index (starts at 624 after seeding, like CPython, so the first draw
  # triggers the twist).

  import Bitwise

  @n 624
  @m 397
  @mask 0xFFFFFFFF
  @upper 0x80000000
  @lower 0x7FFFFFFF
  @matrix_a 0x9908B0DF

  @type t :: %__MODULE__{mt: map(), mti: non_neg_integer()}

  defstruct mt: %{}, mti: 0

  @doc """
  Create a generator seeded exactly like CPython's `random.Random(seed)`.

  Integer seeds only (CPython's string/bytes SHA-512 path is a declared
  M1-e non-goal). Negative seeds seed with abs(seed), parity with CPython.
  """
  def seed(seed) when is_integer(seed) do
    key = seed |> abs() |> key_words() |> Enum.reverse()
    mt = init_by_array(init_genrand(1_965_0218), key)
    # CPython seeds the generator and immediately twists once (index 0).
    # The getstate() dump captures the untwisted array, so we twist here
    # and start reading from index 0.
    state = struct(__MODULE__, mt: twist(mt), mti: 0)
    {state, nil}
  end

  def seed(other) do
    raise ArgumentError,
          "Dspy.Random.seed/1 supports integer seeds only, got: #{inspect(other)}"
  end

  @doc """
  A random k-bit integer, 1 <= k <= 32 — CPython's getrandbits(k).
  """
  def getrandbits(state, k) when is_integer(k) and k >= 1 and k <= 32 do
    {state, word} = genrand_uint32(state)
    {state, word >>> (32 - k)}
  end

  @doc """
  Uniform integer in 0..<(n) — CPython's _randbelow(n).

  k = bit_length(n) (of n, NOT n - 1); draw getrandbits(k) until < n.
  """
  def randbelow(state, n) when is_integer(n) and n > 0 do
    do_randbelow(state, n, bit_length(n))
  end

  defp bit_length(n), do: bit_length(n, 0)
  defp bit_length(0, acc), do: acc
  defp bit_length(n, acc), do: bit_length(n >>> 1, acc + 1)

  @doc """
  CPython's randrange (step 1).
  """
  def randrange(state, n) when is_integer(n) do
    do_randrange(state, 0, n, 1)
  end

  def randrange(state, start, stop, step \\ 1)
      when is_integer(start) and is_integer(stop) and is_integer(step) do
    do_randrange(state, start, stop, step)
  end

  @doc """
  CPython's list.shuffle: for i from length - 1 down to 1,
  j = randbelow(i + 1), swap positions i and j.
  """
  def shuffle(state, list) when is_list(list) do
    len = length(list)

    if len <= 1 do
      {state, list}
    else
      do_shuffle(state, list, len - 1)
    end
  end

  defp do_shuffle(state, list, 0), do: {state, list}

  defp do_shuffle(state, list, i) do
    {state, j} = randbelow(state, i + 1)
    do_shuffle(state, swap(list, i, j), i - 1)
  end

  @doc """
  CPython's random.sample(population, k) with both branches: the pool
  branch when n <= setsize, the set branch otherwise, where setsize is 21
  for k <= 5 and 21 + 4 ** ceil(log(3k, 4)) for k > 5 (CPython computes
  the power with integer arithmetic).
  """
  def sample(state, population, k) when is_list(population) and is_integer(k) do
    n = length(population)

    if k > n do
      raise ArgumentError,
            "Cannot sample more than the population size: k=#{k} > n=#{n}"
    end

    if n <= setsize(k) do
      sample_pool(state, population, k, n)
    else
      sample_set(state, population, k, n)
    end
  end

  # ---------------------------------------------------------------- seeding

  # CPython init_genrand (Modules/_randommodule.c): mt[0] = s;
  # mt[mti] = 1812433253 * (mt[mti-1] ^ (mt[mti-1] >> 30)) + mti.
  defp init_genrand(s) do
    mt = Map.put(%{}, 0, s)

    Enum.reduce(1..(@n - 1), mt, fn i, acc ->
      prev = Map.fetch!(acc, i - 1)
      word = rem(1_812_433_253 * Bitwise.bxor(prev, Bitwise.bsr(prev, 30)) + i, 0x1_0000_0000)
      Map.put(acc, i, word)
    end)
  end

  # CPython init_by_array (Modules/_randommodule.c), verbatim:
  #   init_genrand(19650218); i = 1; j = 0;
  #   for k in (N > keylen ? N : keylen) down to 1:
  #     mt[i] ^= ((mt[i-1] ^ (mt[i-1] >> 30)) * 1664525);
  #     mt[i] += key[j % keylen] + j;  i++; j++;  (wrap i at N copying mt[N-1] to mt[0])
  #   for k in N-1 down to 1:
  #     mt[i] ^= ((mt[i-1] ^ (mt[i-1] >> 30)) * 1566083941);
  #     mt[i] -= i;  i++;  (same wrap)
  #   mt[0] = 0x80000000
  defp init_by_array(mt, key) do
    keylen = length(key)
    k = if @n > keylen, do: @n, else: keylen
    {mt, i, _j} = mix1(mt, k, 1, 0, keylen, key)
    mt = mix2(mt, @n - 1, i)
    Map.put(mt, 0, 0x8000_0000)
  end

  defp mix1(mt, k, i, j, _keylen, _key) when k == 0, do: {mt, i, j}

  defp mix1(mt, k, i, j, keylen, key) do
    prev = Map.fetch!(mt, i - 1)
    x = Bitwise.bxor(prev, Bitwise.bsr(prev, 30))
    w = Bitwise.bxor(Map.fetch!(mt, i), Bitwise.band(x * 1_664_525, @mask))
    w = Bitwise.band(w + Bitwise.band(Enum.at(key, j), @mask) + j, @mask)
    mt = Map.put(mt, i, w)

    {mt, i} =
      if i + 1 >= @n do
        {Map.put(mt, 0, Map.fetch!(mt, @n - 1)), 1}
      else
        {mt, i + 1}
      end

    j = if j + 1 >= keylen, do: 0, else: j + 1
    mix1(mt, k - 1, i, j, keylen, key)
  end

  defp mix2(mt, k, _i) when k == 0, do: mt

  defp mix2(mt, k, i) do
    prev = Map.fetch!(mt, i - 1)
    x = Bitwise.bxor(prev, Bitwise.bsr(prev, 30))
    w = Bitwise.bxor(Map.fetch!(mt, i), Bitwise.band(x * 1_566_083_941, @mask))
    w = Bitwise.band(w - i, @mask)
    mt = Map.put(mt, i, w)

    {mt, i} =
      if i + 1 >= @n do
        {Map.put(mt, 0, Map.fetch!(mt, @n - 1)), 1}
      else
        {mt, i + 1}
      end

    mix2(mt, k - 1, i)
  end

  # CPython random.seed(int): abs(seed) split into 32-bit words,
  # least-significant first; seed 0 gives the key [0].
  defp key_words(0), do: [0]
  defp key_words(n), do: do_key_words(n, [])

  defp do_key_words(0, acc), do: acc
  defp do_key_words(n, acc), do: do_key_words(n >>> 32, [Bitwise.band(n, @mask) | acc])

  # ------------------------------------------------------------ generation

  # CPython genrand_uint32 (Modules/_randommodule.c): when the index
  # reaches N the whole array is twisted first (M = 397, mag01), then the
  # word at the index is read, the index advanced, and the word tempered.
  defp genrand_uint32(%{mti: mti} = state) when mti >= @n do
    state = Map.put(state, :mt, twist(state.mt))
    Map.put(state, :mti, 0) |> do_genrand()
  end

  defp genrand_uint32(state) do
    state |> do_genrand()
  end

  defp do_genrand(%{mti: mti} = state) do
    x = Map.fetch!(state.mt, mti)
    y = Bitwise.bxor(x, Bitwise.bsr(x, 11))
    y = Bitwise.bxor(y, Bitwise.band(Bitwise.bsl(y, 7), 0x9D2C5680))
    y = Bitwise.bxor(y, Bitwise.band(Bitwise.bsl(y, 15), 0xEFC6_0000))
    y = Bitwise.bxor(y, Bitwise.bsr(y, 18))
    {Map.put(state, :mti, mti + 1), Bitwise.band(y, @mask)}
  end

  defp twist(mt) do
    mt
    |> twist_range(0, @n - @m - 1, fn acc, kk ->
      y =
        Bitwise.bor(
          Bitwise.band(Map.fetch!(acc, kk), @upper),
          Bitwise.band(Map.fetch!(acc, kk + 1), @lower)
        )

      mag = if Bitwise.band(y, 1) == 1, do: @matrix_a, else: 0

      word =
        Bitwise.band(
          Bitwise.bxor(Map.fetch!(acc, kk + @m), Bitwise.bxor(Bitwise.bsr(y, 1), mag)),
          @mask
        )

      {Map.put(acc, kk, word), kk}
    end)
    |> twist_range(@n - @m, @n - 2, fn acc, kk ->
      y =
        Bitwise.bor(
          Bitwise.band(Map.fetch!(acc, kk), @upper),
          Bitwise.band(Map.fetch!(acc, kk + 1), @lower)
        )

      mag = if Bitwise.band(y, 1) == 1, do: @matrix_a, else: 0

      word =
        Bitwise.band(
          Bitwise.bxor(Map.fetch!(acc, kk + (@m - @n)), Bitwise.bxor(Bitwise.bsr(y, 1), mag)),
          @mask
        )

      {Map.put(acc, kk, word), kk}
    end)
    |> then(fn acc ->
      y =
        Bitwise.bor(
          Bitwise.band(Map.fetch!(acc, @n - 1), @upper),
          Bitwise.band(Map.fetch!(acc, 0), @lower)
        )

      mag = if Bitwise.band(y, 1) == 1, do: @matrix_a, else: 0

      word =
        Bitwise.band(
          Bitwise.bxor(Map.fetch!(acc, @m - 1), Bitwise.bxor(Bitwise.bsr(y, 1), mag)),
          @mask
        )

      Map.put(acc, @n - 1, word)
    end)
  end

  defp twist_range(mt, from, to, _fun) when from > to, do: mt

  defp twist_range(mt, kk, to, fun) do
    {mt, _kk} = fun.(mt, kk)
    twist_range(mt, kk + 1, to, fun)
  end

  # ------------------------------------------------------------- consumers

  defp do_randbelow(state, n, k) do
    {state, r} = getrandbits(state, k)
    if r < n, do: {state, r}, else: do_randbelow(state, n, k)
  end

  defp do_randrange(state, start, stop, step) do
    if step == 0 do
      raise ArgumentError, "randrange step must not be 0"
    end

    width =
      if step > 0 do
        div(stop - start + step - 1, step)
      else
        div(start - stop - step - 1, -step)
      end

    if width <= 0 do
      raise ArgumentError, "empty range for randrange(#{start}, #{stop}, #{step})"
    end

    {state, idx} = randbelow(state, width)
    {state, start + idx * step}
  end

  defp swap(list, i, j) when i == j, do: list

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    List.replace_at(List.replace_at(list, i, b), j, a)
  end

  # CPython sample: setsize is 21 for k <= 5, else
  # 21 + 4 ** ceil(log(3k, 4)) with an integer power.
  defp setsize(k) when k <= 5, do: 21

  defp setsize(k) do
    21 + trunc(:math.pow(4, :math.ceil(:math.log(3 * k) / :math.log(4))))
  end

  # CPython _sample_pool: pool = list(population); for i in range(k):
  # j = randbelow(n - i); result[i] = pool[j]; pool[j] = pool[n-i-1].
  defp sample_pool(state, _pool, 0, _n), do: {state, []}

  defp sample_pool(state, pool, k, n) do
    {state, result, _pool} = do_sample_pool(state, pool, k, n, 0, [])
    {state, Enum.reverse(result)}
  end

  defp do_sample_pool(state, pool, k, _n, i, result) when i == k, do: {state, result, pool}

  defp do_sample_pool(state, pool, k, n, i, result) do
    {state, j} = randbelow(state, n - i)
    value = Enum.at(pool, j)
    pool = List.replace_at(pool, j, Enum.at(pool, n - i - 1))
    do_sample_pool(state, pool, k, n, i + 1, [value | result])
  end

  # CPython _sample_set: for i in range(k): j = randbelow(n) (redrawn
  # while already selected); result[i] = population[j].
  defp sample_set(state, _population, 0, _n), do: {state, []}

  defp sample_set(state, population, k, n) do
    {state, result, _selected} = do_sample_set(state, population, n, k, 0, [], MapSet.new())
    {state, Enum.reverse(result)}
  end

  defp do_sample_set(state, _population, _n, k, i, result, selected) when i == k,
    do: {state, result, selected}

  defp do_sample_set(state, population, n, k, i, result, selected) do
    {state, j} = do_pick_unused(state, n, selected)
    selected = MapSet.put(selected, j)
    do_sample_set(state, population, n, k, i + 1, [Enum.at(population, j) | result], selected)
  end

  defp do_pick_unused(state, n, selected) do
    {state, j} = randbelow(state, n)
    if j in selected, do: do_pick_unused(state, n, selected), else: {state, j}
  end
end
