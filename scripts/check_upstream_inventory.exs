# Usage: mix run --no-start scripts/check_upstream_inventory.exs

defmodule Dspy.UpstreamInventoryCheck do
  alias NimbleCSV.RFC4180

  @columns ~w(id symbol kind status decision elixir_reference)
  @statuses ~w(done approved_elixir_equivalent partial missing unverified approved_exclusion)

  def run do
    root = git!(["rev-parse", "--show-toplevel"]) |> String.trim()
    directory = Path.join(root, "plan/current")

    pin =
      Path.join(directory, "UPSTREAM_PIN")
      |> File.stream!()
      |> Map.new(fn line ->
        [key, value] = line |> String.trim() |> String.split("=", parts: 2)
        {key, value}
      end)

    commit = Map.fetch!(pin, "elixir_commit")

    files =
      git!(["ls-tree", "-r", "--name-only", "-z", commit]) |> String.split(<<0>>) |> MapSet.new()

    [@columns | rows] =
      Path.join(directory, "UPSTREAM_INVENTORY.csv")
      |> File.read!()
      |> RFC4180.parse_string(skip_headers: false)

    if rows == [], do: raise("Inventory is empty")

    rows
    |> Enum.with_index(2)
    |> Enum.each(fn
      {[id, symbol, kind, status, decision, path], line} ->
        unless Regex.match?(~r/^[NSU][0-9]{3}$/, id) and
                 Enum.all?([symbol, kind, decision], &(&1 != "")) and
                 status in @statuses and
                 (path == "" or MapSet.member?(files, path)) do
          raise "Invalid inventory row #{line} (#{id}) for Elixir #{commit}"
        end

      {_row, line} ->
        raise "Expected six columns on inventory row #{line}"
    end)

    for index <- [0, 1] do
      Enum.each(Enum.frequencies_by(rows, &Enum.at(&1, index)), fn
        {value, count} when count > 1 -> raise "Duplicate inventory key: #{value}"
        _unique -> :ok
      end)
    end

    IO.puts("DSPy #{Map.fetch!(pin, "tag")} (#{Map.fetch!(pin, "commit")})")
    IO.puts("Elixir #{commit}")
    IO.puts("Inventory rows: #{length(rows)}")
    counts = Enum.frequencies_by(rows, &Enum.at(&1, 3))
    Enum.each(@statuses, &IO.puts("#{&1}: #{Map.get(counts, &1, 0)}"))
  end

  defp git!(args) do
    case System.cmd("git", args) do
      {output, 0} -> output
      {_output, status} -> raise "Git exited with status #{status} for #{inspect(args)}"
    end
  end
end

Dspy.UpstreamInventoryCheck.run()
