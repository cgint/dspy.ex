defmodule DspyOpenSpecChangeIdSignatureExpectedBehaviorTest do
  use ExUnit.Case

  @moduledoc """
  Failing (expected-behavior) test that reflects a real downstream integration issue.

  Scenario:
  - A signature requires an output field `change_id`.
  - The LLM returns a plausible answer containing a kebab-case id, but NOT formatted
    with the exact `Change_id:` label.

  Desired behavior (not currently implemented):
  - DSPy should still be able to extract the intended output (e.g. by recognizing JSON
    or by using more robust heuristics).

  This test is intentionally written to FAIL with the current implementation,
  to reproduce the integration pain point.
  """

  defmodule ChangeIdSignature do
    use Dspy.Signature

    input_field(:request, :string, "User request")
    output_field(:change_id, :string, "OpenSpec change id in kebab-case")
  end

  @tag :expected_behavior
  test "parser should accept JSON output for change_id (currently fails as models are used to return JSON instead of the expected label format)" do
    signature = ChangeIdSignature.signature()

    # This is a very common model behavior: it returns JSON even when the signature
    # format asked for labels.
    response_text = ~s( { "change_id": "openspec-new-change-flow"})

    # Desired: parse_outputs should accept JSON and return the field.
    outputs = Dspy.Signature.parse_outputs(signature, response_text)

    assert is_map(outputs)
    assert outputs.change_id == "openspec-new-change-flow"
  end
end
