defmodule Dspy.Tools do
  @moduledoc """
  Tools + ReAct support (adoption-first).

  Proven (deterministic tests):
  - Tool definition helpers: `new_tool/4` + `execute_tool/3`
  - ReAct loop: `Dspy.Tools.React` (incl. tool start/end callbacks via `Dspy.Tools.Callback`)
  - Function-calling helper: `Dspy.Tools.FunctionCalling` (uses request maps)

  Note: the global `ToolRegistry` is a convenience GenServer and is **not required** for the
  proven ReAct workflow.

  For the current stable surface + evidence, see `docs/OVERVIEW.md`.
  """

  defmodule Tool do
    @moduledoc """
    Represents a callable tool with metadata and validation.
    """

    defstruct [
      :name,
      :description,
      :function,
      :parameters,
      :return_type,
      :examples,
      :timeout,
      :retry_attempts,
      :validation_schema
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            function: function(),
            parameters: list(),
            return_type: atom(),
            examples: list(),
            timeout: pos_integer(),
            retry_attempts: pos_integer(),
            validation_schema: map() | nil
          }
  end

  defmodule ToolRegistry do
    @moduledoc """
    Registry for managing available tools.
    """

    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    def init(_opts) do
      {:ok, %{tools: %{}, categories: %{}}}
    end

    def register_tool(%Tool{} = tool) do
      GenServer.call(__MODULE__, {:register, tool})
    end

    def get_tool(name) do
      GenServer.call(__MODULE__, {:get, name})
    end

    def list_tools do
      GenServer.call(__MODULE__, :list)
    end

    def search_tools(query) do
      GenServer.call(__MODULE__, {:search, query})
    end

    def handle_call({:register, tool}, _from, state) do
      updated_tools = Map.put(state.tools, tool.name, tool)
      {:reply, :ok, %{state | tools: updated_tools}}
    end

    def handle_call({:get, name}, _from, state) do
      tool = Map.get(state.tools, name)
      {:reply, tool, state}
    end

    def handle_call(:list, _from, state) do
      tools = Map.values(state.tools)
      {:reply, tools, state}
    end

    def handle_call({:search, query}, _from, state) do
      matching_tools =
        state.tools
        |> Map.values()
        |> Enum.filter(fn tool ->
          String.contains?(String.downcase(tool.name), String.downcase(query)) or
            String.contains?(String.downcase(tool.description), String.downcase(query))
        end)

      {:reply, matching_tools, state}
    end
  end

  defmodule FunctionCalling do
    @moduledoc """
    Handles structured function calling with language models.
    """

    def call_function(lm, function_spec, args, opts \\ []) do
      prompt = build_function_call_prompt(function_spec, args, opts)

      request = %{
        messages: [Dspy.LM.user_message(prompt)],
        max_tokens: Keyword.get(opts, :max_tokens),
        max_completion_tokens: Keyword.get(opts, :max_completion_tokens),
        temperature: Keyword.get(opts, :temperature),
        stop: Keyword.get(opts, :stop),
        tools: Keyword.get(opts, :tools)
      }

      with {:ok, response} <- Dspy.LM.generate(lm, request),
           {:ok, text} <- Dspy.LM.text_from_response(response) do
        parse_function_response(text, function_spec, opts)
      else
        {:error, reason} ->
          {:error, "Function call failed: #{inspect(reason)}"}
      end
    end

    def build_function_call_prompt(function_spec, args, opts) do
      base_prompt = """
      You are a function calling assistant. Execute the following function with the provided arguments.

      Function: #{function_spec.name}
      Description: #{function_spec.description}

      Arguments:
      #{format_args(args)}

      Parameters:
      #{format_parameters(function_spec.parameters)}

      Execute the function and return the result in the specified format.
      """

      if opts[:format] == :json do
        base_prompt <> "\n\nReturn the result as JSON."
      else
        base_prompt
      end
    end

    defp format_args(args) when is_map(args) do
      Enum.map(args, fn {key, value} ->
        "- #{key}: #{inspect(value)}"
      end)
      |> Enum.join("\n")
    end

    defp format_parameters(parameters) do
      Enum.map(parameters, fn param ->
        "- #{param.name} (#{param.type}): #{param.description}"
      end)
      |> Enum.join("\n")
    end

    defp parse_function_response(response, function_spec, opts) do
      case opts[:format] do
        :json ->
          case Dspy.Adapters.parse(response, :json) do
            {:ok, parsed} -> validate_function_result(parsed, function_spec)
            {:error, reason} -> {:error, "Failed to parse JSON response: #{reason}"}
          end

        _ ->
          {:ok, response}
      end
    end

    defp validate_function_result(result, function_spec) do
      if function_spec.validation_schema do
        case validate_schema(result, function_spec.validation_schema) do
          :ok -> {:ok, result}
          {:error, reason} -> {:error, "Validation failed: #{reason}"}
        end
      else
        {:ok, result}
      end
    end

    defp validate_schema(data, schema) do
      # Basic schema validation - could be extended
      if is_map(data) and is_map(schema) do
        missing_keys = Map.keys(schema) -- Map.keys(data)

        if missing_keys == [] do
          :ok
        else
          {:error, "Missing required keys: #{inspect(missing_keys)}"}
        end
      else
        :ok
      end
    end
  end

  defmodule React do
    require Logger

    @type callback_entry :: {module(), term()}

    @moduledoc """
    Implementation of a small ReAct (Reasoning + Acting) loop.

    Notes:
    - Tool functions are executed in a separate `Task` and are subject to each tool's `timeout`.
      Do not rely on `self()` inside a tool being the ReAct process.
    - Tool start/end callbacks (`Dspy.Tools.Callback`) are invoked around tool execution.

    For the current stable surface + evidence, see `docs/OVERVIEW.md`.
    """

    defstruct [
      :lm,
      :tools,
      :max_steps,
      :thought_prefix,
      :action_prefix,
      :observation_prefix,
      :answer_prefix,
      :stop_words,
      :max_tokens,
      :max_completion_tokens,
      :temperature,
      callbacks: []
    ]

    @type t :: %__MODULE__{
            lm: any(),
            tools: list(),
            max_steps: pos_integer(),
            thought_prefix: String.t(),
            action_prefix: String.t(),
            observation_prefix: String.t(),
            answer_prefix: String.t(),
            stop_words: list(),
            max_tokens: pos_integer() | nil,
            max_completion_tokens: pos_integer() | nil,
            temperature: number() | nil,
            callbacks: list(callback_entry())
          }

    def new(lm, tools, opts \\ []) do
      %__MODULE__{
        lm: lm,
        tools: tools,
        max_steps: opts[:max_steps] || 10,
        thought_prefix: opts[:thought_prefix] || "Thought:",
        action_prefix: opts[:action_prefix] || "Action:",
        observation_prefix: opts[:observation_prefix] || "Observation:",
        answer_prefix: opts[:answer_prefix] || "Answer:",
        stop_words: opts[:stop_words] || ["Observation:", "Answer:"],
        max_tokens: opts[:max_tokens],
        max_completion_tokens: opts[:max_completion_tokens],
        temperature: opts[:temperature],
        callbacks: opts[:callbacks] || []
      }
    end

    def run(%__MODULE__{} = react, question, opts \\ []) do
      initial_prompt = build_react_prompt(react, question, opts)
      callbacks = Keyword.get(opts, :callbacks, react.callbacks)

      with :ok <- validate_callbacks(callbacks) do
        react = %{
          react
          | callbacks: callbacks,
            max_tokens: Keyword.get(opts, :max_tokens, react.max_tokens),
            max_completion_tokens:
              Keyword.get(opts, :max_completion_tokens, react.max_completion_tokens),
            temperature: Keyword.get(opts, :temperature, react.temperature)
        }

        execute_react_loop(react, initial_prompt, [], 0)
      end
    end

    defp validate_callbacks(callbacks) when is_list(callbacks) do
      callbacks
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn
        {{mod, _state}, idx}, :ok when is_atom(mod) ->
          if Code.ensure_loaded?(mod) and function_exported?(mod, :on_tool_start, 4) and
               function_exported?(mod, :on_tool_end, 5) do
            {:cont, :ok}
          else
            {:halt, {:error, {:invalid_callbacks, {:module_missing_callbacks, idx, mod}}}}
          end

        {other, idx}, :ok ->
          {:halt, {:error, {:invalid_callbacks, {:invalid_entry, idx, other}}}}
      end)
    end

    defp validate_callbacks(other), do: {:error, {:invalid_callbacks, {:not_a_list, other}}}

    defp build_react_prompt(react, question, _opts) do
      tool_descriptions =
        Enum.map(react.tools, fn tool ->
          "#{tool.name}: #{tool.description}"
        end)
        |> Enum.join("\n")

      """
      You are solving a problem step by step using reasoning and actions.

      Available tools:
      #{tool_descriptions}

      Use the following format:
      #{react.thought_prefix} [your reasoning about what to do next]
      #{react.action_prefix} [tool_name(arguments)]
      #{react.observation_prefix} [tool result will appear here]

      When you have enough information, provide your final answer:
      #{react.answer_prefix} [your final answer]

      Question: #{question}

      #{react.thought_prefix}
      """
    end

    defp execute_react_loop(react, prompt, history, step) when step < react.max_steps do
      request = %{
        messages: [Dspy.LM.user_message(prompt)],
        max_tokens: react.max_tokens,
        max_completion_tokens: react.max_completion_tokens,
        temperature: react.temperature,
        stop: react.stop_words
      }

      with {:ok, response} <- Dspy.LM.generate(react.lm, request),
           {:ok, text} <- Dspy.LM.text_from_response(response) do
        updated_prompt = prompt <> text

        case parse_react_step(text, react) do
          {:thought, thought} ->
            new_history = [{:thought, thought, step} | history]
            continue_react_loop(react, updated_prompt, new_history, step)

          {:action, action_call} ->
            case execute_action(action_call, react.tools, react.callbacks) do
              {:ok, observation} ->
                obs_text =
                  "\n#{react.observation_prefix} #{observation}\n#{react.thought_prefix} "

                new_prompt = updated_prompt <> obs_text

                new_history = [
                  {:action, action_call, step},
                  {:observation, observation, step} | history
                ]

                execute_react_loop(react, new_prompt, new_history, step + 1)

              {:error, error} ->
                error_text =
                  "\n#{react.observation_prefix} Error: #{error}\n#{react.thought_prefix} "

                new_prompt = updated_prompt <> error_text
                new_history = [{:action, action_call, step}, {:error, error, step} | history]
                execute_react_loop(react, new_prompt, new_history, step + 1)
            end

          {:answer, answer} ->
            {:ok,
             %{
               answer: answer,
               steps: step + 1,
               history: Enum.reverse(history),
               reasoning_trace: extract_reasoning_trace(history)
             }}

          {:none, _text} ->
            continue_react_loop(react, updated_prompt, history, step)
        end
      else
        {:error, reason} ->
          {:error, "React execution failed: #{inspect(reason)}"}
      end
    end

    defp execute_react_loop(react, _prompt, history, _step) do
      {:error,
       %{
         reason: "Max steps reached",
         max_steps: react.max_steps,
         history: Enum.reverse(history)
       }}
    end

    defp continue_react_loop(react, prompt, history, step) do
      execute_react_loop(react, prompt, history, step)
    end

    defp parse_react_step(text, react) do
      text = String.trim(text)

      cond do
        String.starts_with?(text, react.answer_prefix) ->
          answer = String.replace_prefix(text, react.answer_prefix, "") |> String.trim()
          {:answer, answer}

        String.contains?(text, react.action_prefix) ->
          case Regex.run(~r/#{react.action_prefix}\s*(.+)/i, text, capture: :all_but_first) do
            [action] -> {:action, String.trim(action)}
            _ -> {:none, text}
          end

        String.starts_with?(text, react.thought_prefix) ->
          thought = String.replace_prefix(text, react.thought_prefix, "") |> String.trim()
          {:thought, thought}

        true ->
          {:none, text}
      end
    end

    defp execute_action(action_call, tools, callbacks) do
      case parse_action_call(action_call) do
        {:ok, {tool_name, args}} ->
          case find_tool(tool_name, tools) do
            {:ok, tool} ->
              call_tool(tool, args, callbacks)

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp parse_action_call(action_call) do
      # Parse action calls like "search(query='machine learning')" or "calculate(2+2)"
      case Regex.run(~r/(\w+)\s*\(([^)]*)\)/, action_call, capture: :all_but_first) do
        [tool_name, args_str] ->
          case parse_arguments(args_str) do
            {:ok, args} -> {:ok, {tool_name, args}}
            {:error, reason} -> {:error, "Failed to parse arguments: #{reason}"}
          end

        _ ->
          # Maybe it's just a tool name
          {:ok, {String.trim(action_call), %{}}}
      end
    end

    defp parse_arguments(""), do: {:ok, %{}}

    defp parse_arguments(args_str) do
      # Simple argument parsing - could be more sophisticated
      try do
        # Try to parse as key=value pairs
        args =
          String.split(args_str, ",")
          |> Enum.map(&String.trim/1)
          |> Enum.reduce(%{}, fn arg, acc ->
            case String.split(arg, "=", parts: 2) do
              [key, value] ->
                clean_key = String.trim(key)
                clean_value = String.trim(value) |> String.trim("'\"")
                Map.put(acc, clean_key, clean_value)

              [single_arg] ->
                Map.put(acc, "query", String.trim(single_arg) |> String.trim("'\""))
            end
          end)

        {:ok, args}
      rescue
        _ -> {:error, "Invalid argument format"}
      end
    end

    defp find_tool(tool_name, tools) do
      case Enum.find(tools, &(&1.name == tool_name)) do
        nil -> {:error, "Tool '#{tool_name}' not found"}
        tool -> {:ok, tool}
      end
    end

    defp call_tool(%Tool{} = tool, args, callbacks) do
      call_id = System.unique_integer([:positive, :monotonic])
      timeout = tool.timeout || 30_000

      notify_tool_start(callbacks, call_id, tool, args)

      task =
        Task.async(fn ->
          try do
            {:ok, tool.function.(args)}
          rescue
            e ->
              {:error,
               %{
                 kind: :exception,
                 message: Exception.message(e)
               }}
          end
        end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {:ok, result}} ->
          notify_tool_end(callbacks, call_id, tool, result, nil)
          {:ok, result}

        {:ok, {:error, error}} ->
          notify_tool_end(callbacks, call_id, tool, nil, error)
          {:error, "Tool execution failed: #{error.message}"}

        nil ->
          error = %{kind: :timeout, message: "Tool execution timed out"}
          notify_tool_end(callbacks, call_id, tool, nil, error)
          {:error, error.message}
      end
    end

    defp notify_tool_start(callbacks, call_id, tool, inputs) do
      Enum.each(callbacks || [], fn
        {mod, state} ->
          try do
            mod.on_tool_start(call_id, tool, inputs, state)
          rescue
            e ->
              Logger.debug(
                "Tool callback on_tool_start failed: #{inspect(mod)} #{Exception.message(e)}"
              )

              :ok
          end
      end)

      :ok
    end

    defp notify_tool_end(callbacks, call_id, tool, outputs, error) do
      Enum.each(callbacks || [], fn
        {mod, state} ->
          try do
            mod.on_tool_end(call_id, tool, outputs, error, state)
          rescue
            e ->
              Logger.debug(
                "Tool callback on_tool_end failed: #{inspect(mod)} #{Exception.message(e)}"
              )

              :ok
          end
      end)

      :ok
    end

    defp extract_reasoning_trace(history) do
      history
      |> Enum.filter(fn {type, _content, _step} -> type == :thought end)
      |> Enum.map(fn {_type, content, step} -> "Step #{step}: #{content}" end)
      |> Enum.join("\n")
    end
  end

  # Predefined useful tools

  def builtin_tools do
    [
      %Tool{
        name: "search",
        description: "Search for information on the internet",
        function: &search_tool/1,
        parameters: [
          %{name: "query", type: "string", description: "Search query"},
          %{name: "num_results", type: "integer", description: "Number of results to return"}
        ],
        return_type: :list,
        timeout: 10_000,
        retry_attempts: 2
      },
      %Tool{
        name: "calculate",
        description: "Perform mathematical calculations",
        function: &calculate_tool/1,
        parameters: [
          %{
            name: "expression",
            type: "string",
            description: "Mathematical expression to evaluate"
          }
        ],
        return_type: :number,
        timeout: 5_000,
        retry_attempts: 1
      },
      %Tool{
        name: "datetime",
        description: "Get current date and time information",
        function: &datetime_tool/1,
        parameters: [
          %{name: "format", type: "string", description: "Date format (optional)"}
        ],
        return_type: :string,
        timeout: 1_000,
        retry_attempts: 1
      }
    ]
  end

  # Tool implementations

  defp search_tool(%{"query" => query} = args) do
    num_results = Map.get(args, "num_results", 5)

    # Mock search implementation - would integrate with real search API
    results =
      [
        %{
          title: "Result 1 for: #{query}",
          url: "https://example.com/1",
          snippet: "Sample result..."
        },
        %{
          title: "Result 2 for: #{query}",
          url: "https://example.com/2",
          snippet: "Another result..."
        }
      ]
      |> Enum.take(num_results)

    titles = results |> Enum.map(& &1.title) |> Enum.join(", ")
    "Found #{length(results)} results for '#{query}': #{titles}"
  end

  defp calculate_tool(%{"expression" => expression}) do
    # NOTE: do NOT use Code.eval_string/1 here; tools are model-driven and must be safe.
    case Dspy.Tools.SafeMath.eval(expression) do
      {:ok, result} -> "#{expression} = #{result}"
      {:error, reason} -> "Error: #{reason}"
    end
  end

  defp datetime_tool(args) do
    format = Map.get(args, "format", "%Y-%m-%d %H:%M:%S")

    case DateTime.now("Etc/UTC") do
      {:ok, dt} ->
        case Calendar.strftime(dt, format) do
          formatted -> "Current time: #{formatted}"
        end

      {:error, _} ->
        "Error: Could not get current time"
    end
  end

  # Public API

  defp ensure_tool_registry_started do
    case Process.whereis(ToolRegistry) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case ToolRegistry.start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Register a tool in the global registry.

  The ToolRegistry is started on-demand.
  """
  def register_tool(%Tool{} = tool) do
    case ensure_tool_registry_started() do
      :ok -> ToolRegistry.register_tool(tool)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get a tool by name from the registry.

  The ToolRegistry is started on-demand.
  """
  def get_tool(name) do
    case ensure_tool_registry_started() do
      :ok -> ToolRegistry.get_tool(name)
      {:error, _reason} -> nil
    end
  end

  @doc """
  List all registered tools.

  The ToolRegistry is started on-demand.
  """
  def list_tools do
    case ensure_tool_registry_started() do
      :ok -> ToolRegistry.list_tools()
      {:error, _reason} -> []
    end
  end

  @doc """
  Search for tools by name or description.

  The ToolRegistry is started on-demand.
  """
  def search_tools(query) do
    case ensure_tool_registry_started() do
      :ok -> ToolRegistry.search_tools(query)
      {:error, _reason} -> []
    end
  end

  @doc """
  Create a new tool.
  """
  def new_tool(name, description, function, opts \\ []) do
    %Tool{
      name: name,
      description: description,
      function: function,
      parameters: opts[:parameters] || [],
      return_type: opts[:return_type] || :any,
      examples: opts[:examples] || [],
      timeout: opts[:timeout] || 30_000,
      retry_attempts: opts[:retry_attempts] || 3,
      validation_schema: opts[:validation_schema]
    }
  end

  @doc """
  Execute a tool with arguments.
  """
  def execute_tool(%Tool{} = tool, args, opts \\ []) do
    timeout = opts[:timeout] || tool.timeout

    task =
      Task.async(fn ->
        try do
          result = tool.function.(args)
          {:ok, result}
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, "Tool execution timed out"}
    end
  end

  @doc """
  Create a ReAct agent with the given language model and tools.
  """
  def create_react_agent(lm, tools \\ [], opts \\ []) do
    all_tools = builtin_tools() ++ tools
    React.new(lm, all_tools, opts)
  end

  @doc """
  Initialize the tool system.
  """
  def start_link(opts \\ []) do
    children = [
      {ToolRegistry, opts}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
