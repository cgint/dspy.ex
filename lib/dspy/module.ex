defmodule Dspy.Module do
  @moduledoc """
  Behaviour for composable DSPy modules.

  Modules are the building blocks of DSPy programs. They define
  forward passes for inference and can contain optimizable parameters.
  """

  @type t :: struct()
  @type inputs :: map() | keyword()
  @type outputs :: Dspy.Prediction.t()

  @doc """
  Execute the module's forward pass.
  """
  @callback forward(module :: t(), inputs :: inputs()) :: {:ok, outputs()} | {:error, any()}

  @doc """
  Get the module's optimizable parameters.
  """
  @callback parameters(module :: t()) :: [Dspy.Parameter.t()]

  @doc """
  Update the module with new parameters.
  """
  @callback update_parameters(module :: t(), parameters :: [Dspy.Parameter.t()]) :: t()

  @optional_callbacks [parameters: 1, update_parameters: 2]

  defmacro __using__(_opts) do
    quote do
      @behaviour Dspy.Module

      def forward(module, inputs) do
        __MODULE__.forward(module, inputs)
      end

      defoverridable forward: 2
    end
  end

  @doc """
  Execute a module's forward pass.

  Accepts inputs as either:
  - a map (preferred)
  - a keyword list (kwargs-like; converted to a map)
  """
  def forward(module, inputs) when is_list(inputs) do
    if Keyword.keyword?(inputs) do
      forward(module, Map.new(inputs))
    else
      module.__struct__.forward(module, inputs)
    end
  end

  def forward(module, inputs) do
    module.__struct__.forward(module, inputs)
  end

  @doc """
  Get a module's parameters if it implements the callback.
  """
  def parameters(module) do
    if function_exported?(module.__struct__, :parameters, 1) do
      module.__struct__.parameters(module)
    else
      []
    end
  end

  @doc """
  Update a module's parameters if it implements the callback.
  """
  def update_parameters(module, parameters) do
    if function_exported?(module.__struct__, :update_parameters, 2) do
      module.__struct__.update_parameters(module, parameters)
    else
      module
    end
  end

  @doc """
  Export a module's optimizable parameters.

  This is an explicit, error-returning variant of `parameters/1` intended for
  persistence/teleprompt workflows.

  ## Returns

  - `{:ok, params}` when the module implements `c:parameters/1`
  - `{:error, {:unsupported_program, mod}}` otherwise
  """
  @spec export_parameters(t()) :: {:ok, [Dspy.Parameter.t()]} | {:error, term()}
  def export_parameters(%_{} = module) do
    if function_exported?(module.__struct__, :parameters, 1) do
      params = module.__struct__.parameters(module)

      if is_list(params) and Enum.all?(params, &match?(%Dspy.Parameter{}, &1)) do
        {:ok, params}
      else
        {:error, {:invalid_parameters, params}}
      end
    else
      {:error, {:unsupported_program, module.__struct__}}
    end
  end

  def export_parameters(other), do: {:error, {:unsupported_program, other}}

  @doc """
  Apply a list of parameters to a module.

  ## Returns

  - `{:ok, updated_module}` when the module implements `c:update_parameters/2`
  - `{:error, {:unsupported_program, mod}}` otherwise
  """
  @spec apply_parameters(t(), [Dspy.Parameter.t()]) :: {:ok, t()} | {:error, term()}
  def apply_parameters(%_{} = module, parameters) when is_list(parameters) do
    cond do
      not Enum.all?(parameters, &match?(%Dspy.Parameter{}, &1)) ->
        {:error, {:invalid_parameters, parameters}}

      function_exported?(module.__struct__, :update_parameters, 2) ->
        {:ok, module.__struct__.update_parameters(module, parameters)}

      true ->
        {:error, {:unsupported_program, module.__struct__}}
    end
  end

  def apply_parameters(other, _parameters), do: {:error, {:unsupported_program, other}}

  @doc """
  Compose multiple modules in sequence.
  """
  def compose(modules) when is_list(modules) do
    fn inputs ->
      Enum.reduce_while(modules, {:ok, inputs}, fn module, {:ok, current_inputs} ->
        case forward(module, current_inputs) do
          {:ok, prediction} -> {:cont, {:ok, prediction.attrs}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc """
  Run modules in parallel and merge results.
  """
  def parallel(modules) when is_list(modules) do
    fn inputs ->
      tasks =
        modules
        |> Enum.map(fn module ->
          Task.async(fn -> forward(module, inputs) end)
        end)

      results = Task.await_many(tasks)

      case Enum.find(results, fn
             {:error, _} -> true
             _ -> false
           end) do
        {:error, reason} ->
          {:error, reason}

        nil ->
          merged_attrs =
            results
            |> Enum.map(fn {:ok, prediction} -> prediction.attrs end)
            |> Enum.reduce(%{}, &Map.merge/2)

          {:ok, Dspy.Prediction.new(merged_attrs)}
      end
    end
  end
end
