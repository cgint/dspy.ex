defmodule Dspy.PredictorConfig do
  @moduledoc false

  @keys [:temperature, :max_tokens, :max_completion_tokens, :rollout_id]

  @type t :: %{
          optional(:temperature) => number() | nil,
          optional(:max_tokens) => pos_integer() | nil,
          optional(:max_completion_tokens) => pos_integer() | nil,
          optional(:rollout_id) => integer() | nil
        }

  def new!(config), do: config |> normalize!() |> drop_nil_request_fields()

  def get(predictor) do
    case Map.get(predictor, :config) do
      nil -> %{}
      config -> config
    end
  end

  def update(predictor, config) do
    config = predictor |> get() |> Map.merge(normalize!(config)) |> new!()
    Map.put(predictor, :config, config)
  end

  def execution_options(config) do
    {cache, request} = config |> new!() |> Map.split([:rollout_id])
    {request, Map.to_list(cache)}
  end

  def set_rollout(program, rollout_id) do
    Dspy.Module.map_named_predictors(
      program,
      &update(&1, temperature: 1.0, rollout_id: rollout_id)
    )
  end

  defp normalize!(config) when is_map(config) and not is_struct(config) do
    Enum.each(config, fn {key, value} -> validate!(key, value) end)
    config
  end

  defp normalize!(config) when is_list(config) do
    if Keyword.keyword?(config), do: normalize!(Map.new(config)), else: invalid_config!()
  end

  defp normalize!(_config), do: invalid_config!()

  defp drop_nil_request_fields(config) do
    Map.reject(config, fn {key, value} -> key != :rollout_id and is_nil(value) end)
  end

  defp validate!(key, nil) when key in @keys, do: :ok

  defp validate!(:temperature, value) when is_number(value), do: :ok

  defp validate!(key, value)
       when key in [:max_tokens, :max_completion_tokens] and is_integer(value) and value > 0,
       do: :ok

  defp validate!(:rollout_id, value) when is_integer(value), do: :ok
  defp validate!(_key, _value), do: invalid_config!()

  defp invalid_config! do
    raise ArgumentError,
          "invalid predictor config. Expected a map or keyword list of temperature, token limits, or rollout_id"
  end
end
