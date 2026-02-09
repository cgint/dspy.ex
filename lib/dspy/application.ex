defmodule Dspy.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {Dspy.Settings, []}
    ]

    opts = [strategy: :one_for_one, name: Dspy.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      maybe_configure_language_model()
      {:ok, pid}
    end
  end

  defp maybe_configure_language_model do
    case Application.get_env(:dspy, :lm) do
      %{module: module, api_key: api_key, model: model} = config ->
        lm = module.new(api_key: api_key, model: model)

        :ok =
          Dspy.Settings.configure(
            lm: lm,
            max_tokens: Map.get(config, :max_tokens),
            temperature: Map.get(config, :temperature)
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
