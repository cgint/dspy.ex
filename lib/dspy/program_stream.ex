defmodule Dspy.ProgramStream do
  @moduledoc false

  alias Dspy.{ChainOfThought, Context, Predict, Prediction, ProcessOwnership, StatusMessage}
  alias Dspy.Module.PredictorSlots
  alias Dspy.ProgramStream.{Channel, Composite, StatusCallback}
  alias Dspy.Signature.AdapterPipeline

  alias Dspy.Signature.Adapters.{
    ChatAdapter,
    ChatStream,
    JSONAdapter,
    JSONStream,
    XMLAdapter,
    XMLStream
  }

  alias Dspy.StreamResponse

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

  defp listeners(program, :none) do
    PredictorSlots.list(program)
    :status_only
  end

  defp listeners(%{__struct__: type} = program, fields) when type in [Predict, ChainOfThought],
    do: select_fields(program, fields)

  defp listeners(program, fields), do: {:composite, Composite.select(program, fields)}

  defp select_fields(_program, []), do: nil

  defp select_fields(program, fields) when is_integer(length(fields)) do
    if length(fields) != MapSet.size(MapSet.new(fields)) do
      raise ArgumentError, "stream_listeners cannot contain duplicate fields"
    end

    validate_fields!(program.signature.output_fields, fields)
    [{predict_name, _predictor}] = Dspy.Module.named_predictors(program)
    {predict_name, fields}
  end

  defp select_fields(_program, _fields) do
    raise ArgumentError, "stream_listeners must be a list of output field atoms"
  end

  def validate_fields!(outputs, fields) do
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

  def open_field_listener(predictor, fields) do
    case AdapterPipeline.active_adapter(adapter: predictor.adapter) do
      ChatAdapter ->
        {:ok, %{predictor | adapter: ChatAdapter}, ChatStream.new(fields)}

      JSONAdapter ->
        {:ok, %{predictor | adapter: JSONAdapter}, JSONStream.new(predictor.signature, fields)}

      XMLAdapter ->
        {:ok, %{predictor | adapter: XMLAdapter}, XMLStream.new(predictor.signature, fields)}

      adapter ->
        {:error, {:unsupported_streaming_adapter, adapter}}
    end
  end

  def push_field_listener(%ChatStream{} = scanner, text), do: ChatStream.push(scanner, text)
  def push_field_listener(%JSONStream{} = scanner, text), do: JSONStream.push(scanner, text)
  def push_field_listener(%XMLStream{} = scanner, text), do: XMLStream.push(scanner, text)

  def finish_field_listener(%ChatStream{} = scanner, _prediction),
    do: {:ok, ChatStream.finish(scanner)}

  def finish_field_listener(%JSONStream{} = scanner, prediction),
    do: JSONStream.finish(scanner, prediction)

  def finish_field_listener(%XMLStream{} = scanner, prediction),
    do: {:ok, XMLStream.finish(scanner, prediction)}

  def field_events(fragments, predict_name, invocation_id \\ nil) do
    for {field, chunk, last?} <- fragments do
      %StreamResponse{
        predict_name: predict_name,
        signature_field_name: field,
        chunk: chunk,
        is_last_chunk: last?,
        invocation_id: invocation_id
      }
    end
  end

  defp start(program, inputs, opts, listeners, provider) do
    consumer = self()
    tag = make_ref()
    context = Context.capture()
    composite? = match?({:composite, _}, listeners)

    cancel_reason =
      if listeners == :status_only or composite?,
        do: :kill,
        else: :shutdown

    run = fn ->
      ProcessOwnership.watch(consumer, self(), cancel_reason)
      {destination, publish} = publisher(composite?, consumer, tag)

      terminal =
        Context.with_context(context, fn ->
          StatusCallback.with_provider(provider, publish, fn ->
            call_program(program, inputs, opts, listeners, publish, {destination, tag})
          end)
        end)

      send(destination, {tag, :terminal, terminal})
    end

    worker = if composite?, do: Channel.start(run), else: spawn_monitor(run)

    %{
      consumer: consumer,
      tag: tag,
      worker: worker,
      channel: if(composite?, do: :initial),
      cancel_reason: cancel_reason,
      listener: nil,
      pending: []
    }
  end

  defp publisher(true, _consumer, tag), do: Channel.publisher(tag, self())

  defp publisher(false, consumer, tag) do
    await_demand(tag)

    {consumer,
     fn event ->
       send(consumer, {tag, event})
       await_demand(tag)
     end}
  end

  defp await_demand(tag) do
    receive do
      {^tag, :demand} -> :ok
    end
  end

  defp next_event(%{worker: nil, pending: []} = state), do: {:halt, state}

  defp next_event(%{consumer: consumer} = state) when consumer != self(),
    do: reject_foreign_consumer!(state)

  # Yield one event at a time so a resumed enumeration always checks ownership.
  defp next_event(%{pending: [event | pending]} = state),
    do: {[event], %{state | pending: pending}}

  defp next_event(%{tag: tag, worker: {worker, inbox}, channel: channel} = state)
       when not is_nil(channel) do
    case Channel.next(tag, worker, inbox, channel) do
      {:event, receipt, event} ->
        {[event], %{state | channel: receipt}}

      {:terminal, event} ->
        close_channel(state)
        await_stop(worker, inbox)
        next_event(queue_terminal(state, event))

      {:down, reason} ->
        close_channel(state)
        next_event(queue_terminal(state, {:error, {:stream_worker_exited, reason}}))
    end
  end

  defp next_event(%{tag: tag, worker: {worker, worker_ref}} = state) do
    send(worker, {tag, :demand})
    receive_event(state, tag, worker, worker_ref)
  end

  defp receive_event(state, tag, worker, worker_ref) do
    receive do
      {^tag, :field_listener, listener} ->
        receive_event(%{state | listener: listener}, tag, worker, worker_ref)

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
    {fragments, scanner} = push_field_listener(scanner, text)
    %{state | listener: {predict_name, scanner}, pending: field_events(fragments, predict_name)}
  end

  defp queue_terminal(%{listener: {predict_name, scanner}} = state, %Prediction{} = prediction) do
    pending =
      case finish_field_listener(scanner, prediction) do
        {:ok, fragments} -> field_events(fragments, predict_name) ++ [prediction]
        {:error, _reason} = error -> [error]
      end

    %{state | worker: nil, listener: nil, pending: pending}
  end

  defp queue_terminal(state, event), do: %{state | worker: nil, listener: nil, pending: [event]}

  defp stop(%{worker: nil, pending: []}), do: :ok

  defp stop(%{consumer: consumer} = state) when consumer != self(),
    do: reject_foreign_consumer!(state)

  defp stop(%{worker: nil}), do: :ok

  defp stop(%{worker: {worker, worker_ref}, cancel_reason: cancel_reason} = state) do
    close_channel(state)
    Process.exit(worker, cancel_reason)
    await_stop(worker, worker_ref)
  end

  defp close_channel(%{channel: nil}), do: :ok
  defp close_channel(%{tag: tag, worker: {_worker, inbox}}), do: Channel.close(tag, inbox)

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

  defp call_program(program, inputs, opts, listeners, publish, {destination, tag}) do
    result =
      case listeners do
        :status_only ->
          invoke(program, inputs, opts)

        {:composite, slots} ->
          Composite.with_listeners(program, slots, publish, &invoke(&1, inputs, opts))

        {name, fields} ->
          with {:ok, program, scanner} <- open_field_listener(program, fields) do
            send(destination, {tag, :field_listener, {name, scanner}})
            Process.put(@delta_key, delta_callback(&publish.({:delta, &1})))
            invoke(program, inputs, opts)
          end

        nil ->
          Process.put(@delta_key, delta_callback(&publish.({:delta, &1})))
          invoke(program, inputs, opts)
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
end
