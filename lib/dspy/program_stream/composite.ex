defmodule Dspy.ProgramStream.Composite do
  @moduledoc false

  alias Dspy.{Prediction, ProcessOwnership, ProgramStream}
  alias Dspy.Module.PredictorSlots

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
      ProgramStream.validate_fields!(outputs, [field])

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

    with_scope({owner, scope, publish}, fn -> run.(program) end)
  end

  def capture_scope, do: Process.get(@scope_key)

  def with_worker_scope(nil, _owner, run), do: run.()

  def with_worker_scope(scope, owner, run) do
    # A trapping task can outlive its linked owner.
    ProcessOwnership.watch(owner, self(), :kill)
    with_scope(scope, run)
  end

  def active_publisher?(owner, publish) do
    match?({^owner, _scope, ^publish}, capture_scope())
  end

  defp with_scope(scope, run) do
    previous = Process.put(@scope_key, scope)

    try do
      run.()
    after
      if previous, do: Process.put(@scope_key, previous), else: Process.delete(@scope_key)
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

  defp forward_selected(module, predictor, inputs, {owner, scope, selected}) do
    case capture_scope() do
      {^owner, ^scope, publish} ->
        stream_selected(module, predictor, inputs, selected, publish, owner)

      _expired ->
        if owner == self() or (node(owner) == node() and not Process.alive?(owner)) do
          module.forward(predictor, inputs, nil)
        else
          {:error, :stream_predictor_outside_owner}
        end
    end
  end

  defp stream_selected(module, predictor, inputs, :raw, publish, owner) do
    stream_invocation(module, predictor, inputs, :raw, publish, owner)
  end

  defp stream_selected(module, predictor, inputs, {name, fields}, publish, owner) do
    with {:ok, predictor, scanner} <- ProgramStream.open_field_listener(predictor, fields) do
      stream_invocation(module, predictor, inputs, {name, scanner}, publish, owner)
    end
  end

  defp stream_invocation(module, predictor, inputs, state, publish, owner) do
    # Each call owns its callback and scanner, including reentrant calls.
    ref = make_ref()
    key = {__MODULE__, ref}
    invocation_id = if owner != self(), do: ref
    Process.put(key, state)
    on_delta = ProgramStream.delta_callback(&emit_delta(key, &1, publish, invocation_id))

    on_cache_hit = fn ->
      Process.put(key, :cache_hit)
      publish.(:stream_cache_hit)
    end

    try do
      with {:ok, %Prediction{} = prediction} = result <-
             module.forward(predictor, inputs, {on_delta, on_cache_hit}),
           :ok <- finish_fields(Process.get(key), prediction, publish, invocation_id) do
        result
      end
    after
      Process.delete(key)
    end
  end

  defp emit_delta(key, text, publish, invocation_id) do
    case Process.get(key) do
      nil ->
        {:error, :expired_stream_delta}

      :raw ->
        publish.({:delta, text})

      {name, scanner} ->
        {fragments, scanner} = ProgramStream.push_field_listener(scanner, text)
        Process.put(key, {name, scanner})
        publish_fields(fragments, name, invocation_id, publish)
    end
  end

  defp finish_fields(state, _prediction, _publish, _invocation_id)
       when state in [:raw, :cache_hit],
       do: :ok

  defp finish_fields({name, scanner}, prediction, publish, invocation_id) do
    with {:ok, fragments} <- ProgramStream.finish_field_listener(scanner, prediction) do
      publish_fields(fragments, name, invocation_id, publish)
    end
  end

  defp publish_fields(fragments, name, invocation_id, publish) do
    fragments
    |> ProgramStream.field_events(name, invocation_id)
    |> Enum.reduce_while(:ok, fn event, :ok ->
      case publish.(event) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
