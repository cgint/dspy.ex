defmodule Dspy.TestSupport.DummyLM do
  @moduledoc """
  A scripted LM for testing judge metrics without network.

  Answers a list of scripted outputs in order, in the default adapter's wire format.

  Each scripted output is an **ordered keyword list**, written in the
  signature's output-field order. Maps are rejected: map iteration order is not
  guaranteed (OTP 26+), so a map-based script would emit fields in an arbitrary
  order and any test relying on that order would pass only by chance (M1-d B2).
  Records each request. Raises on any call past the script.

  Usage:
      lm = Dspy.TestSupport.DummyLM.new([
        [reasoning: "...", recall: 1.0, precision: 1.0]
      ])
      Dspy.context([lm: lm], fn ->
        # code under test
      end)

  The state (script position + recorded requests) is stored in
  `:persistent_term` keyed by a unique instance key, so it works correctly
  even if the LM struct is copied (e.g. across process boundaries).

  Each keyword list in the script becomes the response content, formatted as
  `Field: value` lines in the list's order (the default adapter's wire format).

  On any call past the script, this module raises a `RuntimeError` naming
  the call number.
  """

  @behaviour Dspy.LM
  defstruct [:key]

  @type t :: %__MODULE__{key: {module(), integer()}}

  @doc """
  Create a new DummyLM with a scripted list of ordered keyword lists.

  Each entry's keys become the response fields, emitted in list order as
  `Field: value` lines (the default adapter's wire format). A map entry
  raises `ArgumentError`.

  ## Examples

      lm = Dspy.TestSupport.DummyLM.new([
        [reasoning: "Thinking...", recall: 0.6, precision: 0.8],
        [reasoning: "More thinking...", recall: 0.7, precision: 0.9]
      ])
  """
  @spec new([keyword()]) :: t()
  def new(script) when is_list(script) do
    Enum.each(script, fn entry ->
      unless is_list(entry) and Keyword.keyword?(entry) do
        raise ArgumentError,
              "DummyLM script entries must be ordered keyword lists (signature output order), " <>
                "got: #{inspect(entry)}"
      end
    end)

    key = {__MODULE__, System.unique_integer([:positive])}
    :persistent_term.put(key, {script, 0, []})
    %__MODULE__{key: key}
  end

  @doc """
  Get the recorded requests (the full input maps received by the LM).

  Returns a list of request maps, one per call, in call order.
  """
  @spec requests(t()) :: [map()]
  def requests(%__MODULE__{key: key}) do
    {_script, _pos, requests} = :persistent_term.get(key)
    requests
  end

  @doc """
  Get the number of calls made so far.
  """
  @spec call_count(t()) :: non_neg_integer()
  def call_count(%__MODULE__{key: key}) do
    {_script, pos, _requests} = :persistent_term.get(key)
    pos
  end

  @impl true
  def generate(%__MODULE__{key: key}, request) do
    {script, pos, requests} = :persistent_term.get(key)

    if pos >= length(script) do
      raise RuntimeError,
            "DummyLM script exhausted: call #{pos + 1} exceeds the #{length(script)}-entry script"
    end

    answer = Enum.at(script, pos)
    content = format_answer(answer)

    :persistent_term.put(key, {script, pos + 1, [request | requests]})

    {:ok,
     %{
       choices: [
         %{message: %{role: "assistant", content: content}, finish_reason: "stop"}
       ],
       usage: nil
     }}
  end

  @impl true
  def supports?(_lm, _feature), do: true

  # Format a keyword list as `Field: value` lines, in list order (the default adapter's wire format).
  # Field names must match the pattern in `Dspy.Signature.extract_field_value/2`:
  #   `String.capitalize(Atom.to_string(field.name))`
  # e.g. `:ground_truth_key_ideas` → `Ground_truth_key_ideas`
  defp format_answer(entry) when is_list(entry) do
    entry
    |> Enum.map(fn {field, value} ->
      field_name = field |> Atom.to_string() |> String.capitalize()
      "#{field_name}: #{value_to_string(value)}"
    end)
    |> Enum.join("\n")
  end

  defp value_to_string(value) when is_binary(value), do: value
  defp value_to_string(value) when is_float(value), do: to_string(value)
  defp value_to_string(value) when is_integer(value), do: to_string(value)
  defp value_to_string(value), do: inspect(value)
end
