defmodule Dspy.BoundingBox do
  @moduledoc """
  A normalized rectangular region, expressed as four edges in the range 0..1.

  Use this module as a typed JSON signature schema. Valid boxes have positive
  width and height (`left < right` and `top < bottom`). Coordinates start at
  the top-left of the image sent to the model, after any resizing or cropping.

      {:ok, box} = Dspy.BoundingBox.new(%{
        "top" => 0.1, "left" => 0.2, "bottom" => 0.8, "right" => 0.9
      })

  In a signature, declare `output_field(:box, :json, "Region", schema: Dspy.BoundingBox)`.
  """

  use JSV.Schema

  @derive Jason.Encoder
  @enforce_keys [:top, :left, :bottom, :right]
  defstruct [:top, :left, :bottom, :right]

  @type t :: %__MODULE__{top: number(), left: number(), bottom: number(), right: number()}

  @doc "Validate a JSON object and construct a bounding box."
  @spec new(term()) :: {:ok, t()} | {:error, term()}
  def new(value), do: Dspy.TypedOutputs.validate_term(value, __MODULE__)

  @doc false
  def json_schema do
    %{
      type: :object,
      properties: %{
        top: %{type: :number, description: "Top edge as a fraction of image height."},
        bottom: %{type: :number, description: "Bottom edge as a fraction of image height."},
        left: %{type: :number, description: "Left edge as a fraction of image width."},
        right: %{type: :number, description: "Right edge as a fraction of image width."}
      },
      required: [:top, :left, :bottom, :right],
      additionalProperties: false
    }
    |> JSV.Schema.xcast(to_box())
  end

  @doc false
  defcast to_box(%{"top" => top, "left" => left, "bottom" => bottom, "right" => right}) do
    if Enum.all?([top, left, bottom, right], &(&1 >= 0 and &1 <= 1)) and
         top < bottom and left < right do
      {:ok, %__MODULE__{top: top, left: left, bottom: bottom, right: right}}
    else
      {:error, "edges must be in [0, 1], with top < bottom and left < right"}
    end
  end
end
