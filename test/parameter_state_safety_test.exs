defmodule DspyParameterStateSafetyTest do
  use ExUnit.Case, async: true

  defmodule SafetySignature do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule NoParamsProgram do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_program, _inputs), do: {:ok, Dspy.Prediction.new(%{answer: "ok"})}
  end

  defp tmp_path(basename) do
    Path.join(
      System.tmp_dir!(),
      "dspy_state_safety_#{basename}_#{System.unique_integer([:positive, :monotonic])}.json"
    )
  end

  describe "parameter JSON payload safety" do
    test "decode_json/1 rejects malformed JSON with a tagged Jason error" do
      assert {:error, %Jason.DecodeError{}} = Dspy.Parameter.decode_json("not-json")
    end

    test "decode_json/1 rejects a non-list top-level payload" do
      assert {:error, :expected_parameter_list} = Dspy.Parameter.decode_json(~s({"name":"x"}))
    end

    test "decode_json/1 rejects malformed parameter entries" do
      payload = Jason.encode!([%{"type" => "prompt", "value" => "v", "metadata" => %{}}])

      assert {:error, {:invalid_parameter_name, nil}} = Dspy.Parameter.decode_json(payload)
    end

    test "decode_json/1 rejects unsupported external values in parameter maps" do
      payload =
        Jason.encode!([
          %{
            "dspy" => "parameter",
            "version" => 1,
            "name" => "x",
            "type" => "prompt",
            "value" => %{"bad" => [%{"nested" => :ok}]},
            "metadata" => []
          }
        ])

      assert {:error, {:invalid_metadata, []}} = Dspy.Parameter.decode_json(payload)
    end
  end

  describe "module parameter apply safety" do
    test "apply_parameters/2 rejects invalid parameter lists before updating the program" do
      program = Dspy.Predict.new(SafetySignature, examples: [])
      invalid_parameters = [Dspy.Parameter.new("predict.examples", :examples, []), %{bad: :param}]

      assert {:error, {:invalid_parameters, ^invalid_parameters}} =
               Dspy.Module.apply_parameters(program, invalid_parameters)

      assert program.examples == []
    end

    test "apply_parameters/2 returns a tagged unsupported-program error" do
      assert {:error, {:unsupported_program, NoParamsProgram}} =
               Dspy.Module.apply_parameters(%NoParamsProgram{}, [
                 Dspy.Parameter.new("x", :prompt, "y")
               ])

      assert {:error, {:unsupported_program, :not_a_program}} =
               Dspy.Module.apply_parameters(:not_a_program, [
                 Dspy.Parameter.new("x", :prompt, "y")
               ])
    end
  end

  describe "parameter file persistence errors" do
    test "read_json/1 reports invalid JSON from an existing file" do
      path = tmp_path("invalid")
      File.write!(path, "not-json")

      assert {:error, %Jason.DecodeError{}} = Dspy.Parameter.read_json(path)

      _ = File.rm(path)
    end

    test "write_json/2 returns a structured file write error when path is a directory" do
      dir = System.tmp_dir!()
      params = [Dspy.Parameter.new("x", :prompt, "y")]

      assert {:error, {:file_write_failed, ^dir, reason}} = Dspy.Parameter.write_json(params, dir)
      assert reason in [:eisdir, :eacces]
    end
  end
end
