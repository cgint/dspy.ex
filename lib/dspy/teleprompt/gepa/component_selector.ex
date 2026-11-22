defmodule Dspy.Teleprompt.GEPA.ComponentSelector do
  @moduledoc false

  alias Dspy.Module.PredictorSlots
  alias Dspy.Prediction
  alias Dspy.Signature.PromptPreview

  @observation_bytes 16_384

  def select(_selector, [], _parent, _parent_id), do: {:ok, []}

  def select(selector, eligible, parent, parent_id) do
    slots = parent |> PredictorSlots.list() |> Map.new()

    snapshot = %{
      parent_id: parent_id,
      candidate:
        Map.new(slots, fn {path, predictor} -> {path, predictor.signature.instructions || ""} end),
      eligible_paths: Enum.map(eligible, &elem(&1, 0)),
      observations:
        Map.new(eligible, fn {path, steps} ->
          {path, preview_observations(Map.fetch!(slots, path).signature, steps)}
        end)
    }

    with {:ok, paths} <- invoke(selector, snapshot), do: validate(paths, eligible)
  end

  defp invoke(selector, snapshot) do
    {:ok, selector.(snapshot)}
  rescue
    _error -> selection_error(:selector_raised)
  end

  defp validate([], _eligible), do: :skip

  defp validate(paths, eligible) when is_integer(length(paths)) do
    steps_by_path = Map.new(eligible)

    cond do
      MapSet.size(MapSet.new(paths)) != length(paths) ->
        selection_error(:duplicate_path)

      not Enum.all?(paths, &Map.has_key?(steps_by_path, &1)) ->
        selection_error(:unobserved_path)

      true ->
        {:ok, Enum.map(paths, &{&1, Map.fetch!(steps_by_path, &1)})}
    end
  end

  defp validate(_paths, _eligible), do: selection_error(:invalid_selection)

  defp selection_error(reason), do: {:error, {:component_selection_failed, reason}}

  defp preview_observations(signature, steps) do
    {items, _bytes} =
      Enum.reduce_while(steps, {[], 2}, fn {record, step}, {acc, bytes} ->
        {outputs, status} = preview_outputs(signature, step)

        item = %{
          example_index: record.example_index,
          score: record.score,
          inputs: PromptPreview.project(signature.input_fields, step.inputs),
          outputs: outputs,
          status: status
        }

        bytes = bytes + byte_size(Jason.encode!(item)) + if(acc == [], do: 0, else: 1)

        if bytes <= @observation_bytes,
          do: {:cont, {[item | acc], bytes}},
          else: {:halt, {acc, bytes}}
      end)

    Enum.reverse(items)
  end

  defp preview_outputs(signature, %{prediction: %Prediction{attrs: attrs}}) do
    {PromptPreview.project(signature.output_fields, attrs), :ok}
  end

  defp preview_outputs(_signature, %{error: {:output_parse_failed, _reason, _details}}),
    do: {%{}, :output_parse_failed}
end
