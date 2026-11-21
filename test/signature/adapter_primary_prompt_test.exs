defmodule Dspy.Signature.AdapterPrimaryPromptTest do
  use ExUnit.Case, async: true

  alias Dspy.{Predict, Prediction}
  alias Dspy.Signature.AdapterPipeline
  alias Dspy.Signature.Adapters.Default

  defmodule QA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule MultipartAdapter do
    @behaviour Dspy.Signature.Adapter

    @impl true
    defdelegate format_instructions(signature, opts), to: Default

    @impl true
    def format_request(_signature, %{request: request}, _demos, _opts), do: request

    @impl true
    defdelegate parse_outputs(signature, text, opts), to: Default
  end

  defmodule RetryLM do
    @behaviour Dspy.LM
    defstruct [:observer, :counter]

    @impl true
    def generate(lm, request) do
      send(lm.observer, {:lm_request, request})
      count = Process.get(lm.counter, 0)
      Process.put(lm.counter, count + 1)
      {:ok, Enum.fetch!(["unlabeled draft", "Answer: done"], count)}
    end
  end

  defmodule Recorder do
    def on_adapter_call_start(meta, _payload, owner), do: record(:call_start, meta, owner)
    def on_adapter_call_end(meta, _payload, owner), do: record(:call_end, meta, owner)

    defp record(phase, meta, owner) do
      send(owner, {:adapter_event, phase, meta})
      :ok
    end
  end

  test "an output retry changes only the primary text part in the LM request" do
    system = %{role: "system", content: "format instructions"}
    image = %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,QUJD"}}
    first = %{"type" => "text", "text" => "first marker", "segment" => "primary"}
    trailing = %{"type" => "text", "text" => "trailing marker"}
    user = %{role: "user", content: [first, image, trailing]}
    request = %{messages: [system, user], max_tokens: 17, metadata: %{source: "fixture"}}

    program =
      Predict.new(QA,
        lm: %RetryLM{observer: self(), counter: make_ref()},
        adapter: MultipartAdapter,
        callbacks: [{Recorder, self()}],
        max_retries: 0,
        max_output_retries: 1
      )

    assert {:ok, %Prediction{attrs: %{answer: "done"}}} =
             Dspy.context([cache: false, callbacks: []], fn ->
               Dspy.call(program, %{question: "q", request: request})
             end)

    assert {:adapter_event, :call_start, %{attempt: 1, call_id: id} = meta} = next_event()
    assert {:lm_request, original} = next_event()
    assert {:adapter_event, :call_end, ^meta} = next_event()
    assert {:adapter_event, :call_start, %{attempt: 2, call_id: ^id} = retry_meta} = next_event()
    assert {:lm_request, retry} = next_event()
    assert {:adapter_event, :call_end, ^retry_meta} = next_event()
    refute_received {:lm_request, _}
    refute_received {:adapter_event, _, _}

    assert original.messages == request.messages
    assert original.metadata == request.metadata
    assert original.max_tokens == 17
    assert %{messages: [_, %{content: [%{"text" => replacement} | _]}]} = retry
    assert String.starts_with?(replacement, "first marker\n\nYour previous output")
    assert replacement =~ "missing required output keys: :answer"

    expected_user = %{user | content: [Map.put(first, "text", replacement), image, trailing]}
    assert retry == %{original | messages: [system, expected_user]}
  end

  test "read and replacement choose the same valid part of the last user message" do
    earlier_user = %{"role" => "user", "content" => "earlier question"}
    later_assistant = %{role: "assistant", content: "latest message"}
    missing = %{"type" => "text"}
    non_binary = %{"type" => "text", "text" => 123}
    atom_keys = %{type: "text", text: "not the primary part"}
    first = %{"type" => "text", "text" => "primary", "tag" => "keep"}
    trailing = %{"type" => "text", "text" => "trailing"}
    content = [missing, non_binary, atom_keys, first, trailing]
    user = %{"role" => "user", "content" => content, "name" => "fixture"}
    request = %{"messages" => [earlier_user, user, later_assistant], "metadata" => "keep"}

    assert {:ok, "primary"} = AdapterPipeline.primary_prompt_text(request)
    assert {:ok, updated} = AdapterPipeline.replace_primary_prompt_text(request, "new text")
    assert {:ok, "new text"} = AdapterPipeline.primary_prompt_text(updated)

    updated_parts = [missing, non_binary, atom_keys, Map.put(first, "text", "new text"), trailing]

    assert updated == %{
             :messages => [earlier_user, %{user | "content" => updated_parts}, later_assistant],
             "metadata" => "keep"
           }
  end

  test "missing messages, missing user, and unsupported content keep their error shapes" do
    for {request, reason} <- [
          {%{}, :missing_messages},
          {%{messages: [%{role: "assistant", content: "no user"}]}, :no_user_message},
          {%{messages: [%{role: "user", content: 42}]}, {:unsupported_user_message_content, 42}}
        ] do
      assert {:error, ^reason} = AdapterPipeline.primary_prompt_text(request)
      assert {:error, ^reason} = AdapterPipeline.replace_primary_prompt_text(request, "new text")
    end

    content = [%{"type" => "text", "text" => :not_binary}]
    request = %{messages: [%{role: "user", content: content}]}
    assert {:error, :no_text_part_in_user_message} = AdapterPipeline.primary_prompt_text(request)

    assert {:error, {:unsupported_user_message_content, ^content}} =
             AdapterPipeline.replace_primary_prompt_text(request, "new text")
  end

  defp next_event do
    receive do
      {:lm_request, _} = request -> request
      {:adapter_event, _, _} = event -> event
    after
      0 -> flunk("expected another adapter event or LM request")
    end
  end
end
