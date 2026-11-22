defmodule Dspy.Teleprompt.GEPAObservationImagesTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Image, Predict, Signature}
  alias Dspy.Signature.Adapters.{ChatAdapter, Default, JSONAdapter, XMLAdapter}
  alias Dspy.Teleprompt.GEPA
  alias GEPA.InstructionProposer

  @starting "Answer zero."
  @improved "Read the training images and answer four."
  @first "https://example.invalid/training-first.png"
  @second "https://example.invalid/training-second.png"
  @detail "https://example.invalid/training-detail.png"
  @generated "https://example.invalid/generated.png"
  @hidden "https://example.invalid/undeclared.png"
  @nested "https://example.invalid/nested.png"
  @held_out "https://example.invalid/held-out.png"
  @demo "https://example.invalid/demo.png"

  defmodule ImageOutputAdapter do
    @behaviour Dspy.Signature.Adapter

    @impl true
    defdelegate format_instructions(signature, opts), to: JSONAdapter

    @impl true
    defdelegate format_request(signature, inputs, demos, opts), to: JSONAdapter

    @impl true
    def parse_outputs(signature, text, opts) do
      output_fields = Enum.reject(signature.output_fields, &(&1.name == :illustration))

      case JSONAdapter.parse_outputs(%{signature | output_fields: output_fields}, text, opts) do
        outputs when is_map(outputs) ->
          Map.put(outputs, :illustration, Image.new("https://example.invalid/generated.png"))

        error ->
          error
      end
    end
  end

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:predictor]

    @impl true
    def forward(program, inputs) do
      inputs =
        inputs
        |> Map.put(:undeclared, Image.new("https://example.invalid/undeclared.png"))
        |> Map.put(:metadata, %{embedded: Image.new("https://example.invalid/nested.png")})

      Predict.forward(program.predictor, inputs)
    end
  end

  defmodule StudentLM do
    @behaviour Dspy.LM
    defstruct [:owner, malformed_training?: false]

    @impl true
    def generate(lm, request) do
      {text, _urls} = Dspy.Teleprompt.GEPAObservationImagesTest.user_payload(request)
      row = if text =~ "held-out row", do: :held_out, else: :training
      answer = if text =~ "answer four.", do: "4", else: "0"
      send(lm.owner, {:rollout, row, answer})

      if lm.malformed_training? and row == :training and answer == "0",
        do: {:ok, "not JSON"},
        else: {:ok, Jason.encode!(%{answer: answer})}
    end
  end

  defmodule ReflectionLM do
    @behaviour Dspy.LM
    defstruct [:owner, :expected_urls, :expected_refs, :adapter]

    @impl true
    def generate(lm, request) do
      {text, urls} = Dspy.Teleprompt.GEPAObservationImagesTest.user_payload(request)

      report =
        text
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case Jason.decode(String.trim_leading(line, "Examples_with_feedback: ")) do
            {:ok, [%{"inputs" => _} | _] = observations} -> observations
            _other -> nil
          end
        end)

      send(lm.owner, {:reflection, text, urls, report})

      instruction =
        if urls == lm.expected_urls and lm.expected_refs.(report),
          do: "Read the training images and answer four.",
          else: "Answer zero."

      case lm.adapter do
        ChatAdapter -> {:ok, "[[ ## new_instruction ## ]]\n" <> instruction}
        Default -> {:ok, "New_instruction: " <> instruction}
        XMLAdapter -> {:ok, "<new_instruction>#{instruction}</new_instruction>"}
        JSONAdapter -> {:ok, Jason.encode!(%{new_instruction: instruction})}
      end
    end
  end

  test "the proposer receives ordered training images and improves held-out scoring" do
    for adapter <- [JSONAdapter, ChatAdapter, Default, XMLAdapter] do
      check = fn
        [
          %{
            "inputs" => %{
              "photo" => %{"image_indices" => [1, 2]},
              "detail" => %{"image_indices" => [3]}
            },
            "outputs" => %{"illustration" => %{"image_indices" => [4]}}
          }
        ] ->
          true

        _other ->
          false
      end

      {:ok, improved} =
        compile(
          InstructionProposer.new(include_observation_images: true, adapter: adapter),
          adapter,
          [@first, @second, @detail, @generated],
          check
        )

      assert improved.predictor.signature.instructions == @improved
      assert_receive {:reflection, text, [@first, @second, @detail, @generated], report}
      assert check.(report)
      assert text =~ "training row"
      assert text =~ "1-based"

      for url <- [@first, @second, @detail, @generated, @hidden, @nested, @held_out, @demo] do
        refute text =~ url
      end

      assert_rollouts([{:held_out, "0"}, {:training, "0"}, {:training, "4"}, {:held_out, "4"}])
    end
  end

  test "the default keeps image placeholders and a text-only proposal" do
    {:ok, program} =
      compile(InstructionProposer.new(), JSONAdapter, [@first], fn _report -> false end)

    assert program.predictor.signature.instructions == @starting

    assert_receive {:reflection, text, [],
                    [
                      %{
                        "inputs" => %{"photo" => "[omitted]", "detail" => "[omitted]"},
                        "outputs" => %{"illustration" => "[omitted]"}
                      }
                    ]}

    refute text =~ "Observation_images"
    assert_rollouts([{:held_out, "0"}, {:training, "0"}])
  end

  test "a list that would exceed the image count cap stays omitted as a unit" do
    photos = Enum.map(1..9, &Image.new("https://example.invalid/many-#{&1}.png"))

    {:ok, _program} =
      compile(
        InstructionProposer.new(include_observation_images: true),
        JSONAdapter,
        [@detail, @generated],
        fn _report -> false end,
        photos: photos
      )

    assert_receive {:reflection, _text, [@detail, @generated],
                    [
                      %{
                        "inputs" => %{
                          "photo" => "[omitted]",
                          "detail" => %{"image_indices" => [1]}
                        },
                        "outputs" => %{"illustration" => %{"image_indices" => [2]}}
                      }
                    ]}

    assert_rollouts([{:held_out, "0"}, {:training, "0"}])
  end

  test "a field over the combined image byte cap stays omitted" do
    large_url = "data:image/png;base64," <> :binary.copy("A", 8 * 1_024 * 1_024)

    {:ok, _program} =
      compile(
        InstructionProposer.new(include_observation_images: true),
        JSONAdapter,
        [@detail, @generated],
        fn _report -> false end,
        photos: [Image.new(large_url)]
      )

    assert_receive {:reflection, _text, [@detail, @generated],
                    [
                      %{
                        "inputs" => %{
                          "photo" => "[omitted]",
                          "detail" => %{"image_indices" => [1]}
                        },
                        "outputs" => %{"illustration" => %{"image_indices" => [2]}}
                      }
                    ]}

    assert_rollouts([{:held_out, "0"}, {:training, "0"}])
  end

  test "image limits apply across previously admitted fields" do
    url_prefix = "data:image/png;base64,"
    exact_url = url_prefix <> :binary.copy("A", 8 * 1_024 * 1_024 - byte_size(url_prefix))
    eight_urls = Enum.map(1..8, &"https://example.invalid/count-#{&1}.png")
    config = InstructionProposer.new(include_observation_images: true)

    for expected_urls <- [eight_urls, [exact_url]] do
      {:ok, _program} =
        compile(config, JSONAdapter, expected_urls, fn _report -> false end,
          photos: Enum.map(expected_urls, &Image.new/1)
        )

      assert_receive {:reflection, _text, urls,
                      [
                        %{
                          "inputs" => %{
                            "photo" => %{"image_indices" => indices},
                            "detail" => "[omitted]"
                          },
                          "outputs" => %{"illustration" => "[omitted]"}
                        }
                      ]}

      assert length(urls) == length(expected_urls)
      assert urls == expected_urls
      assert indices == Enum.to_list(1..length(expected_urls))
      assert_rollouts([{:held_out, "0"}, {:training, "0"}])
    end
  end

  test "a malformed training prediction still contributes declared input images" do
    check = fn
      [
        %{
          "inputs" => %{"photo" => %{"image_indices" => [1, 2]}},
          "outputs" => "not JSON"
        }
      ] ->
        true

      _other ->
        false
    end

    {:ok, program} =
      compile(
        InstructionProposer.new(include_observation_images: true),
        JSONAdapter,
        [@first, @second, @detail],
        check,
        malformed_training?: true
      )

    assert program.predictor.signature.instructions == @improved
    assert_receive {:reflection, _text, [@first, @second, @detail], report}
    assert check.(report)
    assert_rollouts([{:held_out, "0"}, {:training, "0"}, {:training, "4"}, {:held_out, "4"}])
  end

  test "rows dropped by the text report budget contribute no image parts" do
    check = &match?([_, _], &1)

    {:ok, improved} =
      compile(
        InstructionProposer.new(include_observation_images: true),
        JSONAdapter,
        [@first, @detail, @generated, @first, @detail, @generated],
        check,
        photos: [Image.new(@first)],
        training_count: 3,
        feedback: :binary.copy(<<0>>, 1_024)
      )

    assert improved.predictor.signature.instructions == @improved

    assert_receive {:reflection, _text,
                    [@first, @detail, @generated, @first, @detail, @generated], [first, second]}

    assert first["inputs"]["photo"] == %{"image_indices" => [1]}
    assert first["outputs"]["illustration"] == %{"image_indices" => [3]}
    assert second["inputs"]["photo"] == %{"image_indices" => [4]}
    assert second["outputs"]["illustration"] == %{"image_indices" => [6]}

    assert_rollouts([
      {:held_out, "0"},
      {:training, "0"},
      {:training, "0"},
      {:training, "0"},
      {:training, "4"},
      {:training, "4"},
      {:training, "4"},
      {:held_out, "4"}
    ])
  end

  test "selector snapshots preview media even when the proposer opts into image content" do
    owner = self()
    program = program(false)

    optimizer =
      GEPA.new(
        metric: fn _, _, _, _, _ -> 0 end,
        instruction_proposer: InstructionProposer.new(include_observation_images: true),
        component_selector: fn snapshot ->
          send(owner, {:selector, snapshot})
          []
        end,
        max_metric_calls: 3,
        num_threads: 1
      )

    Dspy.context([cache: false], fn ->
      training = [example("training row", [Image.new(@first), Image.new(@second)], @detail)]
      held_out = [example("held-out row", Image.new(@held_out), @held_out)]
      assert {:ok, ^program} = GEPA.compile(optimizer, program, training, valset: held_out)
    end)

    path = [{:field, :predictor}]

    assert_received {:selector,
                     %{
                       eligible_paths: [^path],
                       observations: %{
                         ^path => [
                           %{
                             inputs: %{
                               "photo" => "[omitted]",
                               "detail" => "[omitted]",
                               "metadata" => %{"embedded" => "[omitted]"}
                             },
                             outputs: %{"illustration" => "[omitted]"}
                           }
                         ]
                       }
                     } = snapshot}

    inspected = inspect(snapshot)

    for url <- [@first, @second, @detail, @generated, @hidden, @nested, @held_out, @demo] do
      refute inspected =~ url
    end

    assert_rollouts([{:held_out, "0"}, {:training, "0"}])
  end

  test "image inclusion requires a boolean" do
    assert_raise ArgumentError, ~r/include_observation_images.*boolean/, fn ->
      InstructionProposer.new(include_observation_images: :yes)
    end
  end

  def user_payload(request) do
    %{content: content} = List.last(request.messages)
    parts = List.wrap(content)

    text =
      Enum.map_join(parts, fn
        text when is_binary(text) -> text
        %{"type" => "text", "text" => text} -> text
        _image -> ""
      end)

    urls = for %{"type" => "image_url", "image_url" => %{"url" => url}} <- parts, do: url
    {text, urls}
  end

  defp compile(config, adapter, expected_urls, check, opts \\ []) do
    photos = Keyword.get(opts, :photos, [Image.new(@first), Image.new(@second)])
    malformed? = Keyword.get(opts, :malformed_training?, false)
    count = Keyword.get(opts, :training_count, 1)
    feedback = Keyword.get(opts, :feedback, "")

    optimizer =
      GEPA.new(
        metric: fn _example, prediction, _trace, _name, _steps ->
          %{score: if(prediction[:answer] == "4", do: 1.0, else: 0.0), feedback: feedback}
        end,
        instruction_proposer: config,
        reflection_lm: %ReflectionLM{
          owner: self(),
          expected_urls: expected_urls,
          expected_refs: check,
          adapter: adapter
        },
        add_format_failure_as_feedback: malformed?,
        candidate_selection_strategy: :pareto,
        max_metric_calls: 2 * count + 2,
        num_threads: 1
      )

    Dspy.context([cache: false], fn ->
      training = for index <- 1..count, do: example("training row #{index}", photos, @detail)

      GEPA.compile(optimizer, program(malformed?), training,
        valset: [example("held-out row", Image.new(@held_out), @held_out)]
      )
    end)
  end

  defp program(malformed?) do
    signature =
      Signature.new("image_task",
        instructions: @starting,
        input_fields: [
          field(:question, :string),
          field(:photo, :image),
          field(:detail, :image),
          field(:metadata, :json)
        ],
        output_fields: [field(:answer, :string), field(:illustration, :image)]
      )

    demo = Example.new(question: "demo", photo: Image.new(@demo), answer: "0")

    predictor =
      Predict.new(signature,
        lm: %StudentLM{owner: self(), malformed_training?: malformed?},
        adapter: ImageOutputAdapter,
        examples: [demo],
        max_retries: 0,
        max_output_retries: 0
      )

    %Program{predictor: predictor}
  end

  defp field(name, type),
    do: %{name: name, type: type, description: "", required: true, default: nil}

  defp example(question, photos, detail) do
    Example.new(question: question, photo: photos, detail: Image.new(detail))
    |> Example.with_inputs([:question, :photo, :detail])
  end

  defp assert_rollouts(expected) do
    for {row, answer} <- expected do
      assert_receive {:rollout, ^row, ^answer}
    end

    refute_received {:rollout, _, _}
    refute_received {:reflection, _, _, _}
  end
end
