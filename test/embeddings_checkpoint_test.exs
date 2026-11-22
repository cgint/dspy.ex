defmodule Dspy.EmbeddingsCheckpointTest do
  use ExUnit.Case, async: true

  alias Dspy.{Embedder, Embeddings, Prediction}

  @fixture Path.join(__DIR__, "fixtures/embeddings_checkpoint_roundtrip.exs")

  @tag :tmp_dir
  test "a new BEAM restores prepared vectors and scores with a query-only embedder", %{
    tmp_dir: dir
  } do
    run_fixture!("write", dir)
    run_fixture!("read", dir)

    assert File.read!(Path.join(dir, "read.etf")) == File.read!(Path.join(dir, "write.etf"))
    refute File.read!(Path.join(dir, "checkpoint.json")) =~ "private-embedding-key"
  end

  @tag :tmp_dir
  test "preserves raw vectors, corpus positions and the result limit", %{tmp_dir: dir} do
    path = Path.join(dir, "index.json")

    writer =
      Embedder.new(fn ["two", "three", "three"] ->
        [[2], [3], [3]]
      end)

    assert {:ok, index} =
             Embeddings.new(["two", "three", "three"], writer, k: 2, normalize: false)

    assert :ok = Embeddings.save(index, path)
    assert {:ok, restored} = Embeddings.from_saved(path, query_only())
    assert {:ok, prediction} = Embeddings.query_with_scores(restored, "query")

    assert Prediction.to_map(prediction) === %{
             passages: ["three", "three"],
             indices: [1, 2],
             scores: [6, 6]
           }

    mismatch = Embedder.new(fn ["query"] -> [[1, 2]] end)
    assert {:ok, restored} = Embeddings.from_saved(path, mismatch)

    assert Embeddings.query_with_scores(restored, "query") ==
             {:error, {:embedding_dimension_mismatch, expected: 1, got: 2}}
  end

  @tag :tmp_dir
  test "rejects malformed checkpoint envelopes and rows before binding an index", %{tmp_dir: dir} do
    path = Path.join(dir, "index.json")
    valid = document()

    File.write!(path, Jason.encode!(valid))
    assert {:ok, index} = Embeddings.from_saved(path, query_only())
    assert {:ok, prediction} = Embeddings.query_with_scores(index, "query")
    assert Prediction.to_map(prediction) === %{passages: ["a"], indices: [0], scores: [1.0]}

    for invalid <- [
          [],
          Map.delete(valid, "k"),
          Map.put(valid, "embedder", "foreign"),
          %{valid | "version" => 1.0},
          %{valid | "k" => -1},
          %{valid | "k" => 1.0},
          %{valid | "normalize" => "false"},
          %{valid | "dimension" => 0},
          %{valid | "dimension" => 1.0},
          %{valid | "dimension" => 2},
          %{valid | "rows" => []},
          %{valid | "rows" => [%{"passage" => "a", "vector" => [1]}]},
          %{valid | "rows" => [[nil, [1]]]},
          %{valid | "rows" => [["a", [1], []]]},
          %{valid | "rows" => [["a", []]]},
          %{valid | "rows" => [["a", ["private-embedding-value"]]]},
          %{valid | "rows" => [["a", [1]], ["b", [1, 2]]]}
        ] do
      File.write!(path, Jason.encode!(invalid))
      assert {:error, :invalid_checkpoint} = Embeddings.from_saved(path, query_only())
    end

    # A normal map decode would keep the last k and accept this file.
    <<"{", members::binary>> = Jason.encode!(valid)
    File.write!(path, "{" <> ~s("k":99,) <> members)
    assert {:error, :invalid_checkpoint} = Embeddings.from_saved(path, query_only())

    File.write!(path, ~s({"rows": "private-embedding-value"))
    assert {:error, :invalid_json} = Embeddings.from_saved(path, query_only())
  end

  @tag :tmp_dir
  test "reports unsupported format and integer version", %{tmp_dir: dir} do
    path = Path.join(dir, "index.json")
    valid = document()

    File.write!(path, Jason.encode!(%{valid | "format" => "foreign-format"}))
    assert {:error, :unsupported_checkpoint_format} = Embeddings.from_saved(path, query_only())

    File.write!(path, Jason.encode!(%{valid | "version" => 2}))

    assert {:error, {:unsupported_checkpoint_version, 2}} =
             Embeddings.from_saved(path, query_only())
  end

  @tag :tmp_dir
  test "failed saves preserve existing data and clean up temporary files", %{tmp_dir: dir} do
    path = Path.join(dir, "index.json")
    File.write!(path, "existing checkpoint")

    malformed_passage = <<255>>
    embedder = Embedder.new(fn [_] -> [[1]] end)
    assert {:ok, invalid} = Embeddings.new([malformed_passage], embedder)
    assert {:error, :invalid_checkpoint} = Embeddings.save(invalid, path)
    assert File.read!(path) == "existing checkpoint"
    assert File.ls!(dir) == ["index.json"]

    destination = Path.join(dir, "directory")
    File.mkdir!(destination)
    marker = Path.join(destination, "keep")
    File.write!(marker, "existing file")
    assert {:ok, index} = Embeddings.new(["a"], embedder)
    assert {:error, {:file_error, :rename, _reason}} = Embeddings.save(index, destination)
    assert File.read!(marker) == "existing file"
    assert Enum.sort(File.ls!(dir)) == ["directory", "index.json"]

    assert :ok = Embeddings.save(index, path)
    assert {:ok, _index} = Embeddings.from_saved(path, query_only())
    assert Enum.sort(File.ls!(dir)) == ["directory", "index.json"]
  end

  @tag :tmp_dir
  test "reports unusable paths and missing files without leaking path contents", %{tmp_dir: dir} do
    missing = Path.join([dir, "missing", "index.json"])
    assert {:error, {:file_error, :read, :enoent}} = Embeddings.from_saved(missing, query_only())
    assert {:error, {:file_error, :read, :badarg}} = Embeddings.from_saved(:path, query_only())
    assert {:error, :invalid_embedder} = Embeddings.from_saved(missing, :embedder)

    embedder = Embedder.new(fn ["a"] -> [[1]] end)
    assert {:ok, index} = Embeddings.new(["a"], embedder)
    assert {:error, {:file_error, :write, :enoent}} = Embeddings.save(index, missing)
    assert {:error, {:file_error, :write, :badarg}} = Embeddings.save(index, :path)
    assert File.ls!(dir) == []
  end

  defp query_only do
    Embedder.new(fn ["query"] -> [[2]] end)
  end

  defp document do
    %{
      "format" => "dspy.embeddings",
      "version" => 1,
      "k" => 5,
      "normalize" => true,
      "dimension" => 1,
      "rows" => [["a", [1]]]
    }
  end

  defp run_fixture!(mode, dir) do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", Path.expand(&1)])

    elixir = System.find_executable("elixir")
    assert elixir, "a child Elixir executable must be on PATH"

    args = ["--erl", "+S 2:2 +SDcpu 1 +SDio 1"] ++ code_paths ++ [@fixture, mode]
    {output, status} = System.cmd(elixir, args, cd: dir, stderr_to_stdout: true)
    assert status == 0, "corpus checkpoint fixture failed in #{mode} mode:\n#{output}"
  end
end
