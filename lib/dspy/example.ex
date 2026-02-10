defmodule Dspy.Example do
  @moduledoc """
  Training examples for DSPy programs.

  Examples represent input-output pairs used for few-shot learning,
  optimization, and evaluation. They support flexible attribute access
  and can contain arbitrary fields.
  """

  defstruct [:attrs, :metadata]

  @type t :: %__MODULE__{
          attrs: map(),
          metadata: map()
        }

  @behaviour Access

  @doc """
  Create a new Example with the given attributes.

  ## Examples

      iex> ex = Dspy.Example.new(%{question: "What is 2+2?", answer: "4"})
      iex> ex[:question]
      "What is 2+2?"

      iex> ex = Dspy.Example.new(question: "What is 2+2?", answer: "4")
      iex> ex[:answer]
      "4"
  """
  def new(attrs \\ %{}, metadata \\ %{}) do
    attrs = normalize_attrs(attrs)
    %__MODULE__{attrs: attrs, metadata: metadata}
  end

  @doc """
  Mark which attribute keys should be treated as *inputs*.

  This is inspired by Python DSPy’s `Example.with_inputs(...)` and is useful
  for evaluation/teleprompt flows where examples may contain both inputs and
  labels.

  The keys are stored in `example.metadata["inputs"]` as **strings** so the
  behavior survives JSON parameter export/import.
  """
  @spec with_inputs(t(), list(atom() | String.t()) | atom() | String.t()) :: t()
  def with_inputs(%__MODULE__{} = example, keys) do
    input_keys = normalize_input_keys!(keys)
    meta = example.metadata || %{}

    %{example | metadata: Map.put(meta, "inputs", input_keys)}
  end

  @doc """
  Returns the list of configured input keys (as strings), or `nil`.
  """
  @spec input_keys(t()) :: [String.t()] | nil
  def input_keys(%__MODULE__{} = example) do
    meta = example.metadata || %{}

    keys = Map.get(meta, "inputs") || Map.get(meta, :inputs)

    cond do
      is_list(keys) -> Enum.map(keys, &to_string/1)
      is_nil(keys) -> nil
      true -> nil
    end
  end

  @doc """
  Return the inputs map for this example.

  - If the example was configured via `with_inputs/2`, only those keys are
    returned.
  - Otherwise this falls back to `example.attrs`.

  Keys are matched safely:
  - we check the string key first
  - then we try `String.to_existing_atom/1` (no atom leaks)
  """
  @spec inputs(t()) :: map()
  def inputs(%__MODULE__{} = example) do
    attrs = example.attrs || %{}

    case input_keys(example) do
      keys when is_list(keys) and keys != [] ->
        take_input_keys(attrs, keys)

      _ ->
        attrs
    end
  end

  @doc """
  Get an attribute from the example.

  When `key` is an atom, this also checks for the string version of the key
  (useful when examples come from JSON).
  """
  def get(%__MODULE__{} = example, key, default \\ nil) do
    attrs = example.attrs

    case existing_key(attrs, key) do
      nil -> default
      actual_key -> Map.get(attrs, actual_key, default)
    end
  end

  @doc """
  Put an attribute in the example.

  If `key` is an atom and a string-keyed value already exists (e.g. "question"),
  this updates the existing string key instead of introducing a new atom key.
  """
  def put(%__MODULE__{} = example, key, value) do
    attrs = example.attrs
    actual_key = key_for_put(attrs, key)

    %{example | attrs: Map.put(attrs, actual_key, value)}
  end

  @doc """
  Delete an attribute from the example.

  When `key` is an atom, this also deletes the string version of the key if
  present.
  """
  def delete(%__MODULE__{} = example, key) do
    attrs = example.attrs

    case existing_key(attrs, key) do
      nil ->
        example

      actual_key ->
        %{example | attrs: Map.delete(attrs, actual_key)}
    end
  end

  @doc """
  Get all attribute keys.
  """
  def keys(example) do
    Map.keys(example.attrs)
  end

  @doc """
  Convert example to a map.
  """
  def to_map(example) do
    example.attrs
  end

  @doc """
  Merge two examples, with the second taking precedence.
  """
  def merge(example1, example2) do
    new_attrs = Map.merge(example1.attrs, example2.attrs)
    new_metadata = Map.merge(example1.metadata, example2.metadata)
    %__MODULE__{attrs: new_attrs, metadata: new_metadata}
  end

  @impl Access
  def fetch(%__MODULE__{} = example, key) do
    attrs = example.attrs

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
  def get_and_update(%__MODULE__{} = example, key, function) do
    current_value = get(example, key)

    case function.(current_value) do
      :pop ->
        pop(example, key)

      {get_value, new_value} ->
        {get_value, put(example, key, new_value)}
    end
  end

  @impl Access
  def pop(%__MODULE__{} = example, key) do
    current_value = get(example, key)
    {current_value, delete(example, key)}
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

  defp normalize_input_keys!(keys) when is_list(keys) do
    Enum.map(keys, &normalize_input_key!/1)
  end

  defp normalize_input_keys!(key) when is_atom(key) or is_binary(key) do
    [normalize_input_key!(key)]
  end

  defp normalize_input_keys!(other) do
    raise ArgumentError,
          "inputs must be a list of keys (atoms/strings) or a single key, got: #{inspect(other)}"
  end

  defp normalize_input_key!(key) when is_atom(key), do: Atom.to_string(key)

  defp normalize_input_key!(key) when is_binary(key) do
    key = String.trim(key)

    if key == "" do
      raise ArgumentError, "input key cannot be empty"
    end

    key
  end

  defp normalize_input_key!(other) do
    raise ArgumentError, "input key must be an atom or string, got: #{inspect(other)}"
  end

  defp take_input_keys(attrs, keys) when is_map(attrs) and is_list(keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case find_attr_key(attrs, key) do
        nil -> acc
        actual_key -> Map.put(acc, actual_key, Map.fetch!(attrs, actual_key))
      end
    end)
  end

  defp find_attr_key(attrs, key) when is_binary(key) do
    cond do
      Map.has_key?(attrs, key) ->
        key

      true ->
        try do
          atom = String.to_existing_atom(key)
          if Map.has_key?(attrs, atom), do: atom, else: nil
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp normalize_attrs(attrs) when is_list(attrs), do: Enum.into(attrs, %{})
  defp normalize_attrs(attrs) when is_map(attrs), do: attrs
end
