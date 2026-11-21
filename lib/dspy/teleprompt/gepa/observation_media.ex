defmodule Dspy.Teleprompt.GEPA.ObservationMedia do
  @moduledoc false

  alias Dspy.{Attrs, Image, Prediction}

  @max_images 8
  @max_url_bytes 8 * 1_024 * 1_024

  defstruct images: [], count: 0, bytes: 0

  def images(nil), do: []
  def images(%__MODULE__{images: images}), do: Enum.reverse(images)

  def annotate(nil, _signature, _step, item), do: {item, nil}

  def annotate(%__MODULE__{} = media, signature, step, item) do
    {inputs, media} = annotate_fields(signature.input_fields, step.inputs, item.inputs, media)

    case step do
      %{prediction: %Prediction{attrs: attrs}} ->
        {outputs, media} = annotate_fields(signature.output_fields, attrs, item.outputs, media)
        {%{item | inputs: inputs, outputs: outputs}, media}

      _failed_step ->
        {%{item | inputs: inputs}, media}
    end
  end

  defp annotate_fields(fields, values, previews, media) do
    Enum.reduce(fields, {previews, media}, fn
      %{name: name, type: :image}, {previews, media} ->
        key = Atom.to_string(name)

        with true <- Map.has_key?(previews, key),
             {:ok, value} <- Attrs.fetch_map(values, name),
             {:ok, indices, updated} <- add_field_images(media, value) do
          {Map.replace!(previews, key, %{image_indices: indices}), updated}
        else
          _omitted -> {previews, media}
        end

      _non_image_field, acc ->
        acc
    end)
  end

  defp add_field_images(media, %Image{} = image), do: add_field_images(media, [image])

  defp add_field_images(media, [_ | _] = images)
       when length(images) + media.count <= @max_images do
    case Enum.reduce_while(images, media.bytes, &count_url_bytes/2) do
      :omitted ->
        :omitted

      bytes ->
        count = media.count + length(images)
        indices = Enum.to_list((media.count + 1)..count)

        updated = %{
          media
          | images: Enum.reverse(images, media.images),
            count: count,
            bytes: bytes
        }

        {:ok, indices, updated}
    end
  end

  defp add_field_images(_media, _value), do: :omitted

  defp count_url_bytes(%Image{url: url}, total)
       when is_binary(url) and byte_size(url) > 0 and total + byte_size(url) <= @max_url_bytes,
       do: {:cont, total + byte_size(url)}

  defp count_url_bytes(_value, _total), do: {:halt, :omitted}
end
