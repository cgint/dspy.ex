defmodule Dspy.Teleprompt.GEPAInstructionProposerTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Predict, Settings, Signature}
  alias Dspy.Signature.Adapters.{ChatAdapter, Default, JSONAdapter, XMLAdapter}
  alias Dspy.Teleprompt.GEPA
  alias GEPA.InstructionProposer

  @starting "Answer zero."
  @improved "Four."
  @decomposed "e\u0301abcd"

  defmodule WireAdapter do
    @behaviour Dspy.Signature.Adapter

    @impl true
    def format_instructions(_signature, _opts), do: "Use test wire format."

    @impl true
    def format_request(signature, inputs, _demos, _opts) do
      content =
        Jason.encode!(%{
          instructions: signature.instructions,
          inputs: inputs,
          outputs: Enum.map(signature.output_fields, & &1.name),
          wire: "configured-adapter"
        })

      %{messages: [%{role: "user", content: content}]}
    end

    @impl true
    defdelegate parse_outputs(signature, text, opts), to: JSONAdapter
  end

  defmodule RolloutLM do
    @behaviour Dspy.LM
    defstruct [:owner]

    @impl true
    def generate(%__MODULE__{owner: owner}, request) do
      prompt = List.last(request.messages).content
      row = if prompt =~ "held-out row", do: :held_out, else: :training
      answer = if prompt =~ "Four.", do: "4", else: "0"
      send(owner, {:rollout, row, answer, Settings.get(:adapter), Settings.get(:lm)})
      {:ok, Jason.encode!(%{answer: answer})}
    end
  end

  defmodule ReflectionLM do
    @behaviour Dspy.LM
    defstruct [:owner, :draft, :correction]

    @impl true
    def generate(%__MODULE__{} = lm, request) do
      prompt = List.last(request.messages).content

      {wire, [output]} =
        case Jason.decode(prompt) do
          {:ok, %{"wire" => "configured-adapter", "outputs" => fields} = wire} -> {wire, fields}
          _legacy -> {prompt, request.output_contract["required"]}
        end

      send(lm.owner, {:reflection, output, wire})
      text = if output == "shortened_instruction", do: lm.correction, else: lm.draft
      {:ok, Jason.encode!(%{output => text})}
    end
  end

  defmodule NativeWireLM do
    @behaviour Dspy.LM
    alias Dspy.Signature.Adapters.{ChatAdapter, Default, XMLAdapter}

    defstruct [:owner, :adapter, :draft, :correction]

    @impl true
    def generate(lm, %{messages: messages}) do
      prompt = Enum.map_join(messages, "\n", & &1.content)

      {field, value} =
        if prompt =~ "Shorten the instruction",
          do: {"shortened_instruction", lm.correction},
          else: {"new_instruction", lm.draft}

      send(lm.owner, {:native_reflection, field, prompt})
      {:ok, render(lm.adapter, field, value)}
    end

    defp render(_adapter, field, value) when not is_binary(value),
      do: Jason.encode!(%{field => value})

    defp render(Default, field, value),
      do: "#{String.capitalize(field)}: #{value}"

    defp render(ChatAdapter, field, value),
      do: "[[ ## #{field} ## ]]\n#{value}"

    defp render(XMLAdapter, field, value),
      do: "<#{field}>#{value}</#{field}>"
  end

  @tag :tmp_dir
  test "configured reflection corrects a code-point overflow before scoring in the same budget",
       %{tmp_dir: tmp_dir} do
    directory = Path.join(tmp_dir, "reference")
    File.mkdir!(directory)
    path = Path.join(directory, "SKILL.md")
    File.write!(path, "ORIGINAL_FILE_SKILL")
    standalone_path = Path.join(tmp_dir, " standalone.md ")
    File.write!(standalone_path, "STANDALONE_FILE_SKILL")

    config =
      InstructionProposer.new(
        base_instructions: "  CUSTOM_BASE  ",
        additional_instructions: "CUSTOM_ADDITIONAL",
        skills: ["./inline/reference.md", {:path, directory}, {:path, standalone_path}],
        max_chars: 5,
        adapter: WireAdapter
      )

    File.write!(path, "REPLACEMENT_FILE_SKILL")
    lm = reflection("  #{@decomposed}  ", "  #{@improved}  ")
    optimizer = optimizer(config, reflection_lm: lm, max_metric_calls: 4)
    program = program()

    Dspy.context([adapter: Default, lm: nil, cache: false], fn ->
      assert {:ok, optimized} = compile(optimizer, program)
      assert optimized.signature.instructions == @improved
      assert program.signature.instructions == @starting
      assert Settings.get(:lm) == nil
      assert Settings.get(:adapter) == Default

      assert_received {:reflection, "new_instruction",
                       %{"instructions" => "CUSTOM_BASE", "inputs" => inputs}}

      assert inputs["current_instruction"] == @starting
      assert inputs["additional_instructions"] == "CUSTOM_ADDITIONAL"
      assert inputs["reference_skills"] =~ "./inline/reference.md"
      assert inputs["reference_skills"] =~ "ORIGINAL_FILE_SKILL"
      assert inputs["reference_skills"] =~ "STANDALONE_FILE_SKILL"
      refute inputs["reference_skills"] =~ "REPLACEMENT_FILE_SKILL"
      assert inputs["length_limit"] =~ "5"
      assert inputs["examples_with_feedback"] =~ "training row"
      refute inputs["examples_with_feedback"] =~ "held-out row"

      assert_received {:reflection, "shortened_instruction",
                       %{"inputs" => %{"instruction" => @decomposed, "length_limit" => limit}}}

      assert limit =~ "5"
      refute_received {:reflection, _, _}

      assert_rollouts([
        {:held_out, "0", nil},
        {:training, "0", nil},
        {:training, "4", nil},
        {:held_out, "4", nil}
      ])
    end)
  end

  test "one oversized correction fails before any candidate evaluation" do
    config = InstructionProposer.new(max_chars: 5, adapter: WireAdapter)
    lm = reflection(@decomposed, "still long")

    Dspy.context([adapter: Default, lm: nil, cache: false], fn ->
      assert {:error, {:reflection_failed, :instruction_too_long}} =
               compile(optimizer(config, reflection_lm: lm), program())

      assert_received {:reflection, "new_instruction", %{"wire" => "configured-adapter"}}
      assert_received {:reflection, "shortened_instruction", %{"wire" => "configured-adapter"}}
      refute_received {:reflection, _, _}
      assert_rollouts([{:held_out, "0", nil}, {:training, "0", nil}])
    end)
  end

  test "blank and invalid text responses fail with a static proposal error" do
    config = InstructionProposer.new(max_chars: 5, adapter: WireAdapter)

    Dspy.context([adapter: Default, lm: nil, cache: false], fn ->
      for {draft, correction, expected_calls} <- [
            {"  ", nil, ["new_instruction"]},
            {%{"private" => "LEAK_MARKER"}, nil, ["new_instruction"]},
            {123, nil, ["new_instruction"]},
            {@decomposed, " \n ", ["new_instruction", "shortened_instruction"]}
          ] do
        lm = reflection(draft, correction)

        assert {:error, {:reflection_failed, :invalid_instruction_proposal}} =
                 compile(optimizer(config, reflection_lm: lm), program())

        for output <- expected_calls do
          assert_received {:reflection, ^output, %{"wire" => "configured-adapter"}}
        end

        refute_received {:reflection, _, _}
        assert_rollouts([{:held_out, "0", nil}, {:training, "0", nil}])
      end
    end)
  end

  test "the configured proposer respects the final instruction byte limit" do
    config = InstructionProposer.new(max_chars: 4_097)
    lm = reflection(String.duplicate("x", 4_097), nil)

    Dspy.context([adapter: Default, lm: nil, cache: false], fn ->
      assert {:error, {:reflection_failed, :instruction_too_long}} =
               compile(optimizer(config, reflection_lm: lm), program())

      assert_received {:reflection, "new_instruction", _prompt}
      refute_received {:reflection, _, _}
      assert_rollouts([{:held_out, "0", nil}, {:training, "0", nil}])
    end)
  end

  test "native text adapters use their usual wire format for proposal and correction" do
    Dspy.context([adapter: Default, lm: nil, cache: false], fn ->
      for {adapter, proposal_marker, correction_marker} <- [
            {Default, "New_instruction:", "Shortened_instruction:"},
            {ChatAdapter, "[[ ## new_instruction ## ]]", "[[ ## shortened_instruction ## ]]"},
            {XMLAdapter, "<new_instruction>", "<shortened_instruction>"}
          ] do
        config = InstructionProposer.new(max_chars: 5, adapter: adapter)

        lm = %NativeWireLM{
          owner: self(),
          adapter: adapter,
          draft: @decomposed,
          correction: @improved
        }

        assert {:ok, optimized} = compile(optimizer(config, reflection_lm: lm), program())
        assert optimized.signature.instructions == @improved
        assert_received {:native_reflection, "new_instruction", proposal}
        assert proposal =~ proposal_marker
        assert_received {:native_reflection, "shortened_instruction", correction}
        assert correction =~ correction_marker
        refute_received {:native_reflection, _, _}
        assert_rollouts([{:held_out, "0", nil}, {:training, "0", nil}, {:held_out, "4", nil}])
      end
    end)
  end

  test "text adapters reject nonstring JSON values before scoring a candidate" do
    Dspy.context([adapter: Default, lm: nil, cache: false], fn ->
      for adapter <- [Default, ChatAdapter], draft <- [123, %{"text" => "Four."}] do
        config = InstructionProposer.new(adapter: adapter)
        lm = %NativeWireLM{owner: self(), adapter: adapter, draft: draft}

        assert {:error, {:reflection_failed, :invalid_instruction_proposal}} =
                 compile(optimizer(config, reflection_lm: lm), program())

        assert_received {:native_reflection, "new_instruction", _}
        refute_received {:native_reflection, _, _}
        assert_rollouts([{:held_out, "0", nil}, {:training, "0", nil}])
      end
    end)
  end

  test "a proposer alone uses the ambient LM and defaults to JSONAdapter" do
    config = InstructionProposer.new()
    lm = reflection(@improved, nil)

    Dspy.context([adapter: Default, lm: lm, cache: false], fn ->
      assert {:ok, optimized} = compile(optimizer(config), program())
      assert optimized.signature.instructions == @improved
      assert Settings.get(:lm) == lm
      assert Settings.get(:adapter) == Default
      assert_received {:reflection, "new_instruction", prompt}
      assert is_binary(prompt)
      assert prompt =~ "training row"
      refute_received {:reflection, _, _}

      assert_rollouts([
        {:held_out, "0", lm},
        {:training, "0", lm},
        {:held_out, "4", lm}
      ])
    end)
  end

  @tag :tmp_dir
  test "validates configuration and explicit skill paths before any rollout", %{tmp_dir: tmp_dir} do
    bad_text = Path.join(tmp_dir, "binary.md")
    File.write!(bad_text, <<255>>)

    for {options, message} <- [
          {[max_chars: 0], ~r/max_chars/},
          {[max_chars: true], ~r/max_chars/},
          {[max_chars: 1.5], ~r/max_chars/},
          {[adapter: String], ~r/adapter/},
          {[base_instructions: 42], ~r/base_instructions/},
          {[additional_instructions: <<255>>], ~r/additional_instructions/},
          {[skills: ["   "]], ~r/skills/},
          {[skills: {:path, bad_text}], ~r/skills/},
          {[skills: {:path, Path.join(tmp_dir, "missing.md")}], ~r/skills/},
          {[skills: {:path, tmp_dir}], ~r/skills/},
          {[unknown: true], ~r/unknown/}
        ] do
      assert_raise ArgumentError, message, fn -> InstructionProposer.new(options) end
    end

    refute_received {:rollout, _, _, _, _}
  end

  defp program do
    signature = %{Signature.define("question -> answer") | instructions: @starting}
    Predict.new(signature, lm: %RolloutLM{owner: self()}, adapter: JSONAdapter, max_retries: 0)
  end

  defp reflection(draft, correction),
    do: %ReflectionLM{owner: self(), draft: draft, correction: correction}

  defp optimizer(config, opts \\ []) do
    defaults = [
      metric: fn _example, prediction, _trace, _name, _steps ->
        if prediction[:answer] == "4", do: 1.0, else: 0.0
      end,
      instruction_proposer: config,
      max_metric_calls: 3,
      num_threads: 1,
      candidate_selection_strategy:
        if(opts[:max_metric_calls] == 4, do: :pareto, else: :current_best)
    ]

    GEPA.new(Keyword.merge(defaults, opts))
  end

  defp compile(optimizer, program) do
    training = [Example.new(question: "training row") |> Example.with_inputs(:question)]
    validation = [Example.new(question: "held-out row") |> Example.with_inputs(:question)]
    GEPA.compile(optimizer, program, training, valset: validation)
  end

  defp assert_rollouts(expected) do
    for {row, answer, lm} <- expected do
      assert_received {:rollout, actual_row, actual_answer, Default, actual_lm}
      assert {actual_row, actual_answer, actual_lm} == {row, answer, lm}
    end

    refute_received {:rollout, _, _, _, _}
  end
end
