alias Dspy.{History, Image, Predict, ReAct, Refine, Tools}
alias Dspy.History.Turn
alias Dspy.Signature.AdapterPipeline
alias Dspy.Signature.Adapters.{ChatAdapter, XMLAdapter}

defmodule StructuredAgentExample.Signature do
  use Dspy.Signature

  input_field(:question, :string, "Question about the page")
  input_field(:page, :image, "Source page")
  output_field(:answer, :integer, "Value from the page")
end

defmodule StructuredAgentExample.ReplaySignature do
  use Dspy.Signature

  input_field(:question, :string, "Follow-up question about the page")
  input_field(:page, :image, "Source page", required: false)
  input_field(:history, :history, "Previous conversation")
  output_field(:answer, :integer, "Value from the page")
end

defmodule StructuredAgentExample.LM do
  @behaviour Dspy.LM
  defstruct [:reply]

  @impl true
  def supports?(_lm, :structured_react), do: true
  def supports?(_lm, _feature), do: false

  @impl true
  def generate(lm, request), do: lm.reply.(request)

  def call(id, name, args) do
    message = %{
      role: "assistant",
      tool_calls: [%{id: id, function: %{name: name, arguments: args}}]
    }

    {:ok, %{choices: [%{message: message}]}}
  end
end

alias StructuredAgentExample.LM, as: ScriptedLM

lookup = Tools.new_tool("lookup", "Read a value from the page", fn _ -> 42 end)
image = Image.new("https://example.invalid/page.png")

react_lm =
  struct!(ScriptedLM,
    reply: fn %{messages: messages} ->
      case Enum.find(messages, &(&1.role == "tool")) do
        %{tool_call_id: "lookup_page", content: "42"} ->
          true =
            Enum.any?(messages, fn message ->
              Enum.any?(List.wrap(message.content), &match?(%{"type" => "image_url"}, &1))
            end)

          ScriptedLM.call("submit_answer", "submit", %{"answer" => 42})

        nil ->
          ScriptedLM.call("lookup_page", "lookup", %{})
      end
    end
  )

agent = ReAct.new(StructuredAgentExample.Signature, [lookup], mode: :structured)

history =
  Dspy.context([lm: react_lm, cache: false], fn ->
    {:ok, prediction} = Dspy.call(agent, %{question: "What value is on the page?", page: image})

    %{
      answer: 42,
      history: %History{messages: [%Turn{inputs: %{page: ^image}}, %Turn{}]} = history,
      termination_reason: :submit
    } = prediction.attrs

    IO.puts("Structured ReAct submitted 42 after replaying the page and tool result.")
    history
  end)

for {adapter, invalid, valid} <- [
      {ChatAdapter, "[[ ## answer ## ]]\nunknown", "[[ ## answer ## ]]\n42"},
      {XMLAdapter, "<answer>unknown</answer>", "<answer>42</answer>"}
    ] do
  replay_lm =
    struct!(ScriptedLM,
      reply: fn request ->
        true =
          Enum.any?(request.messages, fn message ->
            Enum.any?(List.wrap(message.content), &match?(%{"type" => "image_url"}, &1))
          end)

        true =
          Enum.any?(request.messages, fn message ->
            match?(%{role: "tool", tool_call_id: "lookup_page", content: "42"}, message)
          end)

        {:ok, prompt} = AdapterPipeline.primary_prompt_text(request)
        {:ok, if(prompt =~ "Your previous output", do: valid, else: invalid)}
      end
    )

  verifier =
    Predict.new(StructuredAgentExample.ReplaySignature,
      adapter: adapter,
      lm: replay_lm,
      max_output_retries: 1
    )

  {:ok, %{attrs: %{answer: 42}}} =
    Dspy.context([cache: false], fn ->
      Dspy.call(verifier, %{question: "Confirm the page value.", history: history})
    end)

  IO.puts("#{inspect(adapter)} kept the page image and tool result through a typed output retry.")
end

draft_lm =
  struct!(ScriptedLM,
    reply: fn request ->
      {:ok, prompt} = Dspy.Signature.AdapterPipeline.primary_prompt_text(request)
      answer = if prompt =~ "Keep the units", do: "42 units", else: "42"
      {:ok, "[[ ## answer ## ]]\n" <> answer}
    end
  )

feedback_lm =
  struct!(ScriptedLM,
    reply: fn request ->
      {:ok, report} = Dspy.Signature.AdapterPipeline.primary_prompt_text(request)
      %{"steps" => [%{"slot" => slot}]} = Jason.decode!(report)
      {:ok, Jason.encode!(%{slot => "Keep the units in the answer."})}
    end
  )

predictor = Predict.new("question -> answer", lm: draft_lm, adapter: ChatAdapter)

refiner =
  Refine.new(predictor,
    n: 2,
    feedback_lm: feedback_lm,
    reward_fn: fn _inputs, prediction ->
      if prediction.attrs.answer == "42 units", do: 1.0, else: 0.0
    end
  )

{:ok, prediction} =
  Dspy.context([cache: false], fn -> Dspy.call(refiner, %{question: "Report the page value."}) end)

%{answer: "42 units"} = prediction.attrs
IO.puts("Refine accepted the second answer after one opted-in advisor call.")
