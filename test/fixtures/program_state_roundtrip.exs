defmodule ProgramStateRoundtrip do
  import ExUnit.Assertions

  alias Dspy.{ChainOfThought, Example, Predict, Prediction, Signature}
  alias Dspy.Signature.Adapters.JSONAdapter
  alias Dspy.Teleprompt.BootstrapFewShotWithRandomSearch, as: BootstrapRS

  @left_instruction "Answer the question directly."
  @right_instruction "Explain the evidence for the answer."
  @left_config %{temperature: 0.0, max_completion_tokens: 18}
  @right_config %{temperature: 0.6, max_tokens: 72, rollout_id: nil}

  defmodule OfflineLM do
    @behaviour Dspy.LM
    defstruct [:model, :observer, :instance]

    @impl true
    def generate(lm, request) do
      if lm.observer, do: send(lm.observer, {:request, lm.model, request})

      result =
        case lm.model do
          "offline:predict" -> %{answer: "left answer"}
          "offline:cot" -> %{answer: "right answer", reasoning: "offline proof"}
        end

      {:ok, %{choices: [%{message: %{role: "assistant", content: Jason.encode!(result)}}]}}
    end
  end

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:slots]

    @impl true
    def forward(program, inputs) do
      question = Dspy.Attrs.get(inputs, :question)

      with {:ok, left} <- Dspy.Module.forward(program.slots[1], %{question: question <> "/left"}),
           {:ok, right} <-
             Dspy.Module.forward(program.slots["1"], %{"question" => question <> "/right"}) do
        {:ok, Dspy.Prediction.new(answer: left.attrs.answer <> " | " <> right.attrs.answer)}
      end
    end
  end

  def run(mode) do
    Logger.configure(level: :error)
    {:ok, _} = Application.ensure_all_started(:dspy)

    Dspy.context([cache: false], fn ->
      observation = checkpoint(mode)
      # Compare exact Elixir values without decoding a second persistence format.
      File.write!("#{mode}.etf", :erlang.term_to_binary(observation, [:deterministic]))
    end)
  end

  defp checkpoint("write") do
    lms = bindings(:writer)
    student = build_program()

    left =
      configure(student.slots[1], %{lms["left"] | observer: nil}, @left_instruction, @left_config)

    right =
      configure(
        student.slots["1"],
        %{lms["right"] | observer: nil},
        @right_instruction,
        @right_config
      )

    student = %{student | slots: %{1 => left, "1" => right}}

    optimizer =
      BootstrapRS.new(
        metric: fn _, _ -> 1.0 end,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 2,
        verbose: false
      )

    assert {:ok, %{program: learned, candidates: [%{seed: -1, score: 100.0}]}} =
             BootstrapRS.compile_with_candidates(optimizer, student, [row("training"), label()],
               restrict: [-1],
               valset: [row("validation")]
             )

    program = %{
      learned
      | slots: %{
          1 => %{learned.slots[1] | lm: lms["left"]},
          "1" => %{learned.slots["1"] | lm: lms["right"]}
        }
    }

    observation = observe(program, lms)
    assert :ok = Dspy.Module.save_state(program, "checkpoint.json", lms: lms)
    observation
  end

  defp checkpoint("read") do
    lms = bindings(:reader)
    assert {:ok, program} = Dspy.Module.load_state(build_program(), "checkpoint.json", lms: lms)
    observe(program, lms)
  end

  defp build_program do
    signature = %{Signature.define("question -> answer") | instructions: "Initial instructions"}

    opts = [
      adapter: JSONAdapter,
      config: [rollout_id: 99],
      max_retries: 1,
      max_output_retries: 1
    ]

    %Program{
      slots: %{1 => Predict.new(signature, opts), "1" => ChainOfThought.new(signature, opts)}
    }
  end

  defp configure(predictor, lm, instructions, config) do
    %{
      predictor
      | lm: lm,
        config: config,
        signature: %{predictor.signature | instructions: instructions}
    }
  end

  defp bindings(instance) do
    %{
      "left" => %OfflineLM{model: "offline:predict", observer: self(), instance: instance},
      "right" => %OfflineLM{model: "offline:cot", observer: self(), instance: instance}
    }
  end

  defp row(question), do: Example.new(question: question) |> Example.with_inputs(:question)

  defp label do
    Example.new(
      %{
        "question" => "labeled question",
        question: "atom-key label",
        answer: "labeled answer"
      },
      %{"split" => "train", "source" => %{"revisions" => [1, true, nil]}}
    )
    |> Example.with_inputs(:question)
  end

  defp observe(program, lms) do
    assert %{1 => %Predict{} = left, "1" => %ChainOfThought{} = right} = program.slots
    assert left.lm === lms["left"]
    assert right.lm === lms["right"]

    assert left.signature.instructions == @left_instruction
    assert right.signature.instructions == @right_instruction
    assert Predict.get_config(left) === @left_config
    assert ChainOfThought.get_config(right) === @right_config

    labeled_demo = label()

    assert left.examples === [
             %Example{attrs: %{question: "training/left", answer: "left answer"}, metadata: %{}},
             labeled_demo
           ]

    assert right.examples === [
             %Example{
               attrs: %{
                 "question" => "training/right",
                 answer: "right answer",
                 reasoning: "offline proof"
               },
               metadata: %{}
             },
             labeled_demo
           ]

    assert {:ok, %Prediction{attrs: %{answer: "left answer | right answer"}} = prediction} =
             Dspy.Module.forward(program, %{question: "round trip"})

    assert_received {:request, left_model, left_request}
    assert_received {:request, right_model, right_request}
    assert {left_model, right_model} == {"offline:predict", "offline:cot"}
    refute_received {:request, _, _}

    assert left_request.temperature === 0.0
    assert left_request.max_completion_tokens == 18
    assert %{temperature: 0.6, max_tokens: 72} = right_request

    {left_request, right_request, prediction}
  end
end

[mode] = System.argv()
ProgramStateRoundtrip.run(mode)
