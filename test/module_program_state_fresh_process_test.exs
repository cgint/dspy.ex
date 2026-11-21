defmodule Dspy.ModuleProgramStateFreshProcessTest do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "fixtures/program_state_roundtrip.exs")

  @tag :tmp_dir
  test "a new BEAM can resume a BootstrapRS program with caller-provided LMs", %{tmp_dir: dir} do
    run_fixture!("write", dir)
    run_fixture!("read", dir)

    assert File.read!(Path.join(dir, "read.etf")) == File.read!(Path.join(dir, "write.etf"))
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
    assert status == 0, "program checkpoint fixture failed in #{mode} mode:\n#{output}"
  end
end
