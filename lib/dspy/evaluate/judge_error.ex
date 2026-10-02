defmodule Dspy.Evaluate.JudgeError do
  @moduledoc """
  Raised when a judge LM's answer cannot be parsed or lacks a required field.

  Carries the adapter's underlying reason and the raw judge answer so the
  failure is diagnosable, not a mystery.
  """
  defexception [:reason, :raw_answer]

  @impl true
  def message(%{reason: reason, raw_answer: raw}) do
    "Judge failed: #{inspect(reason)} (raw answer: #{inspect(raw)})"
  end
end
