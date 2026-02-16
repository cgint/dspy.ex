defmodule Dspy.Prediction do
  @moduledoc """
  Language model predictions with completion metadata.

  Predictions represent the outputs from language model calls,
  including the generated content and metadata about the generation process.
  """

  defstruct [:attrs, :completions, :metadata]

  @type completion :: %{
          text: String.t(),
          tokens: pos_integer() | nil,
          logprobs: map() | nil,
          finish_reason: String.t() | nil
        }

  @type t :: %__MODULE__{
          attrs: map(),
          completions: [completion()],
          metadata: map()
        }

  @doc """
  Create a new Prediction with the given attributes.

  ## Examples

      iex> pred = Dspy.Prediction.new(%{answer: "4"})
      iex> pred[:answer]
      "4"

      iex> pred = Dspy.Prediction.new(answer: "4", reasoning: "2+2=4")
      iex> pred[:reasoning]
      "2+2=4"
  """
  def new(attrs \\ %{}, completions \\ [], metadata \\ %{}) do
    attrs = normalize_attrs(attrs)

    %__MODULE__{
      attrs: attrs,
      completions: completions,
      metadata: metadata
    }
  end

  @doc """
  Get an attribute from the prediction.

  When `key` is an atom, this also checks for the string version of the key
  (useful when predictions are created/loaded from JSON).
  """
  def get(%__MODULE__{} = prediction, key, default \\ nil) do
    attrs = prediction.attrs

    case existing_key(attrs, key) do
      nil -> default
      actual_key -> Map.get(attrs, actual_key, default)
    end
  end

  @doc """
  Put an attribute in the prediction.

  If `key` is an atom and a string-keyed value already exists (e.g. "answer"),
  this updates the existing string key instead of introducing a new atom key.
  """
  def put(%__MODULE__{} = prediction, key, value) do
    attrs = prediction.attrs
    actual_key = key_for_put(attrs, key)

    %{prediction | attrs: Map.put(attrs, actual_key, value)}
  end

  @doc """
  Delete an attribute from the prediction.

  When `key` is an atom, this also deletes the string version of the key if
  present.
  """
  def delete(%__MODULE__{} = prediction, key) do
    attrs = prediction.attrs

    case existing_key(attrs, key) do
      nil ->
        prediction

      actual_key ->
        %{prediction | attrs: Map.delete(attrs, actual_key)}
    end
  end

  @doc """
  Get all attribute keys.
  """
  def keys(prediction) do
    Map.keys(prediction.attrs)
  end

  @doc """
  Convert prediction to a map.
  """
  def to_map(prediction) do
    prediction.attrs
  end

  @doc """
  Get aggregated LM usage attached to this prediction.

  This aims to be as close as possible to Python DSPy's `prediction.get_lm_usage()`:
  a map keyed by model, where each value is a provider-dependent usage map.

  Example:

      %{
        "google:gemini-2.5-flash" => %{
          prompt_tokens: 123,
          completion_tokens: 456,
          total_tokens: 579,
          cached_tokens: 0,
          reasoning_tokens: 318
        }
      }

  Returns `nil` when usage tracking is disabled or usage is unavailable.
  """
  @spec get_lm_usage(t()) :: map() | nil
  def get_lm_usage(%__MODULE__{} = prediction) do
    metadata = prediction.metadata || %{}

    cond do
      is_map(metadata) and Map.has_key?(metadata, :lm_usage) ->
        metadata[:lm_usage]

      is_map(metadata) and Map.has_key?(metadata, "lm_usage") ->
        metadata["lm_usage"]

      true ->
        nil
    end
  end

  @doc """
  Add completion metadata to the prediction.
  """
  def add_completion(prediction, completion) do
    new_completions = [completion | prediction.completions]
    %{prediction | completions: new_completions}
  end

  @doc """
  Get the most recent completion.
  """
  def latest_completion(prediction) do
    List.first(prediction.completions)
  end

  @doc """
  Get all completions.
  """
  def completions(prediction) do
    prediction.completions
  end

  @behaviour Access

  @impl Access
  def fetch(%__MODULE__{} = prediction, key) do
    attrs = prediction.attrs

    case Map.fetch(attrs, key) do
      {:ok, value} ->
        {:ok, value}

      :error when is_atom(key) ->
        Map.fetch(attrs, Atom.to_string(key))

      :error ->
        :error
    end
  end

  @impl Access
  def get_and_update(%__MODULE__{} = prediction, key, function) do
    current_value = get(prediction, key)

    case function.(current_value) do
      :pop ->
        pop(prediction, key)

      {get_value, new_value} ->
        {get_value, put(prediction, key, new_value)}
    end
  end

  @impl Access
  def pop(prediction, key) do
    current_value = get(prediction, key)
    new_prediction = delete(prediction, key)
    {current_value, new_prediction}
  end

  defp existing_key(attrs, key) when is_atom(key) do
    cond do
      Map.has_key?(attrs, key) -> key
      Map.has_key?(attrs, Atom.to_string(key)) -> Atom.to_string(key)
      true -> nil
    end
  end

  defp existing_key(attrs, key) when is_binary(key) do
    if Map.has_key?(attrs, key), do: key, else: nil
  end

  defp existing_key(_attrs, _key), do: nil

  defp key_for_put(attrs, key) when is_atom(key) do
    existing_key(attrs, key) || key
  end

  defp key_for_put(_attrs, key), do: key

  defp normalize_attrs(attrs) when is_list(attrs), do: Enum.into(attrs, %{})
  defp normalize_attrs(attrs) when is_map(attrs), do: attrs
  defp normalize_attrs(_attrs), do: %{}
end
