defmodule Dspy.ProgramStream.Composite do
  @moduledoc false

  alias Dspy.{Prediction, ProgramStream}
  alias Dspy.Module.PredictorSlots
  alias Dspy.Signature.AdapterPipeline
  alias Dspy.Signature.Adapters.{ChatAdapter, ChatStream}

  @slot_key {__MODULE__, :slot}
  @scope_key {__MODULE__, :scope}

  def select(program, selectors) do
    slots = PredictorSlots.list(program)
    resolve_selectors(selectors, slots)
  end

  defp resolve_selectors([], _slots), do: :raw

  defp resolve_selectors(selectors, slots) when is_integer(length(selectors)) do
    named_slots =
      Enum.map(slots, fn {path, predictor} ->
        {path, PredictorSlots.name(path, predictor), predictor.signature.output_fields}
      end)

    Enum.reduce(selectors, %{}, fn selector, selections ->
      {path, name, outputs, field} = resolve_selector(selector, named_slots)
      ProgramStream.validate_chat_fields!(outputs, [field])

      Map.update(selections, path, {name, [field]}, fn {name, fields} ->
        if field in fields do
          raise ArgumentError, "stream_listeners cannot contain duplicate slot fields"
        end

        {name, [field | fields]}
      end)
    end)
  end

  defp resolve_selectors(_selectors, _slots) do
    raise ArgumentError,
          "stream_listeners must be a list of field atoms or {predict_name, field} pairs"
  end

  defp resolve_selector(field, slots) when is_atom(field) do
    slots
    |> Enum.filter(fn {_path, _name, outputs} -> Enum.any?(outputs, &(&1.name == field)) end)
    |> resolve_match(field, field)
  end

  defp resolve_selector({name, field} = selector, slots)
       when is_binary(name) and is_atom(field) do
    slots
    |> Enum.filter(fn {_path, slot_name, _outputs} -> slot_name == name end)
    |> resolve_match(field, selector)
  end

  defp resolve_selector(selector, _slots) do
    raise ArgumentError, "invalid stream_listeners selector #{inspect(selector)}"
  end

  defp resolve_match([{path, name, outputs}], field, _selector), do: {path, name, outputs, field}

  defp resolve_match([], _field, selector) do
    raise ArgumentError, "stream_listeners selector #{inspect(selector)} matched no predictor"
  end

  defp resolve_match(_slots, _field, selector) do
    raise ArgumentError, "stream_listeners selector #{inspect(selector)} is ambiguous"
  end

  def with_listeners(program, selections, publish, run) do
    owner = self()
    scope = make_ref()

    program =
      PredictorSlots.map(program, fn path, predictor ->
        case selection(selections, path) do
          nil -> predictor
          selected -> Map.put(predictor, @slot_key, {owner, scope, selected})
        end
      end)

    Process.put(@scope_key, {scope, publish})

    try do
      run.(program)
    after
      Process.delete(@scope_key)
    end
  end

  defp selection(:raw, _path), do: :raw
  defp selection(selections, path), do: Map.get(selections, path)

  def forward(%module{} = predictor, inputs) do
    case Map.get(predictor, @slot_key) do
      nil -> module.forward(predictor, inputs, nil)
      binding -> forward_selected(module, predictor, inputs, binding)
    end
  end

  defp forward_selected(module, predictor, inputs, {owner, scope, selected})
       when owner == self() do
    case Process.get(@scope_key) do
      {^scope, publish} -> stream_selected(module, predictor, inputs, selected, publish)
      _expired -> module.forward(predictor, inputs, nil)
    end
  end

  defp forward_selected(module, predictor, inputs, {owner, _scope, _selected}) do
    if node(owner) == node() and not Process.alive?(owner) do
      module.forward(predictor, inputs, nil)
    else
      {:error, :stream_predictor_outside_owner}
    end
  end

  defp stream_selected(module, predictor, inputs, :raw, publish) do
    stream_invocation(module, predictor, inputs, :raw, publish)
  end

  defp stream_selected(module, predictor, inputs, {name, fields}, publish) do
    case AdapterPipeline.active_adapter(adapter: predictor.adapter) do
      ChatAdapter ->
        selection = {name, ChatStream.new(fields)}
        stream_invocation(module, %{predictor | adapter: ChatAdapter}, inputs, selection, publish)

      adapter ->
        {:error, {:unsupported_streaming_adapter, adapter}}
    end
  end

  defp stream_invocation(module, predictor, inputs, state, publish) do
    # Each call owns its callback and scanner, including reentrant calls.
    key = {__MODULE__, make_ref()}
    Process.put(key, state)
    on_delta = ProgramStream.delta_callback(&emit_delta(key, &1, publish))

    try do
      result = module.forward(predictor, inputs, on_delta)

      if match?({:ok, %Prediction{}}, result) do
        finish_fields(Process.get(key), publish)
      end

      result
    after
      Process.delete(key)
    end
  end

  defp emit_delta(key, text, publish) do
    case Process.get(key) do
      nil ->
        {:error, :expired_stream_delta}

      :raw ->
        publish.({:delta, text})

      {name, scanner} ->
        {fragments, scanner} = ChatStream.push(scanner, text)
        Process.put(key, {name, scanner})
        Enum.each(ProgramStream.field_events(fragments, name), publish)
    end
  end

  defp finish_fields(:raw, _publish), do: :ok

  defp finish_fields({name, scanner}, publish) do
    Enum.each(ProgramStream.field_events(ChatStream.finish(scanner), name), publish)
  end
end
