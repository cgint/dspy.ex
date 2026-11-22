defmodule Dspy.ProgramStream do
  @moduledoc false

  alias Dspy.{ChainOfThought, Context, Predict, Prediction, StatusMessage, StreamResponse}
  alias Dspy.ProgramStream.{Composite, StatusCallback}
  alias Dspy.Signature.AdapterPipeline
  alias Dspy.Signature.Adapters.{ChatAdapter, ChatStream}

  @delta_key {__MODULE__, :on_delta}

  def wrap(program, opts) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "expected streamify call options")
    {fields, opts} = Keyword.pop(opts, :stream_listeners, [])
    {provider, call_opts} = Keyword.pop(opts, :status_message_provider)
    validate_status_provider!(provider)
    listeners = listeners(program, fields)

    fn inputs ->
      Stream.resource(
        fn -> start(program, inputs, call_opts, listeners, provider) end,
        &next_event/1,
        &stop/1
      )
    end
  end

  def take_delta, do: Process.delete(@delta_key)

  def delta_callback(consume) do
    worker = self()

    fn
      _text when self() != worker -> {:error, :foreign_stream_delta}
      text when is_binary(text) -> consume.(text)
      _invalid -> {:error, :invalid_stream_delta}
    end
  end

  defp validate_status_provider!(nil), do: :ok

  defp validate_status_provider!(provider) do
    unless is_atom(provider) and Code.ensure_loaded?(provider) and
             function_exported?(provider, :message, 2) do
      raise ArgumentError, "status_message_provider must be a module exporting message/2 or nil"
    end
  end

  defp listeners(%{__struct__: type} = program, fields) when type in [Predict, ChainOfThought],
    do: select_fields(program, fields)

  defp listeners(program, fields), do: {:composite, Composite.select(program, fields)}

  defp select_fields(_program, []), do: nil

  defp select_fields(program, fields) when is_integer(length(fields)) do
    if length(fields) != MapSet.size(MapSet.new(fields)) do
      raise ArgumentError, "stream_listeners cannot contain duplicate fields"
    end

    validate_chat_fields!(program.signature.output_fields, fields)
    [{predict_name, _predictor}] = Dspy.Module.named_predictors(program)
    {predict_name, fields}
  end

  defp select_fields(_program, _fields) do
    raise ArgumentError, "stream_listeners must be a list of output field atoms"
  end

  def validate_chat_fields!(outputs, fields) do
    if Enum.any?(outputs, &match?(%{type: :tool_calls, tool_call_format: :structured}, &1)) do
      raise ArgumentError, "stream_listeners require ordinary Chat markers"
    end

    Enum.each(fields, fn field ->
      unless is_atom(field) and Enum.any?(outputs, &plain_string_output?(&1, field)) do
        raise ArgumentError, "stream_listeners must name declared plain string outputs by atom"
      end
    end)
  end

  defp plain_string_output?(%{name: name, type: :string} = output, name),
    do: not Map.has_key?(output, :schema)

  defp plain_string_output?(_output, _name), do: false

  def field_events(fragments, predict_name) do
    for {field, chunk, last?} <- fragments do
      %StreamResponse{
        predict_name: predict_name,
        signature_field_name: field,
        chunk: chunk,
        is_last_chunk: last?
      }
    end
  end

  defp start(program, inputs, opts, listeners, provider) do
    consumer = self()
    tag = make_ref()
    context = Context.capture()
    cancel_reason = if match?({:composite, _}, listeners), do: :kill, else: :shutdown

    {worker, worker_ref} =
      spawn_monitor(fn ->
        worker = self()
        spawn(fn -> watch_consumer(consumer, worker, cancel_reason) end)
        await_demand(tag)

        publish = fn event ->
          send(consumer, {tag, event})
          await_demand(tag)
        end

        terminal =
          Context.with_context(context, fn ->
            StatusCallback.with_provider(provider, publish, fn ->
              call_program(program, inputs, opts, listeners, publish)
            end)
          end)

        send(consumer, {tag, :terminal, terminal})
      end)

    listener =
      case listeners do
        nil -> nil
        {:composite, _} -> nil
        {predict_name, fields} -> {predict_name, ChatStream.new(fields)}
      end

    %{
      consumer: consumer,
      tag: tag,
      worker: {worker, worker_ref},
      cancel_reason: cancel_reason,
      listener: listener,
      pending: []
    }
  end

  defp await_demand(tag) do
    receive do
      {^tag, :demand} -> :ok
    end
  end

  defp watch_consumer(consumer, worker, cancel_reason) do
    consumer_ref = Process.monitor(consumer)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^consumer_ref, :process, ^consumer, _reason} -> Process.exit(worker, cancel_reason)
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
    end
  end

  defp next_event(%{worker: nil, pending: []} = state), do: {:halt, state}

  defp next_event(%{consumer: consumer} = state) when consumer != self(),
    do: reject_foreign_consumer!(state)

  # Yield one event at a time so a resumed enumeration always checks ownership.
  defp next_event(%{pending: [event | pending]} = state),
    do: {[event], %{state | pending: pending}}

  defp next_event(%{tag: tag, worker: {worker, worker_ref}} = state) do
    send(worker, {tag, :demand})

    receive do
      {^tag, {:delta, _text} = delta} ->
        next_event(queue_delta(state, delta))

      {^tag, %{__struct__: event_type} = event}
      when event_type in [StatusMessage, StreamResponse] ->
        next_event(%{state | pending: [event]})

      {^tag, :terminal, event} ->
        await_stop(worker, worker_ref)
        next_event(queue_terminal(state, event))

      {:DOWN, ^worker_ref, :process, ^worker, reason} ->
        next_event(queue_terminal(state, {:error, {:stream_worker_exited, reason}}))
    end
  end

  defp queue_delta(%{listener: nil} = state, delta), do: %{state | pending: [delta]}

  defp queue_delta(%{listener: {predict_name, scanner}} = state, {:delta, text}) do
    {fragments, scanner} = ChatStream.push(scanner, text)
    %{state | listener: {predict_name, scanner}, pending: field_events(fragments, predict_name)}
  end

  defp queue_terminal(%{listener: {predict_name, scanner}} = state, %Prediction{} = prediction) do
    pending = field_events(ChatStream.finish(scanner), predict_name) ++ [prediction]
    %{state | worker: nil, listener: nil, pending: pending}
  end

  defp queue_terminal(state, event), do: %{state | worker: nil, listener: nil, pending: [event]}

  defp stop(%{worker: nil, pending: []}), do: :ok

  defp stop(%{consumer: consumer} = state) when consumer != self(),
    do: reject_foreign_consumer!(state)

  defp stop(%{worker: nil}), do: :ok

  defp stop(%{worker: {worker, worker_ref}, cancel_reason: cancel_reason}) do
    Process.exit(worker, cancel_reason)
    await_stop(worker, worker_ref)
  end

  defp reject_foreign_consumer!(%{worker: worker, cancel_reason: cancel_reason}) do
    case worker do
      {pid, _ref} -> Process.exit(pid, cancel_reason)
      nil -> :ok
    end

    raise ArgumentError, "streamify continuations belong to their original consumer"
  end

  defp await_stop(worker, worker_ref) do
    receive do
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
    end
  end

  defp call_program(program, inputs, opts, listeners, publish) do
    result =
      case listeners do
        {:composite, slots} ->
          Composite.with_listeners(program, slots, publish, &invoke(&1, inputs, opts))

        _standalone ->
          with {:ok, program} <- select_adapter(program, listeners) do
            Process.put(@delta_key, delta_callback(&publish.({:delta, &1})))
            invoke(program, inputs, opts)
          end
      end

    case result do
      {:ok, prediction} -> prediction
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:stream_worker_exited, reason}}
    :throw, reason -> {:error, {:stream_worker_threw, reason}}
  end

  defp invoke(program, inputs, []), do: Dspy.call(program, inputs)
  defp invoke(program, inputs, opts), do: Dspy.call(program, inputs, opts)

  defp select_adapter(program, nil), do: {:ok, program}

  defp select_adapter(program, _listeners) do
    case AdapterPipeline.active_adapter(adapter: program.adapter) do
      ChatAdapter -> {:ok, %{program | adapter: ChatAdapter}}
      adapter -> {:error, {:unsupported_streaming_adapter, adapter}}
    end
  end
end
