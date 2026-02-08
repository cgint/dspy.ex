defmodule Dspy.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Library-first: start only the minimal core services by default.
    # Optional/web/experimental services are gated behind config so `mix test`
    # (and normal library usage) stays quiet and deterministic.
    ensure_optional_apps_started_if_enabled()

    children =
      [
        {Dspy.Settings, []}
      ] ++ optional_children()

    opts = [strategy: :one_for_one, name: Dspy.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      maybe_configure_language_model()
      {:ok, pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    if optional_services_enabled?() and is_pid(Process.whereis(DspyWeb.Endpoint)) do
      DspyWeb.Endpoint.config_change(changed, removed)
    end

    :ok
  end

  defp optional_children do
    if optional_services_enabled?() do
      [
        # Phoenix PubSub
        {Phoenix.PubSub, name: Dspy.PubSub},

        # Multi-agent / experimental services
        {Registry, keys: :unique, name: Dspy.MultiAgentChat.Registry},
        {Dspy.MultiAgentLogger, []},

        # Godmode services
        {Dspy.GodmodeCoordinator, []},
        {Dspy.RealtimeMonitor, []},

        # Phoenix Endpoint
        DspyWeb.Endpoint
      ]
    else
      []
    end
  end

  defp optional_services_enabled? do
    Application.get_env(:dspy, :start_optional_services, false) == true
  end

  defp ensure_optional_apps_started_if_enabled do
    if optional_services_enabled?() do
      # Optional services may use `:os_mon` (system monitoring).
      # Keep it out of the default startup to avoid noisy logs in library/test usage.
      case Application.ensure_all_started(:os_mon) do
        {:ok, _apps} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Optional services are enabled, but failed to start :os_mon: #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp maybe_configure_language_model do
    case Application.get_env(:dspy, :lm) do
      %{module: module, api_key: api_key, model: model} = config ->
        lm = module.new(api_key: api_key, model: model)

        :ok =
          Dspy.Settings.configure(
            lm: lm,
            max_tokens: Map.get(config, :max_tokens, 2048),
            temperature: Map.get(config, :temperature, 0.0)
          )

        Logger.info("DSPy LM configured: #{model}")

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.error("Failed to configure LM:\n" <> Exception.format(:error, error, __STACKTRACE__))
  end
end
