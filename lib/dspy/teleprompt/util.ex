defmodule Dspy.Teleprompt.Util do
  @moduledoc false

  alias Dspy.Parameter

  @type error_reason ::
          {:unsupported_program, term()}
          | {:parameter_not_applied, String.t()}
          | {:invalid_parameter_type, term()}
          | {:parameter_type_mismatch, String.t(), expected: atom(), got: atom()}

  @spec set_parameter(Dspy.Module.t(), String.t(), Dspy.Parameter.parameter_type(), any()) ::
          {:ok, Dspy.Module.t()} | {:error, error_reason()}
  def set_parameter(%_{} = program, name, type, value)
      when type in [:prompt, :examples, :weights, :custom] do
    if not function_exported?(program.__struct__, :update_parameters, 2) do
      {:error, {:unsupported_program, program.__struct__}}
    else
      params = Dspy.Module.parameters(program)

      if not is_list(params) || not Enum.all?(params, &match?(%Parameter{}, &1)) do
        {:error, {:unsupported_program, program.__struct__}}
      else
        case Enum.find(params, &match?(%Parameter{name: ^name}, &1)) do
          %Parameter{type: existing_type} when existing_type != type ->
            {:error, {:parameter_type_mismatch, name, expected: type, got: existing_type}}

          _ ->
            {updated, found?} =
              Enum.map_reduce(params, false, fn
                %Parameter{name: ^name} = p, _found? ->
                  {Parameter.update(p, value), true}

                other, found? ->
                  {other, found?}
              end)

            updated =
              if found? do
                updated
              else
                updated ++ [Parameter.new(name, type, value)]
              end

            updated_program = Dspy.Module.update_parameters(program, updated)

            applied? =
              updated_program
              |> Dspy.Module.parameters()
              |> Enum.any?(fn
                %Parameter{name: ^name, value: ^value} -> true
                _ -> false
              end)

            if applied? do
              {:ok, updated_program}
            else
              {:error, {:parameter_not_applied, name}}
            end
        end
      end
    end
  end

  def set_parameter(%_{} = _program, _name, type, _value) do
    {:error, {:invalid_parameter_type, type}}
  end

  def set_parameter(program, _name, _type, _value) do
    {:error, {:unsupported_program, program}}
  end

  @spec set_predict_instructions(Dspy.Module.t(), String.t()) ::
          {:ok, Dspy.Module.t()} | {:error, error_reason()}
  def set_predict_instructions(program, instruction) when is_binary(instruction) do
    set_parameter(program, "predict.instructions", :prompt, instruction)
  end

  @spec set_predict_examples(Dspy.Module.t(), list()) ::
          {:ok, Dspy.Module.t()} | {:error, error_reason()}
  def set_predict_examples(program, examples) when is_list(examples) do
    set_parameter(program, "predict.examples", :examples, examples)
  end
end
