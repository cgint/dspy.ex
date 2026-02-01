defmodule DspyOpenSpecChangeIdSignatureRegressionTest do
  use ExUnit.Case

  @moduledoc """
  Regression test for a common real-world failure mode:

  When a signature requires an output field (e.g. `change_id`) but the model returns
  free-form text without the expected `Change_id:` label, the parser should return
  `{:error, {:missing_required_outputs, [:change_id]}}`.

  This mirrors the scenario observed in downstream apps where the LLM responds with
  prose or a question instead of the signature format.

  NOTE: This test is deterministic and does not call any external LLM.
  """

  defmodule ChangeIdSignature do
    use Dspy.Signature

    input_field(:request, :string, "User request")
    output_field(:change_id, :string, "OpenSpec change id in kebab-case")
  end

  test "parse_outputs returns missing_required_outputs when label is absent" do
    signature = ChangeIdSignature.signature()

    # Representative LLM-style prose response that does NOT include "Change_id:".
    response_text =
      "I need more details before I can propose a specific change id. What feature do you mean?"

    assert {:error, {:missing_required_outputs, [:change_id]}} =
             Dspy.Signature.parse_outputs(signature, response_text)
  end

  test "parse_outputs succeeds when Change_id label is present" do
    signature = ChangeIdSignature.signature()

    response_text = "Change_id: openspec-new-change-flow"

    outputs = Dspy.Signature.parse_outputs(signature, response_text)

    assert outputs.change_id == "openspec-new-change-flow"
  end
end
