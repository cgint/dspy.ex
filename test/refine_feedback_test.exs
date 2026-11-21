defmodule Dspy.RefineFeedbackTest do
  use ExUnit.Case, async: true

  alias Dspy.{Context, Example, Image, LM, Predict, Prediction, Refine, Settings}
  alias Dspy.Module, as: DSPyModule
  alias Dspy.Module.PredictorTrace
  alias Dspy.Signature.AdapterPipeline
  alias Dspy.Signature.Adapters.ChatAdapter

  defmodule QA do
    use Dspy.Signature

    input_field(:question, :string, "Declared question")
    input_field(:page, :image, "Declared image", required: false)
    output_field(:answer, :string, "Declared answer")
  end

  defmodule MultipartAdapter do
    @behaviour Dspy.Signature.Adapter
    alias Dspy.Signature.Adapters.ChatAdapter

    defdelegate format_instructions(signature, opts), to: ChatAdapter
    defdelegate parse_outputs(signature, text, opts), to: ChatAdapter

    def format_request(signature, inputs, demos, opts) do
      request = ChatAdapter.format_request(signature, inputs, demos, opts)
      [system, %{content: text} = user] = request.messages

      %{
        request
        | messages: [
            system,
            %{
              user
              | content: [
                  %{"type" => "text", "text" => text},
                  %{"type" => "text", "text" => "TRAILING_TEXT"}
                ]
            }
          ]
      }
    end
  end

  defmodule RecordingLM do
    @behaviour LM
    defstruct [:owner, :label, :generate, :api_key]

    @impl true
    def generate(lm, request) do
      scope = %{temperature: Settings.get(:temperature), rollout_id: Settings.get(:rollout_id)}
      send(lm.owner, {:request, lm.label, request, scope, self()})
      lm.generate.(request, scope)
    end
  end

  defmodule Composite do
    use Dspy.Module
    defstruct [:predictors]

    @impl true
    def forward(program, inputs) do
      left = Map.put(inputs, :question, "first slot")
      right = Map.put(inputs, :question, "second slot")
      context = Context.capture()

      with {:ok, prediction} <- DSPyModule.forward(program.predictors[1], left) do
        task =
          Task.async(fn ->
            Context.with_context(context, fn ->
              DSPyModule.forward(program.predictors["1"], right)
            end)
          end)

        with {:ok, _right} <- Task.await(task), do: {:ok, prediction}
      end
    end
  end

  defmodule NoPredictors do
    use Dspy.Module
    defstruct []

    @impl true
    def forward(_program, _inputs), do: {:ok, Prediction.new(%{answer: "low"})}
  end

  defmodule Repeater do
    use Dspy.Module
    defstruct [:predictor]

    @impl true
    def forward(program, inputs) do
      Enum.reduce(1..40, nil, fn _step, _previous ->
        DSPyModule.forward(program.predictor, inputs)
      end)
    end
  end

  test "bounds a declared trace and applies advice to one exact slot through a multipart retry" do
    predictor_lm =
      lm(:program, fn request, scope ->
        {:ok, text} = AdapterPipeline.primary_prompt_text(request)

        cond do
          scope.rollout_id == 7 -> answer("low")
          text =~ "first slot" and not (text =~ "Your previous output") -> {:ok, "bad output"}
          true -> answer("high")
        end
      end)

    advisor =
      lm(:advisor, fn request, _scope ->
        [left, _right] = report(request)["steps"]
        {:ok, Jason.encode!(%{left["slot"] => "TARGET_ADVICE", "unknown" => "FOREIGN_ADVICE"})}
      end)

    demo =
      Example.new(%{question: "DEMO_SENTINEL", answer: "DEMO_ANSWER"})
      |> Example.with_inputs([:question])

    predictor =
      Predict.new(QA,
        lm: predictor_lm,
        adapter: MultipartAdapter,
        examples: [demo],
        max_output_retries: 1
      )

    program = %Composite{predictors: %{1 => predictor, "1" => predictor}}
    refiner = refiner(program, advisor)

    inputs = %{
      page: Image.new("https://example.invalid/IMAGE_SENTINEL.png"),
      secret: "UNDECLARED_SENTINEL"
    }

    assert {:ok, %Prediction{attrs: %{answer: "high"}}, outer_trace} =
             Dspy.context([temperature: 0.25, rollout_id: 7, cache: false], fn ->
               PredictorTrace.capture(refiner, inputs)
             end)

    assert length(outer_trace) == 4
    refute inspect(outer_trace) =~ "TARGET_ADVICE"
    assert %Composite{predictors: %{1 => ^predictor, "1" => ^predictor}} = refiner.program

    assert_received {:request, :program, first_left, %{temperature: 1.0, rollout_id: 7}, _}
    assert_received {:request, :program, first_right, %{temperature: 1.0, rollout_id: 7}, worker}
    assert worker != self()
    assert_received {:request, :advisor, advisor_request, %{temperature: 0.25, rollout_id: 7}, _}
    assert_received {:request, :program, second_left, %{temperature: 1.0, rollout_id: 8}, _}
    assert_received {:request, :program, retry_left, %{temperature: 1.0, rollout_id: 8}, _}
    assert_received {:request, :program, second_right, %{temperature: 1.0, rollout_id: 8}, _}
    refute_received {:request, :advisor, _, _, _}

    assert %{"score" => 0, "threshold" => 1, "steps" => [left, right]} = report(advisor_request)
    assert left["slot"] != right["slot"]
    assert left["inputs"]["question"] == "first slot"
    assert left["outputs"] == %{"answer" => "low"}
    assert right["inputs"]["question"] == "second slot"
    assert is_binary(left["inputs"]["page"])

    serialized = Jason.encode!(advisor_request)

    for secret <- ["IMAGE_SENTINEL", "UNDECLARED_SENTINEL", "DEMO_SENTINEL", "FAKE_API_KEY"] do
      refute serialized =~ secret
    end

    for request <- [first_left, first_right, second_right] do
      refute primary(request) =~ "TARGET_ADVICE"
    end

    for request <- [second_left, retry_left] do
      assert length(:binary.matches(primary(request), "TARGET_ADVICE")) == 1
      refute primary(request) =~ "FOREIGN_ADVICE"
      assert other_parts(request) == other_parts(first_left)
    end

    assert Enum.any?(other_parts(second_left), &(&1["type"] == "image_url"))
    assert %{"type" => "text", "text" => "TRAILING_TEXT"} in other_parts(second_left)
  end

  test "clears advice after one attempt and tolerates an advisor exit with no failure allowance" do
    predictor =
      Predict.new(QA, adapter: ChatAdapter, lm: lm(:program, fn _, _ -> answer("low") end))

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    advisor =
      lm(:advisor, fn request, _ ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 ->
            [step] = report(request)["steps"]
            {:ok, Jason.encode!(%{step["slot"] => "ONCE_ONLY"})}

          1 ->
            Process.exit(self(), :kill)
        end
      end)

    refiner = refiner(predictor, advisor, n: 3, fail_count: 0)

    assert {:ok, %Prediction{attrs: %{answer: "low"}}} = call(refiner, %{question: "q"})
    assert_received {:request, :program, first, _, _}
    assert_received {:request, :advisor, _, _, _}
    assert_received {:request, :program, second, _, _}
    assert_received {:request, :advisor, _, _, _}
    assert_received {:request, :program, third, _, _}
    refute_received {:request, :advisor, _, _, _}
    refute primary(first) =~ "ONCE_ONLY"
    assert primary(second) =~ "ONCE_ONLY"
    refute primary(third) =~ "ONCE_ONLY"
  end

  test "enforces payload and advice caps and skips a missing trace, final attempt or nil advisor" do
    huge = String.duplicate("å", 100_000)

    predictor =
      Predict.new(QA, adapter: ChatAdapter, lm: lm(:program, fn _, _ -> answer("low") end))

    advisor =
      lm(:advisor, fn request, _ ->
        [step] = report(request)["steps"]
        {:ok, Jason.encode!(%{step["slot"] => String.duplicate("a", 4_000)})}
      end)

    assert {:ok, _} = call(refiner(predictor, advisor), %{question: huge})
    assert_received {:request, :program, _, _, _}
    assert_received {:request, :advisor, payload, _, _}
    assert_received {:request, :program, with_advice, _, _}
    assert byte_size(primary(payload)) <= 16_384
    assert primary(payload) =~ "[truncated]"
    refute primary(with_advice) =~ String.duplicate("a", 1_025)
    assert primary(with_advice) =~ String.duplicate("a", 100)
    refute_received {:request, :advisor, _, _, _}

    for refiner <- [
          refiner(%NoPredictors{}, advisor),
          refiner(predictor, advisor, n: 1),
          refiner(predictor, nil),
          refiner(predictor, advisor, reward_fn: fn _, _ -> 1 end),
          refiner(predictor, advisor, reward_fn: fn _, _ -> :invalid end)
        ] do
      call(refiner, %{question: "q"})
      refute_received {:request, :advisor, _, _, _}
    end
  end

  test "caps advisor trace collection without capping an enclosing trace" do
    program = %Repeater{
      predictor:
        Predict.new(QA,
          adapter: ChatAdapter,
          lm: lm(:program, fn _, _ -> answer("low") end)
        )
    }

    advisor = lm(:advisor, fn _, _ -> {:ok, "{}"} end)

    assert {:ok, %Prediction{}, outer} =
             Dspy.context([cache: false], fn ->
               PredictorTrace.capture(refiner(program, advisor), %{question: "q"})
             end)

    assert length(outer) == 80
    assert_received {:request, :advisor, request, _, _}
    assert %{"truncated" => true, "steps" => steps} = report(request)
    assert length(steps) == 32
    refute_received {:request, :advisor, _, _, _}
  end

  test "a hung advisor is stopped before the refiner resumes" do
    predictor =
      Predict.new(QA, adapter: ChatAdapter, lm: lm(:program, fn _, _ -> answer("low") end))

    advisor =
      lm(:advisor, fn _, _ ->
        receive do
          :never_sent -> {:ok, "{}"}
        end
      end)

    refiner = refiner(predictor, advisor, fail_count: 0)
    assert {:ok, %Prediction{attrs: %{answer: "low"}}} = call(refiner, %{question: "q"})
    assert_received {:request, :advisor, _, _, worker}
    refute Process.alive?(worker)
    assert_received {:request, :program, first, _, _}
    assert_received {:request, :program, ^first, _, _}
  end

  test "invalid replies have no effect on the next prompt" do
    predictor =
      Predict.new(QA, adapter: ChatAdapter, lm: lm(:program, fn _, _ -> answer("low") end))

    for response <- [
          fn _ -> {:error, :advisor_failed} end,
          fn _ -> {:ok, "not JSON"} end,
          fn _ -> {:ok, Jason.encode!(%{"unknown" => "wrong slot"})} end,
          fn request ->
            [step] = report(request)["steps"]
            {:ok, Jason.encode!(%{step["slot"] => " N/A "})}
          end,
          fn request ->
            [step] = report(request)["steps"]
            {:ok, Jason.encode!(%{step["slot"] => String.duplicate("a", 20_000)})}
          end
        ] do
      advisor = lm(:advisor, fn request, _ -> response.(request) end)
      assert {:ok, _} = call(refiner(predictor, advisor, fail_count: 0), %{question: "q"})
      assert_received {:request, :advisor, _, _, _}
      assert_received {:request, :program, first, _, _}
      assert_received {:request, :program, ^first, _, _}
    end
  end

  defp report(request), do: request |> primary() |> Jason.decode!()
  defp primary(request), do: elem(AdapterPipeline.primary_prompt_text(request), 1)
  defp other_parts(request), do: request.messages |> List.last() |> Map.fetch!(:content) |> tl()

  defp lm(label, generate),
    do: %RecordingLM{owner: self(), label: label, generate: generate, api_key: "FAKE_API_KEY"}

  defp answer(value), do: {:ok, "[[ ## answer ## ]]\n" <> value}

  defp refiner(program, advisor, opts \\ []) do
    defaults = [
      feedback_lm: advisor,
      n: 2,
      threshold: 1,
      reward_fn: fn _, prediction -> if prediction.attrs.answer == "high", do: 1, else: 0 end
    ]

    Refine.new(program, Keyword.merge(defaults, opts))
  end

  defp call(refiner, inputs),
    do: Dspy.context([cache: false], fn -> Dspy.call(refiner, inputs) end)
end
