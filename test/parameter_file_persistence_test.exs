defmodule DspyParameterFilePersistenceTest do
  use ExUnit.Case, async: true

  alias Dspy.Parameter

  defp tmp_path(basename) do
    Path.join(
      System.tmp_dir!(),
      "dspy_#{basename}_#{System.unique_integer([:positive, :monotonic])}.json"
    )
  end

  test "write_json/2 + read_json/1 roundtrip a parameter list" do
    params = [Parameter.new("x", :prompt, "y")]
    path = tmp_path("params")

    assert :ok = Parameter.write_json(params, path)
    assert {:ok, params2} = Parameter.read_json(path)

    assert [%Parameter{name: "x", type: :prompt, value: "y"}] = params2

    # best-effort cleanup
    _ = File.rm(path)
  end

  test "read_json/1 returns a structured error for missing file" do
    path = tmp_path("missing")

    assert {:error, {:file_read_failed, ^path, :enoent}} = Parameter.read_json(path)
  end

  test "write_json/2 bubbles encode errors (unsupported value)" do
    path = tmp_path("bad")
    params = [Parameter.new("x", :custom, self())]

    assert {:error, {:unsupported_value, _pid}} = Parameter.write_json(params, path)
  end
end
