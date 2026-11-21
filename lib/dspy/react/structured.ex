defmodule Dspy.ReAct.Structured do
  @moduledoc false

  alias Dspy.{History, LM, Module, Predict, Prediction, Settings, Signature, Tools}
  alias Dspy.History.Turn
  alias Dspy.Signature.Adapters.{ChatAdapter, JSONAdapter}
  alias Dspy.Tools.Tool

  def build!(signature, tools, adapter, max_steps) do
    validate_reserved!(signature.input_fields, [:history, :tools, :turn_budget])
    validate_reserved!(signature.output_fields, [:history, :termination_reason])

    if Map.has_key?(tools, "submit"), do: raise(ArgumentError, "submit is reserved by ReAct")

    unless is_integer(max_steps) and max_steps >= 0 do
      raise ArgumentError, "structured ReAct requires a nonnegative :max_steps"
    end

    adapter = adapter || ChatAdapter
    tools = Map.put(tools, "submit", submit_tool(signature))
    step = step_signature(signature, tools)

    %Dspy.ReAct{
      mode: :structured,
      signature: signature,
      tools: tools,
      max_steps: max_steps,
      adapter: adapter,
      step_signature: step,
      step_predictor: Predict.new(step, adapter: adapter, max_output_retries: 0)
    }
  end

  def forward(react, inputs) do
    supplied_history = Map.get(inputs, :history, Map.get(inputs, "history"))
    history = if is_nil(supplied_history), do: History.new(), else: supplied_history

    lm = Map.get(react.step_predictor, :lm) || Settings.get(:lm)

    with :ok <- validate_route(react.step_predictor.adapter, lm),
         {:ok, ids} <- History.typed_tool_ids(history),
         :ok <- validate_inputs(react.signature, inputs, history) do
      pending =
        for field <- react.signature.input_fields,
            {:ok, value} <- [fetch_input(inputs, field.name)],
            into: %{},
            do: {field.name, value}

      runtime = %{react | step_predictor: %{react.step_predictor | lm: lm}}
      run_turns(runtime, pending, history, ids, runtime.max_steps)
    end
  end

  defp fetch_input(inputs, name) do
    case Map.fetch(inputs, name) do
      :error -> Map.fetch(inputs, Atom.to_string(name))
      present -> present
    end
  end

  defp validate_route(adapter, _lm) when adapter != ChatAdapter,
    do: {:error, {:unsupported_structured_react_adapter, adapter}}

  defp validate_route(ChatAdapter, nil), do: {:error, :no_lm_configured}

  defp validate_route(ChatAdapter, lm) do
    if LM.supports?(lm, :structured_react),
      do: :ok,
      else: {:error, :unsupported_structured_react_lm}
  end

  defp validate_inputs(signature, inputs, %History{messages: []}),
    do: Signature.validate_inputs(signature, inputs)

  defp validate_inputs(signature, inputs, %History{}),
    do: Signature.validate_inputs(optional_inputs(signature), inputs)

  defp validate_reserved!(fields, reserved) do
    for %{name: name} <- fields, name in reserved do
      raise ArgumentError, "field #{name} is reserved by structured ReAct"
    end
  end

  defp optional_inputs(signature) do
    %{signature | input_fields: Enum.map(signature.input_fields, &Map.put(&1, :required, false))}
  end

  defp step_signature(signature, tools) do
    tool_names = tools |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    instructions = """
    #{signature.instructions}
    Use the supplied tools to answer the request. Call submit with the final outputs.
    Tools: #{tool_names}.
    If native tool calls are unavailable, write a [[ ## tool_calls ## ]] section containing
    a JSON array of calls such as [{"name":"submit","args":{"output":"value"}}].
    An optional [[ ## next_thought ## ]] section may precede the tool calls.
    """

    internal_inputs = [
      field(:history, :history, "Conversation history"),
      Map.put(field(:tools, :tools, "Tool declarations"), :wire_only, true),
      field(:turn_budget, :string, "Current turn budget")
    ]

    outputs = [
      field(:next_thought, :string, "Thought for this turn"),
      Map.put(field(:tool_calls, :tool_calls, "Tool calls"), :tool_call_format, :structured)
    ]

    Signature.new("react_structured_step",
      input_fields: optional_inputs(signature).input_fields ++ internal_inputs,
      output_fields: outputs,
      instructions: String.trim(instructions)
    )
  end

  defp field(name, type, description),
    do: %{name: name, type: type, description: description, required: false, default: nil}

  defp submit_tool(signature) do
    contract = JSONAdapter.output_contract(signature)

    required =
      for field <- signature.output_fields, field.required, do: Atom.to_string(field.name)

    # Responses strict tools require every property on the wire. Null means
    # omission for an optional DSPy output.
    properties =
      Map.new(signature.output_fields, fn field ->
        name = Atom.to_string(field.name)

        schema =
          Map.get(contract["properties"], name) ||
            raise ArgumentError, "structured ReAct cannot submit output type #{field.type}"

        schema =
          if field.required,
            do: schema,
            else: %{"anyOf" => [schema, %{"type" => "null"}]}

        {name, Map.put_new(schema, "description", field.description || "")}
      end)

    Tools.new_tool(
      "submit",
      "Submit the final outputs for the task.",
      &JSONAdapter.cast_declared_outputs(signature, &1),
      parameters: %{contract | "required" => required, "properties" => properties}
    )
  end

  defp run_turns(react, pending, history, ids, 0),
    do: forced_submit(react, pending, history, ids, :max_steps)

  defp run_turns(react, pending, history, ids, remaining) do
    index = react.max_steps - remaining + 1
    inputs = Map.put(pending, :turn_budget, "Turn #{index} of #{react.max_steps}.")
    tools = react.tools |> Map.values() |> Enum.sort_by(& &1.name)

    case predict(react.step_predictor, inputs, history, tools) do
      {:ok, %{attrs: %{tool_calls: [_ | _] = calls} = attrs}} ->
        case with_call_ids(calls, ids, length(history.messages)) do
          {:ok, calls, ids} ->
            {next_history, outputs} = execute_turn(react.tools, calls, attrs, history, inputs)

            if is_nil(outputs) do
              run_turns(react, %{}, next_history, ids, remaining - 1)
            else
              prediction(outputs, next_history, :submit)
            end

          {:error, reason} ->
            failure(reason, history)
        end

      {:ok, _prediction} ->
        forced_submit(react, pending, history, ids, :empty_tool_calls)

      {:error, reason} ->
        case recoverable_turn_failure(reason) do
          nil -> failure(reason, history)
          stop -> forced_submit(react, pending, history, ids, stop)
        end
    end
  end

  defp forced_submit(react, pending, history, ids, stop) do
    inputs = Map.put(pending, :turn_budget, "No turns remain. Call submit now.")
    submit = Map.fetch!(react.tools, "submit")
    predictor = %{react.step_predictor | forced_tool: "submit"}

    with {:ok, %{attrs: attrs}} <- predict(predictor, inputs, history, [submit]),
         {:ok, calls, _ids} <-
           with_call_ids(Map.get(attrs, :tool_calls, []), ids, length(history.messages)) do
      case Enum.filter(calls, &(&1.name == "submit")) do
        [] ->
          failure({:missing_submit, stop}, history)

        submissions ->
          case execute_turn(react.tools, submissions, attrs, history, inputs) do
            {next_history, nil} -> failure({:submit_failed, stop}, next_history)
            {next_history, outputs} -> prediction(outputs, next_history, :forced_submit)
          end
      end
    else
      {:error, reason} -> failure({:forced_submit_failed, stop, reason}, history)
    end
  end

  defp predict(predictor, inputs, history, tools) do
    declarations = Enum.map(tools, &tool_declaration/1)
    Module.forward(predictor, Map.merge(inputs, %{history: history, tools: declarations}))
  end

  defp tool_declaration(%Tool{name: "submit", parameters: parameters} = tool) do
    if Enum.all?(parameters["properties"], fn {_name, schema} -> strict_schema?(schema) end) do
      tool
    else
      # ReqLLM strict tools close nested objects and require every nested key.
      # Preserve the declared schema and validate required fields locally.
      required = Enum.join(parameters["required"], ", ")
      guidance = if required == "", do: "", else: " Required fields are #{required}."

      %{
        "type" => "function",
        "function" => %{
          "name" => tool.name,
          "description" => tool.description <> guidance,
          "parameters" => parameters,
          "strict" => false
        }
      }
    end
  end

  defp tool_declaration(tool), do: tool

  defp strict_schema?(schema) when is_map(schema) do
    if "object" in List.wrap(schema["type"]) or Map.has_key?(schema, "properties") do
      properties = Map.get(schema, "properties", %{})

      schema["additionalProperties"] == false and
        Enum.sort(Map.keys(properties)) == Enum.sort(Map.get(schema, "required", [])) and
        Enum.all?(properties, fn {_name, value} -> strict_schema?(value) end)
    else
      schema |> Map.values() |> Enum.all?(&strict_schema?/1)
    end
  end

  defp strict_schema?(schemas) when is_list(schemas), do: Enum.all?(schemas, &strict_schema?/1)
  defp strict_schema?(_schema), do: true

  defp recoverable_turn_failure({:output_parse_failed, _reason, _meta}), do: :parse_error
  defp recoverable_turn_failure({:missing_content, _reason}), do: :parse_error

  defp recoverable_turn_failure(%ReqLLM.Error.API.Request{
         response_body: %{"error" => %{"code" => "context_length_exceeded"}}
       }),
       do: :context_window_exceeded

  defp recoverable_turn_failure(_reason), do: nil

  defp with_call_ids(calls, ids, turn) do
    explicit = for %{id: id} <- calls, is_binary(id), do: id

    result =
      Enum.reduce_while(explicit, {:ok, ids}, fn id, {:ok, seen} ->
        if MapSet.member?(seen, id),
          do: {:halt, {:error, {:duplicate_tool_call_id, id}}},
          else: {:cont, {:ok, MapSet.put(seen, id)}}
      end)

    with {:ok, ids} <- result do
      {calls, ids} =
        calls
        |> Enum.with_index()
        |> Enum.map_reduce(ids, fn
          {%{id: nil} = call, index}, seen ->
            base = "call_#{turn}_#{index}"
            id = if MapSet.member?(seen, base), do: find_id(base, seen, 1), else: base
            {%{call | id: id}, MapSet.put(seen, id)}

          {call, _index}, seen ->
            {call, seen}
        end)

      {:ok, calls, ids}
    end
  end

  defp find_id(base, ids, suffix) do
    candidate = "#{base}_#{suffix}"
    if MapSet.member?(ids, candidate), do: find_id(base, ids, suffix + 1), else: candidate
  end

  defp execute_turn(tools, calls, attrs, history, inputs) do
    {exchanges, outputs} =
      Enum.map_reduce(calls, nil, fn call, outputs ->
        {result, is_error, outputs} = execute_call(tools, call, outputs)

        {%{
           id: call.id,
           name: call.name,
           arguments: call.args,
           result: result,
           is_error: is_error
         }, outputs}
      end)

    turn = %Turn{
      inputs: inputs,
      outputs: Map.merge(Map.take(attrs, [:next_thought]), outputs || %{}),
      tool_exchanges: exchanges
    }

    {%{history | messages: history.messages ++ [turn]}, outputs}
  end

  defp execute_call(tools, call, outputs) do
    case Map.fetch(tools, call.name) do
      {:ok, tool} ->
        case Tools.execute_tool(tool, call.args) do
          {:ok, {:ok, submitted}} when call.name == "submit" ->
            {submitted, false, submitted}

          {:ok, {:error, reason}} when call.name == "submit" ->
            {"Invalid submit: " <> inspect(reason, limit: 20), true, outputs}

          {:ok, result} ->
            {result, false, outputs}

          {:error, reason} ->
            {"Tool error: " <> reason, true, outputs}
        end

      :error ->
        {"Unknown tool: " <> call.name, true, outputs}
    end
  end

  defp prediction(outputs, history, reason),
    do: {:ok, Prediction.new(Map.merge(outputs, %{history: history, termination_reason: reason}))}

  defp failure(reason, history),
    do: {:error, {:structured_react_failed, %{reason: reason, history: history}}}
end
