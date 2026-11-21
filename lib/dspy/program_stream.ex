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
      |> listen(listeners)
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
      unless is_atom(field) and Enum.any?(outputs, &match?(%{name: ^field, type: :string}, &1)) do
        raise ArgumentError, "stream_listeners must name declared string output fields by atom"
      end
    end)

    [{predict_name, _predictor}] = Dspy.Module.named_predictors(program)
    {predict_name, fields}
  end

  defp select_fields(_program, _fields) do
    raise ArgumentError, "stream_listeners must be a list of output field atoms"
  end

  defp listen(stream, nil), do: stream

  defp listen(stream, {predict_name, fields}) do
    Stream.transform(stream, ChatStream.new(fields), fn
      {:delta, text}, state ->
        {fragments, state} = ChatStream.push(state, text)
        {field_events(fragments, predict_name), state}

      %Prediction{} = prediction, state ->
        {field_events(ChatStream.finish(state), predict_name) ++ [prediction], state}

      {:error, _reason} = error, state ->
        {[error], state}
    end)
  end

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

    {consumer, tag, worker, worker_ref}
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

  defp next_event(:done), do: {:halt, :done}

  defp next_event({consumer, tag, worker, worker_ref} = state) when consumer == self() do
    send(worker, {tag, :demand})

    receive do
      {^tag, {:delta, _text} = delta} ->
        {[delta], state}

      {^tag, :terminal, event} ->
        await_stop(worker, worker_ref)
        {[event], :done}

      {:DOWN, ^worker_ref, :process, ^worker, reason} ->
        {[{:error, {:stream_worker_exited, reason}}], :done}
    end
  end

  defp next_event({_consumer, _tag, worker, _worker_ref}), do: reject_foreign_consumer!(worker)

  defp stop(:done), do: :ok

  defp stop({consumer, _tag, worker, worker_ref}) when consumer == self() do
    Process.exit(worker, :shutdown)
    await_stop(worker, worker_ref)
  end

  defp stop({_consumer, _tag, worker, _worker_ref}), do: reject_foreign_consumer!(worker)

  defp reject_foreign_consumer!(worker) do
    Process.exit(worker, :shutdown)
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
