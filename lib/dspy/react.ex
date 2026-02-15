defmodule Dspy.ReAct do
  @moduledoc """
  Signature-driven ReAct (Reasoning + Acting) module.

  This module is intended to mirror Python DSPy’s ReAct shape: an iterative
  tool-selection loop implemented via `Dspy.Predict`, followed by a final
  extraction step implemented via `Dspy.ChainOfThought`.

  Compared to `Dspy.Tools.React`, this module is signature-polymorphic and
  participates in adapter-driven prompt formatting/parsing.
  """

  use Dspy.Module

  alias Dspy.{ChainOfThought, Predict, Prediction, Signature}
  alias Dspy.Tools.Tool

  defstruct [
    :signature,
    :tools,
    :max_steps,
    :adapter,
    :step_signature,
    :extract_signature,
    :step_predictor,
    :extractor
  ]

  @type t :: %__MODULE__{
          signature: Signature.t(),
          tools: %{optional(String.t()) => Tool.t()},
          max_steps: pos_integer(),
          adapter: module() | nil,
          step_signature: Signature.t(),
          extract_signature: Signature.t(),
          step_predictor: Predict.t(),
          extractor: ChainOfThought.t()
        }

  @doc """
  Create a new ReAct module.

  `signature` may be:
  - a signature module (`use Dspy.Signature`)
  - a `%Dspy.Signature{}`
  - an arrow signature string (e.g. `"question -> answer"`)

  `tools` is a list of `%Dspy.Tools.Tool{}`.

  Options:
  - `:max_steps` (default: 10)
  - `:adapter` optional signature adapter override (defaults to global settings)
  """
  @spec new(Signature.t() | module() | binary(), [Tool.t()], keyword()) :: t()
  def new(signature, tools, opts \\ []) when is_list(tools) and is_list(opts) do
    base_signature = get_signature(signature)

    tools_by_name = normalize_tools!(tools)

    adapter = Keyword.get(opts, :adapter)
    max_steps = Keyword.get(opts, :max_steps, 10)

    step_signature = build_step_signature(base_signature, tools_by_name)
    extract_signature = build_extract_signature(base_signature)

    step_predictor = Predict.new(step_signature, adapter: adapter)
    extractor = ChainOfThought.new(extract_signature, adapter: adapter)

    %__MODULE__{
      signature: base_signature,
      tools: tools_by_name,
      max_steps: max_steps,
      adapter: adapter,
      step_signature: step_signature,
      extract_signature: extract_signature,
      step_predictor: step_predictor,
      extractor: extractor
    }
  end

  @impl true
  def forward(%__MODULE__{} = react, inputs) when is_map(inputs) do
    with :ok <- Signature.validate_inputs(react.signature, inputs),
         {:ok, trajectory} <- run_steps(react, inputs),
         {:ok, prediction} <- extract_final(react, inputs, trajectory) do
      attrs = Map.put(prediction.attrs, :trajectory, trajectory)
      {:ok, Prediction.new(attrs)}
    end
  end

  def forward(%__MODULE__{}, other), do: {:error, {:invalid_inputs, other}}

  # --- signature building ---

  defp build_step_signature(%Signature{} = base, tools_by_name) when is_map(tools_by_name) do
    tool_names = Map.keys(tools_by_name) |> Enum.sort()

    step_instructions = step_instructions(tool_names, tools_by_name)

    trajectory_field = %{
      name: :trajectory,
      type: :string,
      description: "Current tool-use trajectory so far",
      required: true,
      default: ""
    }

    output_fields = [
      %{
        name: :next_thought,
        type: :string,
        description: "Reasoning about what to do next",
        required: true,
        default: nil
      },
      %{
        name: :next_tool_name,
        type: :string,
        description: "Which tool to call next (or 'finish')",
        required: true,
        default: nil,
        one_of: tool_names ++ ["finish"]
      },
      %{
        name: :next_tool_args,
        type: :json,
        description: "Tool arguments as a JSON object",
        required: true,
        default: %{}
      }
    ]

    %Signature{
      Signature.new("react_step",
        input_fields: base.input_fields ++ [trajectory_field],
        output_fields: output_fields,
        instructions: step_instructions
      )
      | name: "react_step"
    }
  end

  defp build_extract_signature(%Signature{} = base) do
    trajectory_field = %{
      name: :trajectory,
      type: :string,
      description: "Full tool-use trajectory",
      required: true,
      default: ""
    }

    Signature.new("react_extract",
      input_fields: base.input_fields ++ [trajectory_field],
      output_fields: base.output_fields,
      instructions: base.instructions
    )
  end

  defp step_instructions(tool_names, tools_by_name) do
    tool_lines =
      tool_names
      |> Enum.map(fn name ->
        tool = Map.fetch!(tools_by_name, name)
        "- #{tool.name}: #{tool.description}"
      end)
      |> Enum.join("\n")

    """
    You are a tool-using agent.

    Choose the next tool to call, or choose finish when you can answer.

    Available tools:
    #{tool_lines}

    IMPORTANT:
    - next_tool_name MUST be one of: #{Enum.join(tool_names ++ ["finish"], ", ")}
    - next_tool_args MUST be a valid JSON object ({} if no args)
    """
    |> String.trim()
  end

  # --- loop ---

  defp run_steps(%__MODULE__{} = react, inputs) do
    do_run_steps(react, inputs, "", 0)
  end

  defp do_run_steps(%__MODULE__{} = react, inputs, trajectory, step)
       when step < react.max_steps do
    step_inputs = Map.put(inputs, :trajectory, trajectory)

    with {:ok, step_pred} <- Dspy.Module.forward(react.step_predictor, step_inputs),
         %{next_tool_name: tool_name, next_tool_args: tool_args, next_thought: thought} <-
           step_pred.attrs do
      cond do
        tool_name == "finish" ->
          {:ok, trajectory}

        true ->
          {obs_kind, observation} = execute_tool_step(react.tools, tool_name, tool_args)

          next_trajectory =
            trajectory <>
              format_trajectory_entry(step, thought, tool_name, tool_args, obs_kind, observation)

          do_run_steps(react, inputs, next_trajectory, step + 1)
      end
    else
      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_step_outputs, other}}
    end
  end

  defp do_run_steps(%__MODULE__{} = react, _inputs, trajectory, _step) do
    {:ok,
     trajectory <>
       format_trajectory_entry(react.max_steps, "", "finish", %{}, :error, "max steps reached")}
  end

  defp execute_tool_step(tools_by_name, tool_name, tool_args)
       when is_map(tools_by_name) and is_binary(tool_name) do
    case Map.fetch(tools_by_name, tool_name) do
      {:ok, %Tool{} = tool} ->
        case Dspy.Tools.execute_tool(tool, tool_args) do
          {:ok, result} ->
            {:ok, stringify_observation(result)}

          {:error, reason} ->
            {:error, stringify_observation(reason)}
        end

      :error ->
        {:error, "unknown tool: #{tool_name}"}
    end
  end

  defp stringify_observation(result) when is_binary(result), do: result
  defp stringify_observation(result), do: inspect(result, pretty: false, limit: 100)

  defp format_trajectory_entry(step, thought, tool_name, tool_args, obs_kind, observation) do
    args =
      case Jason.encode(tool_args) do
        {:ok, json} -> json
        _ -> inspect(tool_args, pretty: false, limit: 50)
      end

    kind = if obs_kind == :ok, do: "Observation", else: "Observation (error)"

    """

    Step #{step + 1}
    Thought: #{String.trim(to_string(thought))}
    Tool: #{tool_name}
    Args: #{args}
    #{kind}: #{String.trim(to_string(observation))}
    """
  end

  defp extract_final(%__MODULE__{} = react, inputs, trajectory) do
    extract_inputs = Map.put(inputs, :trajectory, trajectory)
    Dspy.Module.forward(react.extractor, extract_inputs)
  end

  # --- helpers ---

  defp normalize_tools!(tools) when is_list(tools) do
    tools
    |> Enum.reduce(%{}, fn
      %Tool{name: name} = tool, acc when is_binary(name) ->
        Map.put(acc, name, tool)

      other, _acc ->
        raise ArgumentError,
              "Dspy.ReAct tools must be a list of %Dspy.Tools.Tool{}; got: #{inspect(other)}"
    end)
  end

  defp get_signature(signature) when is_atom(signature), do: signature.signature()
  defp get_signature(signature) when is_binary(signature), do: Signature.define(signature)
  defp get_signature(%Signature{} = signature), do: signature
end
