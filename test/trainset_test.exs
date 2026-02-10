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

  defp labeled_dataset do
    [
      Example.new(%{id: 1, question: "q1", answer: "A"}),
      Example.new(%{id: 2, question: "q2", answer: "A"}),
      Example.new(%{id: 3, question: "q3", answer: "B"}),
      Example.new(%{id: 4, question: "q4", answer: "B"}),
      Example.new(%{id: 5, question: "q5", answer: "C"})
    ]
  end

  test "sample/3 with :balanced is deterministic with a seed" do
    data = labeled_dataset()

    sample1 = Trainset.sample(data, 4, strategy: :balanced, seed: 123, balance_field: :answer)
    sample2 = Trainset.sample(data, 4, strategy: :balanced, seed: 123, balance_field: :answer)

    assert sample1 == sample2

    counts =
      sample1
      |> Enum.map(& &1.attrs.answer)
      |> Enum.frequencies()

    assert counts["A"] == 2
    assert counts["B"] == 1
    assert counts["C"] == 1
  end

  test "sample/3 with :diverse is deterministic with a seed" do
    data = dataset(10)

    sample1 = Trainset.sample(data, 4, strategy: :diverse, seed: 999)
    sample2 = Trainset.sample(data, 4, strategy: :diverse, seed: 999)

    assert sample1 == sample2
    assert length(sample1) == 4
  end

  test "sample/3 with :hard selects highest difficulty" do
    data = [
      Example.new(%{id: 1, question: "q1", answer: "a1", difficulty: 0.1}),
      Example.new(%{id: 2, question: "q2", answer: "a2", difficulty: 0.9}),
      Example.new(%{id: 3, question: "q3", answer: "a3", difficulty: 0.5})
    ]

    sample = Trainset.sample(data, 2, strategy: :hard, seed: 123, difficulty_field: :difficulty)

    assert Enum.map(sample, & &1.attrs.id) == [2, 3]
  end

  test "sample/3 with :uncertainty selects highest uncertainty" do
    data = [
      Example.new(%{id: 1, question: "q1", answer: "a1", uncertainty: 0.1}),
      Example.new(%{id: 2, question: "q2", answer: "a2", uncertainty: 0.9}),
      Example.new(%{id: 3, question: "q3", answer: "a3", uncertainty: 0.5})
    ]

    sample =
      Trainset.sample(data, 2, strategy: :uncertainty, seed: 123, uncertainty_field: :uncertainty)

    assert Enum.map(sample, & &1.attrs.id) == [2, 3]
  end

  test "bootstrap_sample/3 is deterministic with a seed" do
    data = dataset(5)

    sample1 = Trainset.bootstrap_sample(data, 6, seed: 42)
    sample2 = Trainset.bootstrap_sample(data, 6, seed: 42)

    assert sample1 == sample2
    assert length(sample1) == 6
  end
end
