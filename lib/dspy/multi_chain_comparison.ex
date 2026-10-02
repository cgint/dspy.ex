defmodule Dspy.MultiChainComparison do
  @moduledoc """
  Compare `M` reasoning attempts and produce a holistically corrected answer.

  Port of Python `dspy.MultiChainComparison`
  (`dspy/predict/multi_chain_comparison.py`). The signature is extended with
  inputs `reasoning_attempt_1..M` and a leading `rationale` output; `forward/2`
  turns each completion into a one-line "student attempt" and runs a
  `Dspy.Predict` on the extended signature.

  Temperature (default `0.7`) is applied via `Dspy.context/2` for the call, so
  an explicit per-request temperature elsewhere still wins.

  ## Example

      mcc = Dspy.MultiChainComparison.new(QA, m: 3)
      {:ok, pred} = Dspy.call(mcc, %{question: "...", completions: [c1, c2, c3]})

  Each completion is a map / `%Dspy.Prediction{}` with `:rationale` or
  `:reasoning`, and the signature's last output field (e.g. `:answer`).
  """

  use Dspy.Module

  defstruct [:m, :temperature, :last_key, :predict]

  @type t :: %__MODULE__{}

  @doc """
  Options: `:m` (also `:M`, default 3), `:temperature` (default 0.7); other
  options are passed to `Dspy.Predict.new/2`.
  """
  def new(signature, opts \\ []) do
    m = Keyword.get(opts, :m, Keyword.get(opts, :M, 3))

    unless is_integer(m) and m > 0 do
      raise ArgumentError,
            "MultiChainComparison :m must be a positive integer, got: #{inspect(m)}"
    end

    temperature = Keyword.get(opts, :temperature, 0.7)
    signature = resolve_signature(signature)

    last_key =
      case List.last(signature.output_fields) do
        %{name: name} -> name
        nil -> raise ArgumentError, "MultiChainComparison signature needs an output field"
      end

    attempt_fields =
      for idx <- 1..m do
        field(:"reasoning_attempt_#{idx}", "Student Attempt ##{idx}: ${reasoning attempt}")
      end

    rationale =
      field(
        :rationale,
        "Accurate Reasoning: Thank you everyone. Let's now holistically ${corrected reasoning}"
      )

    extended = %{
      signature
      | input_fields: signature.input_fields ++ attempt_fields,
        output_fields: [rationale | signature.output_fields]
    }

    predict_opts = Keyword.drop(opts, [:m, :M, :temperature])

    %__MODULE__{
      m: m,
      temperature: temperature,
      last_key: last_key,
      predict: Dspy.Predict.new(extended, predict_opts)
    }
  end

  @impl true
  def forward(%__MODULE__{} = mcc, inputs) when is_map(inputs) do
    {completions, rest} = Map.pop(inputs, :completions, [])

    attempts = Enum.map(completions, &format_attempt(&1, mcc.last_key))

    if length(attempts) != mcc.m do
      {:error, {:attempt_count_mismatch, %{expected: mcc.m, got: length(attempts)}}}
    else
      attempt_inputs =
        attempts
        |> Enum.with_index(1)
        |> Map.new(fn {text, idx} -> {:"reasoning_attempt_#{idx}", text} end)

      # Caller-supplied inputs win, as upstream (`{**attempts, **kwargs}`).
      Dspy.context([temperature: mcc.temperature], fn ->
        Dspy.Module.forward(mcc.predict, Map.merge(attempt_inputs, rest))
      end)
    end
  end

  defp format_attempt(completion, last_key) do
    rationale = get(completion, :rationale) || get(completion, :reasoning) || ""
    answer = get(completion, last_key)

    "«I'm trying to #{first_line(rationale)} I'm not sure but my prediction is #{first_line(answer)}»"
  end

  # H15 (S10): both clause shapes use the canonical accessor, so a string-keyed
  # Prediction's rationale/answer are no longer dropped.
  defp get(source, key), do: Dspy.Attrs.get(source, key)

  defp first_line(nil), do: ""

  defp first_line(value) do
    value |> to_string() |> String.trim() |> String.split("\n") |> hd() |> String.trim()
  end

  defp field(name, description) do
    %{name: name, type: :string, description: description, required: true, default: nil}
  end

  defp resolve_signature(sig) when is_atom(sig), do: sig.signature()
  defp resolve_signature(sig) when is_binary(sig), do: Dspy.Signature.define(sig)
  defp resolve_signature(%Dspy.Signature{} = sig), do: sig
end
