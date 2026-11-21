defmodule Dspy.ProgramStream do
  @moduledoc false

  alias Dspy.{ChainOfThought, Context, Predict, Prediction, StreamResponse}
  alias Dspy.Signature.AdapterPipeline
  alias Dspy.Signature.Adapters.{ChatAdapter, ChatStream}

  @delta_key {__MODULE__, :on_delta}

  def wrap(%{__struct__: type} = program, opts) when type in [Predict, ChainOfThought] do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "expected streamify call options")
    {fields, call_opts} = Keyword.pop(opts, :stream_listeners, [])
    listeners = select_fields(program, fields)

    fn inputs ->
      Stream.resource(
        fn -> start(program, inputs, call_opts, listeners) end,
        &next_event/1,
        &stop/1
      )
    end
  end

  def wrap(_program, _opts) do
    raise ArgumentError, "streamify requires a standalone Predict or ChainOfThought"
  end

  def take_delta, do: Process.delete(@delta_key)

  defp select_fields(_program, []), do: nil

  defp select_fields(program, fields) when is_integer(length(fields)) do
    if length(fields) != MapSet.size(MapSet.new(fields)) do
      raise ArgumentError, "stream_listeners cannot contain duplicate fields"
    end

    outputs = program.signature.output_fields

    if Enum.any?(outputs, &match?(%{type: :tool_calls, tool_call_format: :structured}, &1)) do
      raise ArgumentError, "stream_listeners require ordinary Chat markers"
    end

    Enum.each(fields, fn field ->
      unless is_atom(field) and Enum.any?(outputs, &plain_string_output?(&1, field)) do
        raise ArgumentError, "stream_listeners must name declared plain string outputs by atom"
      end
    end)

    [{predict_name, _predictor}] = Dspy.Module.named_predictors(program)
    {predict_name, fields}
  end

  defp select_fields(_program, _fields) do
    raise ArgumentError, "stream_listeners must be a list of output field atoms"
  end

  defp plain_string_output?(%{name: name, type: :string} = output, name),
    do: not Map.has_key?(output, :schema)

  defp plain_string_output?(_output, _name), do: false

  defp field_events(fragments, predict_name) do
    for {field, chunk, last?} <- fragments do
      %StreamResponse{
        predict_name: predict_name,
        signature_field_name: field,
        chunk: chunk,
        is_last_chunk: last?
      }
    end
  end

  defp start(program, inputs, opts, listeners) do
    consumer = self()
    tag = make_ref()
    context = Context.capture()

    {worker, worker_ref} =
      spawn_monitor(fn ->
        worker = self()
        spawn(fn -> watch_consumer(consumer, worker) end)
        await_demand(tag)

        terminal =
          Context.with_context(context, fn ->
            Process.put(@delta_key, fn
              _text when self() != worker ->
                {:error, :foreign_stream_delta}

              text when is_binary(text) ->
                send(consumer, {tag, {:delta, text}})
                await_demand(tag)

              _invalid ->
                {:error, :invalid_stream_delta}
            end)

            call_program(program, inputs, opts, listeners)
          end)

        send(consumer, {tag, :terminal, terminal})
      end)

    listener =
      case listeners do
        nil -> nil
        {predict_name, fields} -> {predict_name, ChatStream.new(fields)}
      end

    %{consumer: consumer, tag: tag, worker: {worker, worker_ref}, listener: listener, pending: []}
  end

  defp await_demand(tag) do
    receive do
      {^tag, :demand} -> :ok
    end
  end

  defp watch_consumer(consumer, worker) do
    consumer_ref = Process.monitor(consumer)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^consumer_ref, :process, ^consumer, _reason} -> Process.exit(worker, :shutdown)
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
    end
  end

  defp next_event(%{worker: nil, pending: []} = state), do: {:halt, state}

  defp next_event(%{consumer: consumer, worker: worker}) when consumer != self(),
    do: reject_foreign_consumer!(worker)

  # Yield one event at a time so a resumed enumeration always checks ownership.
  defp next_event(%{pending: [event | pending]} = state),
    do: {[event], %{state | pending: pending}}

  defp next_event(%{tag: tag, worker: {worker, worker_ref}} = state) do
    send(worker, {tag, :demand})

    receive do
      {^tag, {:delta, _text} = delta} ->
        next_event(queue_delta(state, delta))

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

  defp stop(%{consumer: consumer, worker: worker}) when consumer != self(),
    do: reject_foreign_consumer!(worker)

  defp stop(%{worker: nil}), do: :ok

  defp stop(%{worker: {worker, worker_ref}}) do
    Process.exit(worker, :shutdown)
    await_stop(worker, worker_ref)
  end

  defp reject_foreign_consumer!(worker) do
    case worker do
      {pid, _ref} -> Process.exit(pid, :shutdown)
      nil -> :ok
    end

    raise ArgumentError, "streamify continuations belong to their original consumer"
  end

  defp await_stop(worker, worker_ref) do
    receive do
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
    end
  end

  defp call_program(program, inputs, opts, listeners) do
    with {:ok, program} <- select_adapter(program, listeners) do
      result =
        if opts == [], do: Dspy.call(program, inputs), else: Dspy.call(program, inputs, opts)

      case result do
        {:ok, prediction} -> prediction
        {:error, _} = error -> error
      end
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:stream_worker_exited, reason}}
    :throw, reason -> {:error, {:stream_worker_threw, reason}}
  end

  defp select_adapter(program, nil), do: {:ok, program}

  defp select_adapter(program, _listeners) do
    case AdapterPipeline.active_adapter(adapter: program.adapter) do
      ChatAdapter -> {:ok, %{program | adapter: ChatAdapter}}
      adapter -> {:error, {:unsupported_streaming_adapter, adapter}}
    end
  end
end
