defmodule Dspy.Teleprompt.GEPA.CandidatePool do
  @moduledoc false

  alias Dspy.Random

  @enforce_keys [:best_id, :candidates, :leaders]
  defstruct [:best_id, :candidates, :leaders]

  def new(program, scores, dimensions \\ nil) do
    %__MODULE__{
      best_id: 0,
      candidates: %{0 => entry(program, scores, MapSet.new())},
      leaders: update_leaders(%{}, scores, dimensions, 0)
    }
  end

  def add(pool, program, scores, parents \\ [], dimensions \\ nil) do
    index = map_size(pool.candidates)
    entry = entry(program, scores, ancestors(pool, parents))
    leaders = update_leaders(pool.leaders, scores, dimensions, index)

    best_id = if entry.mean > fetch(pool, pool.best_id).mean, do: index, else: pool.best_id

    %{
      pool
      | best_id: best_id,
        candidates: Map.put(pool.candidates, index, entry),
        leaders: leaders
    }
  end

  def keep_best(pool, program, scores) do
    if mean(scores) > fetch(pool, pool.best_id).mean, do: new(program, scores), else: pool
  end

  def fetch(pool, id), do: Map.fetch!(pool.candidates, id)
  def best(pool), do: fetch(pool, pool.best_id).program

  def known?(pool, program),
    do: Enum.any?(pool.candidates, fn {_id, entry} -> entry.program === program end)

  def parent(pool, :current_best, random), do: {random, pool.best_id}

  def parent(pool, :pareto, random) do
    weights = frontier_weights(pool)
    {random, draw} = Random.randbelow(random, Enum.sum_by(weights, &elem(&1, 1)))
    {random, choose(weights, draw)}
  end

  def frontier(pool), do: Enum.map(frontier_weights(pool), &elem(&1, 0))

  defp update_leaders(leaders, scores, dimensions, id) do
    dimensions = dimensions || Enum.with_index(scores, &{&2, &1})

    Enum.reduce(dimensions, leaders, fn {key, score}, acc ->
      case Map.get(acc, key) do
        {best, _ids} when best > score -> acc
        {best, ids} when best == score -> Map.put(acc, key, {best, MapSet.put(ids, id)})
        _ -> Map.put(acc, key, {score, MapSet.new([id])})
      end
    end)
  end

  defp frontier_weights(pool) do
    rows = Enum.map(pool.leaders, fn {_key, {_score, ids}} -> ids end)
    counts = rows |> Enum.map(&MapSet.size/1) |> Enum.with_index(&{&2, &1}) |> Map.new()

    support =
      rows
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {ids, row}, support ->
        Enum.reduce(ids, support, fn id, acc -> Map.update(acc, id, [row], &[row | &1]) end)
      end)

    ordered =
      Enum.sort_by(support, fn {id, _rows} ->
        {fetch(pool, id).mean, id}
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

  defp entry(program, scores, ancestors) do
    %{program: program, scores: List.to_tuple(scores), mean: mean(scores), ancestors: ancestors}
  end

  defp ancestors(pool, parents) do
    Enum.reduce(parents, MapSet.new(), fn parent, ancestors ->
      ancestors |> MapSet.union(fetch(pool, parent).ancestors) |> MapSet.put(parent)
    end)
  end

  defp mean(scores), do: Enum.sum(scores) / length(scores)
end
