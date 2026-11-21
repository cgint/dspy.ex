defmodule Dspy.Teleprompt.GEPA.CandidatePool do
  @moduledoc false

  alias Dspy.Random

  @enforce_keys [:best, :best_mean, :candidates, :leaders]
  defstruct [:best, :best_mean, :candidates, :leaders]

  def new(program, scores) do
    mean = mean(scores)

    %__MODULE__{
      best: program,
      best_mean: mean,
      candidates: %{0 => {program, mean}},
      leaders: Enum.map(scores, &{&1, MapSet.new([0])})
    }
  end

  def add(pool, program, scores) do
    index = map_size(pool.candidates)
    mean = mean(scores)

    leaders =
      Enum.zip_with(pool.leaders, scores, fn {best_score, ids} = leader, score ->
        cond do
          score > best_score -> {score, MapSet.new([index])}
          score == best_score -> {best_score, MapSet.put(ids, index)}
          true -> leader
        end
      end)

    pool = %{
      pool
      | candidates: Map.put(pool.candidates, index, {program, mean}),
        leaders: leaders
    }

    if mean > pool.best_mean, do: %{pool | best: program, best_mean: mean}, else: pool
  end

  def keep_best(pool, program, scores) do
    if mean(scores) > pool.best_mean, do: new(program, scores), else: pool
  end

  def parent(pool, :current_best, random), do: {random, pool.best}

  def parent(pool, :pareto, random) do
    weights = frontier_weights(pool)
    {random, draw} = Random.randbelow(random, Enum.sum_by(weights, &elem(&1, 1)))
    index = choose(weights, draw)
    {program, _mean} = Map.fetch!(pool.candidates, index)
    {random, program}
  end

  defp frontier_weights(pool) do
    rows = Enum.map(pool.leaders, &elem(&1, 1))
    counts = rows |> Enum.map(&MapSet.size/1) |> Enum.with_index(&{&2, &1}) |> Map.new()

    support =
      rows
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {ids, row}, support ->
        Enum.reduce(ids, support, fn id, acc -> Map.update(acc, id, [row], &[row | &1]) end)
      end)

    ordered =
      Enum.sort_by(support, fn {id, _rows} ->
        {_program, mean} = Map.fetch!(pool.candidates, id)
        {mean, id}
      end)

    # Remove a candidate only if all the rows it leads still have another
    # leader. Lower aggregate scores give up redundant rows first.
    {weights, _counts} =
      Enum.reduce(ordered, {[], counts}, fn {id, rows}, {weights, counts} ->
        if Enum.all?(rows, &(Map.fetch!(counts, &1) > 1)) do
          {weights, Enum.reduce(rows, counts, &Map.update!(&2, &1, fn count -> count - 1 end))}
        else
          {[{id, length(rows)} | weights], counts}
        end
      end)

    Enum.sort(weights)
  end

  defp choose([{id, weight} | _], draw) when draw < weight, do: id
  defp choose([{_id, weight} | rest], draw), do: choose(rest, draw - weight)

  defp mean(scores), do: Enum.sum(scores) / length(scores)
end
