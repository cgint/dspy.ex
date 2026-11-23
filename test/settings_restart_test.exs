defmodule Dspy.SettingsRestartTest do
  use ExUnit.Case, async: false

  defmodule BootLM do
    def new(opts), do: {:boot_lm, opts}
  end

  test "supervised restart reloads application defaults" do
    old_lm = Application.fetch_env(:dspy, :lm)
    old_adapter = Application.fetch_env(:dspy, :adapter)
    old_settings = Dspy.Settings.get()

    on_exit(fn ->
      for {key, value} <- [lm: old_lm, adapter: old_adapter] do
        case value do
          {:ok, value} -> Application.put_env(:dspy, key, value)
          :error -> Application.delete_env(:dspy, key)
        end
      end

      Dspy.Settings.configure(Map.to_list(Map.from_struct(old_settings)))
    end)

    Application.put_env(:dspy, :lm, %{
      module: BootLM,
      api_key: "key",
      model: "model",
      temperature: 0.3
    })

    Application.put_env(:dspy, :adapter, BootLM)
    old_pid = Process.whereis(Dspy.Settings)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}
    assert pid = eventually_restarted(old_pid, 100)
    :sys.get_state(pid)

    assert %Dspy.Settings{
             lm: {:boot_lm, [api_key: "key", model: "model"]},
             adapter: BootLM,
             temperature: 0.3
           } = Dspy.Settings.get()
  end

  defp eventually_restarted(_, 0), do: false

  defp eventually_restarted(old, attempts) do
    case Process.whereis(Dspy.Settings) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        Process.sleep(10)
        eventually_restarted(old, attempts - 1)
    end
  end
end
