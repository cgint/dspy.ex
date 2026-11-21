defmodule Dspy.Module do
  @moduledoc """
  Behaviour for composable DSPy modules.

  Modules are the building blocks of DSPy programs. They define
  forward passes for inference and can contain optimizable parameters.
  """

  alias Dspy.Lifecycle
  alias Dspy.Module.{PredictorSlots, ProgramState}
  alias Dspy.Signature.Adapter.Callbacks

  @type t :: struct()
  @type inputs :: map() | keyword() | Dspy.Example.t()
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
  - a `%Dspy.Example{}` (converted via `Dspy.Example.inputs/1`)
  """
  def forward(module, inputs) do
    {track_usage, global_callbacks} = Dspy.Settings.module_observability()

    with %{__struct__: type} when is_atom(type) <- module,
         [_ | _] = callbacks <-
           Callbacks.module_handlers(global_callbacks, program_callbacks(module)) do
      Lifecycle.run(type, callbacks, {:module_start, :module_end}, fn ->
        forward_with_usage(module, inputs, track_usage)
      end)
    else
      _ -> forward_with_usage(module, inputs, track_usage)
    end
  end

  defp program_callbacks(%{__struct__: type} = module)
       when type in [Dspy.Predict, Dspy.ChainOfThought],
       do: Map.get(module, :callbacks)

  defp program_callbacks(_module), do: []

  defp forward_with_usage(module, inputs, true) do
    outer? = Dspy.LM.UsageAcc.enter()

    result =
      try do
        forward_untracked(module, inputs)
      catch
        kind, reason ->
          Dspy.LM.UsageAcc.exit()
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    usage = Dspy.LM.UsageAcc.exit()

    if outer? do
      attach_usage_to_result(result, usage)
    else
      result
    end
  end

  defp forward_with_usage(module, inputs, _track_usage), do: forward_untracked(module, inputs)

  defp forward_untracked(module, %Dspy.Example{} = example) do
    forward_untracked(module, Dspy.Example.inputs(example))
  end

  defp forward_untracked(module, inputs) when is_list(inputs) do
    if Keyword.keyword?(inputs) do
      forward_untracked(module, Map.new(inputs))
    else
      module.__struct__.forward(module, inputs)
    end
  end

  defp forward_untracked(module, inputs) do
    module.__struct__.forward(module, inputs)
  end

  defp attach_usage_to_result({:ok, %Dspy.Prediction{} = pred}, usage) do
    if is_map(usage) do
      metadata = Map.put(pred.metadata || %{}, :lm_usage, usage)
      {:ok, %{pred | metadata: metadata}}
    else
      {:ok, pred}
    end
  end

  defp attach_usage_to_result(other, _usage), do: other

  @doc """
  List the named Predict and ChainOfThought values in a program.

  Names follow declared module fields and the immediate entries of proper list,
  tuple and map fields. The same predictor value in multiple slots appears at each name.
  A standalone Predict is named `self`. ChainOfThought contributes `predict`
  within its slot and is returned as the native ChainOfThought value.

  Raises `ArgumentError` if `program` is not a module struct implementing `forward/2`.
  """
  @spec named_predictors(t()) :: [{String.t(), PredictorSlots.predictor()}]
  def named_predictors(program) do
    for {path, predictor} <- PredictorSlots.list(program) do
      {PredictorSlots.name(path, predictor), predictor}
    end
  end

  @doc """
  Return the predictor values in the same order as `named_predictors/1`.
  """
  @spec predictors(t()) :: [PredictorSlots.predictor()]
  def predictors(program) do
    for {_path, predictor} <- PredictorSlots.list(program), do: predictor
  end

  @doc """
  Return a new program with each discovered predictor replaced by `fun`'s result.

  The unary function receives each predictor once in `named_predictors/1` order.
  Equal predictor values in separate slots are visited separately. A standalone
  predictor returns the function's result directly. A program without predictors
  is returned as given.
  """
  @spec map_named_predictors(t(), (PredictorSlots.predictor() -> term())) :: term()
  def map_named_predictors(program, fun) when is_function(fun, 1) do
    PredictorSlots.map(program, fn _path, predictor -> fun.(predictor) end)
  end

  @doc """
  Return a program with the same LM binding on every named predictor.

  Pass `nil` to clear the bindings and let the predictors use the configured
  LM at call time.
  """
  @spec set_lm(t(), Dspy.LM.t() | nil) :: t()
  def set_lm(program, lm) do
    lm = Dspy.LM.validate_binding!(lm)
    map_named_predictors(program, &Map.put(&1, :lm, lm))
  end

  @doc """
  Return the LM binding shared by all named predictors.

  Reads stored bindings and returns `nil` when all predictors are unbound.
  Raises `ArgumentError` when the program has no named predictors or their
  bindings differ.
  """
  @spec get_lm(t()) :: Dspy.LM.t() | nil
  def get_lm(program) do
    bindings = program |> predictors() |> Enum.map(&Map.get(&1, :lm)) |> Enum.uniq()

    case bindings do
      [lm] -> lm
      [] -> raise ArgumentError, "program has no predictors"
      _ -> raise ArgumentError, "program has different LM bindings"
    end
  end

  @doc """
  Return a program with demos and stored LM bindings cleared on each named predictor.

  Reset predictors use the configured LM on their next call. Signatures and
  generation options carry over to the result.
  """
  @spec reset_copy(t()) :: t()
  def reset_copy(program) do
    map_named_predictors(program, &Map.merge(&1, %{examples: [], lm: nil}))
  end

  @doc """
  Save a native JSON v1 checkpoint of the program's predictor state.

  The document stores instructions, ordered demos, and generation config by
  typed predictor slot. Supply `lms: %{"name" => lm}` to name any bound LM.
  Only the name is saved. The filename is caller-selected.

  Demos are `Dspy.Example` values with portable attributes and metadata. Values
  can contain numbers, booleans, nil, UTF-8 strings, lists, and plain maps.
  Attribute map keys can be strings or atoms declared by any predictor signature
  in the program.
  Metadata keys can be strings and the top-level `:inputs` atom. Slots in
  maps support atoms, UTF-8 strings, and integer keys.

  Returns `:ok` after atomic publication or `{:error, reason}` on failure.
  """
  @spec save_state(t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def save_state(program, path, opts \\ []), do: ProgramState.save(program, path, opts)

  @doc """
  Restore a native JSON v1 checkpoint into a caller-built program.

  The target must match the checkpoint's typed predictor slots, predictor
  kinds, and ordered input and output field names. The target supplies the
  field definitions, adapters, callbacks, retry options, and program structure.
  Provide an LM registry with `lms: %{"name" => lm}` to resolve named bindings.
  A null reference restores an unbound predictor.

  Returns `{:ok, restored_program}` or `{:error, reason}` for a rejected
  checkpoint. The returned program is hydrated only after full validation.
  """
  @spec load_state(t(), Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load_state(program, path, opts \\ []), do: ProgramState.load(program, path, opts)

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

  Options:

  * `:timeout` — maximum time (in ms, or `:infinity`) to wait for all modules
    to complete. Defaults to `:infinity`. Tasks that do not return by the
    deadline are killed via `Task.shutdown/2` and reported as
    `{:error, :timeout}` in that slot.
  """
  def parallel(modules, opts \\ []) when is_list(modules) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    fn inputs ->
      # Run each module in a separate task. Each task's body carries a child-side
      # catch-all (rescue + catch) so that an exception, throw, or exit inside
      # `forward/2` is captured and returned to the caller as `{:error, ...}`
      # rather than crashing the task process and (pre-fix) the caller.
      #
      # We use `Task.yield_many/2` + `Task.shutdown/2` instead of
      # `Task.await_many/2` (which re-raises the first task's exit in the
      # caller, and whose default 5 s timeout exits the caller). Tasks that did
      # not return by the deadline are killed with `Task.shutdown/2` so they
      # cannot outlive the call or leak LM connections.
      #
      # `Task.yield_many/2` wraps the body's return value in `{:ok, _}` (or
      # returns `nil` on timeout). The body returns `{:ok, prediction}` or
      # `{:error, reason}`, so we unwrap the outer `{:ok, _}` to recover the
      # body's result. A non-`{:ok, _}` yield (e.g. `{:exit, _}`) is a crash
      # the child catch-all did not cover; we kill the task and surface it.
      #
      # Capture process-local DSPy state (overrides + callback stack) in the
      # caller; reinstall it in each task (tasks do not inherit the dictionary).
      ctx = Dspy.Context.capture()

      tasks =
        modules
        |> Enum.map(fn module ->
          Task.async(fn ->
            Dspy.Context.with_context(ctx, fn ->
              try do
                forward(module, inputs)
              rescue
                e -> {:error, {:raised, e}}
              catch
                :exit, reason -> {:error, {:exit, reason}}
                kind, reason -> {:error, {:thrown, kind, reason}}
              end
            end)
          end)
        end)

      results =
        Task.yield_many(tasks, timeout)
        |> Enum.map(fn
          {_task, {:ok, body_result}} ->
            body_result

          {task, nil} ->
            Task.shutdown(task, :brutal_kill)
            {:error, :timeout}

          {task, other} ->
            Task.shutdown(task, :brutal_kill)
            {:error, other}
        end)

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
