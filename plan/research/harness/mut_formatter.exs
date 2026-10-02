defmodule MutFormatter do
  @moduledoc false
  # JSON test-report formatter for the H20-C2 mutation library (contract A3).
  #
  # ExUnit starts this formatter itself with
  # `GenServer.start_link(MutFormatter, config)`, so `init/1` receives the
  # ExUnit config keyword list. The report path comes from the
  # `DSPY_MUT_REPORT` environment variable.
  #
  # Writes one JSON record per test to that path, plus a final
  # `{"suite_finished": true}` line. A missing or truncated final line
  # means the run is INVALID (checked by `mutlib.py`).
  #
  # State shapes (verified 2026-10-02, Elixir 1.20.4 / OTP 29):
  #   passed  -> %ExUnit.Test{state: nil, ...}
  #   failed  -> %ExUnit.Test{state: {:failed, [{kind, reason, stack} | _]}, ...}
  #              kind is :assert (assertion) or :error (exception raised)
  #   skipped -> %ExUnit.Test{state: {:skipped, reason}, ...}
  #   invalid -> %ExUnit.Test{state: {:invalid, %ExUnit.TestModule{}}, ...}

  use GenServer

  @impl true
  def init(_config) do
    path =
      case System.get_env("DSPY_MUT_REPORT") do
        nil ->
          # Not active; stay a silent no-op (test_helper only configures us
          # when the variable is set, so this should not happen).
          raise RuntimeError, "MutFormatter: DSPY_MUT_REPORT is not set"

        path ->
          File.write!(path, "")
          path
      end

    {:ok, %{path: path}}
  end

  @impl true
  def handle_cast({:suite_finished, _times_us}, state) do
    emit(state, %{"suite_finished" => true})
    {:noreply, state}
  end

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    emit(state, record(test))
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  # -- helpers --------------------------------------------------------------

  defp record(%ExUnit.Test{} = test) do
    %{
      "name" => test.name,
      "module" => module_name(test.module),
      "file" => Map.get(test.tags, :file),
      "state" => state_name(test.state),
      "error" => error_of(test.state)
    }
  end

  defp state_name(nil), do: "passed"
  defp state_name({:failed, _}), do: "failed"
  defp state_name({:skipped, _}), do: "skipped"
  defp state_name({:invalid, _}), do: "invalid"
  defp state_name({:excluded, _}), do: "excluded"
  defp state_name(other), do: inspect(other)

  defp error_of(nil), do: nil
  defp error_of({:skipped, _}), do: nil
  defp error_of({:invalid, _}), do: nil
  defp error_of({:excluded, _}), do: nil

  defp error_of({:failed, [head | _]}) when is_tuple(head) do
    case head do
      {:assertion, _reason, _stack, _data} -> "ExUnit.AssertionError"
      {:error, exception, _stack} -> exception_name(exception)
      other -> inspect(other)
    end
  end

  defp error_of({:failed, _}), do: "ExUnit.Error"

  defp exception_name(exception) when is_exception(exception),
    do: module_name(exception.__struct__)

  defp exception_name(other), do: inspect(other)

  defp module_name(nil), do: nil
  defp module_name(m) when is_atom(m), do: Atom.to_string(m)
  defp module_name(m), do: inspect(m)

  defp emit(state, map) do
    line =
      map
      |> Enum.map(fn {k, v} -> {k, encode(v)} end)
      |> Enum.map_join(",", fn {k, v} -> "\"#{k}\":#{v}" end)
      |> then(&("{#{&1}}\n"))

    File.write!(state.path, line, [:append])
  end

  defp encode(nil), do: "null"
  defp encode(v) when is_binary(v), do: encode_string(v)
  defp encode(v) when is_atom(v), do: encode_string(Atom.to_string(v))
  defp encode(v) when is_boolean(v) do
    if v, do: "true", else: "false"
  end

  defp encode(v) when is_number(v), do: to_string(v)
  defp encode(v), do: encode_string(inspect(v))

  defp encode_string(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
    |> then(&("\"" <> &1 <> "\""))
  end
end
