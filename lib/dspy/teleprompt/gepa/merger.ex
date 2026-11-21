defmodule Dspy.Teleprompt.GEPA.Merger do
  @moduledoc false

  alias Dspy.Module.PredictorSlots
  alias Dspy.Random
  alias Dspy.Teleprompt.GEPA.CandidatePool

  @sample_size 5

  def propose(pool, attempted, random) do
    leaders = CandidatePool.frontier(pool)

    leaders
    |> Stream.flat_map(fn left ->
      leaders
      |> Stream.filter(&(&1 > left))
      |> Stream.map(&{left, &1})
    end)
    |> Enum.find_value(fn {left_id, right_id} ->
      try_pair(pool, left_id, right_id, attempted, random)
    end)
  end

  defp try_pair(pool, left_id, right_id, attempted, random) do
    left = CandidatePool.fetch(pool, left_id)
    right = CandidatePool.fetch(pool, right_id)

    unless MapSet.member?(left.ancestors, right_id) or MapSet.member?(right.ancestors, left_id) do
      left_text = instructions(left.program)
      right_text = instructions(right.program)

      left.ancestors
      |> MapSet.intersection(right.ancestors)
      |> Enum.sort(:desc)
      |> Enum.find_value(fn ancestor_id ->
        key = {left_id, right_id, ancestor_id}
        ancestor = CandidatePool.fetch(pool, ancestor_id)

        if not MapSet.member?(attempted, key) and ancestor.mean <= min(left.mean, right.mean) do
          with {:ok, program, random} <-
                 combine(ancestor.program, left_text, right_text, left.mean, right.mean, random) do
            unless CandidatePool.known?(pool, program) do
              %{key: key, program: program, parents: [left_id, right_id], random: random}
            end
          else
            :skip -> nil
          end
        end
      end)
    end
  end

  defp combine(ancestor, left, right, left_mean, right_mean, random) do
    slots = PredictorSlots.list(ancestor)

    {changes, {random, compatible?}} =
      Enum.map_reduce(slots, {random, false}, fn {path, predictor}, {random, compatible?} ->
        previous = predictor.signature.instructions
        first = Map.fetch!(left, path)
        second = Map.fetch!(right, path)

        {value, random, unilateral?} =
          combine_instruction(previous, first, second, left_mean, right_mean, random)

        {{path, value}, {random, compatible? or unilateral?}}
      end)

    merged = Map.new(changes)

    if compatible? and merged != left and merged != right do
      program =
        PredictorSlots.map(ancestor, fn path, predictor ->
          %{
            predictor
            | signature: %{predictor.signature | instructions: Map.fetch!(merged, path)}
          }
        end)

      {:ok, program, random}
    else
      :skip
    end
  end

  defp combine_instruction(previous, left, right, left_mean, right_mean, random) do
    cond do
      left == right ->
        {left, random, false}

      left == previous ->
        {right, random, true}

      right == previous ->
        {left, random, true}

      left_mean > right_mean ->
        {left, random, false}

      right_mean > left_mean ->
        {right, random, false}

      true ->
        {random, value} = Random.choice(random, [left, right])
        {value, random, false}
    end
  end

  def validation_sample(random, left, right) do
    ids = Enum.to_list(0..(tuple_size(left) - 1))

    if length(ids) <= @sample_size do
      {random, ids}
    else
      buckets = Enum.group_by(ids, &preference(elem(left, &1), elem(right, &1)))

      {random, selected} =
        Enum.reduce([:left, :right, :tie], {random, []}, fn bucket, {random, selected} ->
          rows = Map.get(buckets, bucket, [])
          count = min(2, min(length(rows), @sample_size - length(selected)))
          {random, sample} = Random.sample(random, rows, count)
          {random, selected ++ sample}
        end)

      unused = ids -- selected
      {random, rest} = Random.sample(random, unused, @sample_size - length(selected))
      {random, selected ++ rest}
    end
  end

  defp preference(left, right) when left > right, do: :left
  defp preference(left, right) when right > left, do: :right
  defp preference(_left, _right), do: :tie

  defp instructions(program) do
    program
    |> PredictorSlots.list()
    |> Map.new(fn {path, predictor} ->
      {path, predictor.signature.instructions}
    end)
  end
end
