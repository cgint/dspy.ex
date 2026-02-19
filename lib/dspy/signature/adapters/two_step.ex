defmodule Dspy.Signature.Adapters.TwoStep do
  @moduledoc """
  Two-stage signature adapter:

  1) run the main LM call with a freeform/natural prompt
  2) run a second extraction LM call to produce signature-shaped outputs
  """

  @behaviour Dspy.Signature.Adapter

  alias Dspy.Signature
  alias Dspy.Signature.AdapterPipeline

  @impl true
  def format_instructions(_signature, _opts \\ []) do
    "Respond naturally to solve the task. Do not use JSON or field labels unless explicitly requested."
  end

  @impl true
  def format_request(%Signature{} = signature, inputs, demos, _opts \\ [])
      when is_map(inputs) and is_list(demos) do
    with {:ok, %{inputs: filtered_inputs, messages: history_messages}} <-
           Dspy.History.extract_messages(signature, inputs) do
      filtered_signature = %{
        signature
        | input_fields: Enum.reject(signature.input_fields, &(&1.type == :history))
      }

      system = build_main_system_prompt(filtered_signature)

      user =
        [
          render_examples(filtered_signature, demos),
          render_inputs(filtered_signature, filtered_inputs)
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      %{
        messages:
          [%{role: "system", content: system}] ++
            history_messages ++ [%{role: "user", content: user}]
      }
    end
  end

  @impl true
  def parse_outputs(%Signature{} = signature, text, _opts \\ []) when is_binary(text) do
    with {:ok, extraction_lm} <- extraction_lm(),
         {:ok, extraction_adapter} <- extraction_adapter(),
         {:ok, request_defaults} <- extraction_request_defaults(),
         extractor_signature <- extractor_signature(signature),
         {:ok, extraction_request0} <-
           AdapterPipeline.format_request(
             extractor_signature,
             %{text: text},
             [],
             adapter: extraction_adapter
           ),
         {:ok, extraction_request} <-
           merge_request_defaults(extraction_request0, request_defaults),
         {:ok, extraction_response} <- Dspy.LM.generate(extraction_lm, extraction_request),
         {:ok, extraction_text} <- Dspy.LM.text_from_response(extraction_response),
         {:ok, outputs} <-
           parse_extracted_outputs(extraction_adapter, extractor_signature, extraction_text) do
      outputs
    else
      {:error, {:two_step, _} = tagged} -> {:error, tagged}
      {:error, reason} -> {:error, {:two_step, {:extraction_failed, reason}}}
    end
  end

  defp extraction_lm do
    lm =
      if Process.whereis(Dspy.Settings), do: Dspy.Settings.get(:two_step_extraction_lm), else: nil

    if is_nil(lm) do
      {:error, {:two_step, :extraction_lm_not_configured}}
    else
      {:ok, lm}
    end
  end

  defp extraction_adapter do
    adapter =
      if Process.whereis(Dspy.Settings) do
        Dspy.Settings.get(:two_step_extraction_adapter) || Dspy.Signature.Adapters.JSONAdapter
      else
        Dspy.Signature.Adapters.JSONAdapter
      end

    cond do
      is_atom(adapter) and Code.ensure_loaded?(adapter) and
        function_exported?(adapter, :parse_outputs, 3) and
          function_exported?(adapter, :format_request, 4) ->
        {:ok, adapter}

      true ->
        {:error, {:invalid_extraction_adapter, adapter}}
    end
  end

  defp extraction_request_defaults do
    defaults =
      if Process.whereis(Dspy.Settings) do
        Dspy.Settings.get(:two_step_extraction_request_defaults) || [temperature: 0]
      else
        [temperature: 0]
      end

    if Keyword.keyword?(defaults) do
      {:ok, defaults}
    else
      {:error, {:invalid_extraction_request_defaults, defaults}}
    end
  end

  defp merge_request_defaults(request, defaults) when is_map(request) and is_list(defaults) do
    merged =
      Enum.reduce(defaults, request, fn {key, value}, acc ->
        case Map.get(acc, key) do
          nil -> Map.put(acc, key, value)
          _existing -> acc
        end
      end)

    {:ok, merged}
  end

  defp parse_extracted_outputs(adapter, extractor_signature, extraction_text) do
    case adapter.parse_outputs(extractor_signature, extraction_text, []) do
      outputs when is_map(outputs) ->
        {:ok, outputs}

      {:error, reason} ->
        {:error, {:two_step, {:extraction_parse_failed, reason}}}

      other ->
        {:error, {:two_step, {:extraction_parse_failed, {:invalid_outputs, other}}}}
    end
  rescue
    error ->
      {:error, {:two_step, {:extraction_parse_failed, {:exception, error}}}}
  end

  defp extractor_signature(%Signature{} = signature) do
    %Signature{
      name: signature.name <> "__two_step_extractor",
      input_fields: [
        %{
          name: :text,
          type: :string,
          description: "Freeform completion text from the main LM",
          required: true,
          default: nil
        }
      ],
      output_fields: signature.output_fields,
      instructions:
        "Extract structured outputs from the input text. Return only values supported by the text."
    }
  end

  defp build_main_system_prompt(%Signature{} = signature) do
    input_lines =
      signature.input_fields
      |> Enum.map(fn field ->
        "- #{field.name}: #{field.description}"
      end)
      |> Enum.join("\n")

    output_lines =
      signature.output_fields
      |> Enum.map(fn field ->
        "- #{field.name}: #{field.description}"
      end)
      |> Enum.join("\n")

    instruction_line =
      case signature.instructions do
        s when is_binary(s) and s != "" -> "\n\nSpecific instructions:\n" <> s
        _ -> ""
      end

    """
    You are a helpful assistant that solves the user task.

    Inputs available:
    #{input_lines}

    Desired outputs:
    #{output_lines}

    Respond naturally and clearly.
    Do not format your response as JSON.
    Do not use explicit output field labels.
    """ <> instruction_line
  end

  defp render_examples(_signature, []), do: ""

  defp render_examples(%Signature{} = signature, demos) when is_list(demos) do
    demos
    |> Enum.with_index(1)
    |> Enum.map(fn {example, idx} ->
      inputs = Dspy.Example.inputs(example)

      outputs =
        signature.output_fields
        |> Enum.reduce(%{}, fn field, acc ->
          case Dspy.Example.get(example, field.name) do
            nil -> acc
            value -> Map.put(acc, field.name, value)
          end
        end)

      "Example #{idx}:\n" <>
        "Inputs:\n" <>
        render_pairs(signature.input_fields, inputs) <>
        "\n\nHelpful answer:\n" <> render_pairs(signature.output_fields, outputs)
    end)
    |> Enum.join("\n\n")
  end

  defp render_inputs(%Signature{} = signature, inputs) when is_map(inputs) do
    "Task inputs:\n" <> render_pairs(signature.input_fields, inputs)
  end

  defp render_pairs(fields, data) when is_list(fields) and is_map(data) do
    fields
    |> Enum.map(fn %{name: name} ->
      value = fetch_input(data, name)

      value_text =
        case value do
          :__missing__ -> ""
          %Dspy.Attachments{} -> "<attachments>"
          binary when is_binary(binary) -> binary
          other -> inspect(other, pretty: false, limit: 100, sort_maps: true)
        end

      "#{name}: #{value_text}"
    end)
    |> Enum.join("\n")
  end

  defp fetch_input(map, name) when is_map(map) and is_atom(name) do
    cond do
      Map.has_key?(map, name) -> Map.fetch!(map, name)
      Map.has_key?(map, Atom.to_string(name)) -> Map.fetch!(map, Atom.to_string(name))
      true -> :__missing__
    end
  end
end
