defmodule Dspy.Acceptance.SimplestContractsAcceptanceTest do
  use ExUnit.Case, async: false

  defmodule SeqMockLM do
    @behaviour Dspy.LM
    defstruct [:counter]

    @impl true
    def generate(%__MODULE__{counter: counter}, request) when is_map(request) do
      Agent.update(counter, &(&1 + 1))
      attempt = Agent.get(counter, & &1)

      case attempt do
        1 ->
          # Ensure we got a multimodal message with an input_file part.
          with {:ok, messages} <- fetch_messages(request),
               true <- has_input_file_part?(messages) do
            {:ok,
             %{
               choices: [
                 %{
                   message: %{role: "assistant", content: contract_info_json()},
                   finish_reason: "stop"
                 }
               ],
               usage: nil
             }}
          else
            {:error, reason} -> {:error, reason}
            false -> {:error, :expected_input_file_part}
          end

        _ ->
          {:ok,
           %{
             choices: [
               %{
                 message: %{
                   role: "assistant",
                   content: "Answer: The contract date is 2020-01-01."
                 },
                 finish_reason: "stop"
               }
             ],
             usage: nil
           }}
      end
    end

    defp fetch_messages(%{messages: messages}) when is_list(messages), do: {:ok, messages}
    defp fetch_messages(%{"messages" => messages}) when is_list(messages), do: {:ok, messages}
    defp fetch_messages(_), do: {:error, :missing_messages}

    defp has_input_file_part?(messages) do
      Enum.any?(messages, fn
        %{role: "user", content: parts} when is_list(parts) ->
          input_file_part?(parts)

        %{"role" => "user", "content" => parts} when is_list(parts) ->
          input_file_part?(parts)

        _ ->
          false
      end)
    end

    defp input_file_part?(parts) do
      Enum.any?(parts, fn
        %{"type" => "input_file", "file_path" => path} when is_binary(path) ->
          String.ends_with?(path, "test/fixtures/dummy.pdf")

        _ ->
          false
      end)
    end

    defp contract_info_json do
      # JSON object output (in fences) to exercise `:json` output fields.
      """
      ```json
      {
        "contract_info": {
          "contract_date": "2020-01-01",
          "parties": "Alice; Bob",
          "contract_type": "NDA",
          "subject": "Confidentiality",
          "duration": "12 months",
          "payment_terms": "n/a",
          "key_clauses": "No disclosure",
          "signatures": "Signed",
          "other_info": "None"
        }
      }
      ```
      """
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule ContractExtractionSignature do
    use Dspy.Signature

    signature_instructions("Return outputs as JSON with keys: contract_info.")

    input_field(:pdf, :string, "Contract PDF")
    output_field(:contract_info, :json, "Structured contract information")
  end

  defmodule QuestionAnswerSignature do
    use Dspy.Signature

    input_field(:contracts_data, :json, "List of contract information")
    input_field(:question, :string, "User's question")
    output_field(:answer, :string, "Answer based on the contract information")
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()

    {:ok, counter} = Agent.start_link(fn -> 0 end)
    Dspy.configure(lm: %SeqMockLM{counter: counter})

    :ok
  end

  test "ports dspy-intro simplest_dspy_with_contracts.py: PDF attachment + structured JSON output + Q&A" do
    pdf = Dspy.Attachments.new("test/fixtures/dummy.pdf")

    extractor = Dspy.Predict.new(ContractExtractionSignature)
    assert {:ok, pred} = Dspy.Module.forward(extractor, %{pdf: pdf})

    assert %{"contract_date" => "2020-01-01"} = pred.attrs.contract_info

    qa = Dspy.Predict.new(QuestionAnswerSignature)

    assert {:ok, qa_pred} =
             Dspy.Module.forward(qa, %{
               contracts_data: [pred.attrs.contract_info],
               question: "What is the contract date?"
             })

    assert qa_pred.attrs.answer =~ "2020-01-01"
  end
end
