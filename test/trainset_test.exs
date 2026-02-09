defmodule DspyTrainsetTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Trainset}

  defp dataset(n) do
    Enum.map(1..n, fn id ->
      Example.new(%{id: id, question: "q#{id}", answer: "a#{id}"})
    end)
  end

  test "split/2 is deterministic with shuffle + seed" do
    data = dataset(10)

    {train1, val1, test1} =
      Trainset.split(data,
        train: 0.5,
        val: 0.3,
        test: 0.2,
        shuffle: true,
        seed: 123
      )

    {train2, val2, test2} =
      Trainset.split(data,
        train: 0.5,
        val: 0.3,
        test: 0.2,
        shuffle: true,
        seed: 123
      )

    assert {train1, val1, test1} == {train2, val2, test2}

    assert length(train1) == 5
    assert length(val1) == 3
    assert length(test1) == 2

    ids = data |> Enum.map(& &1.attrs.id) |> MapSet.new()

    split_ids =
      (train1 ++ val1 ++ test1)
      |> Enum.map(& &1.attrs.id)
      |> MapSet.new()

    assert split_ids == ids
  end

  test "split/2 with shuffle: false preserves order" do
    data = dataset(10)

    {train, val, test} = Trainset.split(data, train: 0.6, val: 0.2, test: 0.2, shuffle: false)

    assert Enum.map(train, & &1.attrs.id) == Enum.to_list(1..6)
    assert Enum.map(val, & &1.attrs.id) == Enum.to_list(7..8)
    assert Enum.map(test, & &1.attrs.id) == Enum.to_list(9..10)
  end

  test "sample/3 is deterministic with a seed" do
    data = dataset(10)

    sample1 = Trainset.sample(data, 3, strategy: :random, seed: 456)
    sample2 = Trainset.sample(data, 3, strategy: :random, seed: 456)

    assert sample1 == sample2
    assert length(sample1) == 3

    data_set = MapSet.new(data)
    assert Enum.all?(sample1, &MapSet.member?(data_set, &1))
  end
end
