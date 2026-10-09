defmodule Dspy.ImageFieldTypeTest do
  @moduledoc """
  Characterization tests for `:image` as a declared, validatable field type
  in `Dspy.Signature` (OpenSpec change `align-image-input-with-python`).

  All tests go through public entry points only:
    * `Dspy.Signature.define/1` (arrow-string type normalizer)
    * `Dspy.Signature.new/2` + `input_field` DSL (atom type)
    * `Dspy.Signature.validate_inputs/2`
  """
  use ExUnit.Case, async: true

  alias Dspy.Image

  @image %Image{url: "https://example.com/a.png"}

  defp image_signature(fields) do
    Dspy.Signature.new("ImageSig",
      input_fields: fields,
      output_fields: [
        %{name: :answer, type: :string, description: "", required: true, default: nil}
      ]
    )
  end

  describe "arrow-string signatures (type normalizer)" do
    test "accepts \"image\" as a field type and stores :image" do
      signature = Dspy.Signature.define("img: image -> answer: string")

      assert [img | _] = signature.input_fields
      assert img.name == :img
      assert img.type == :image
    end

    test "unknown types still raise (no accidental permissiveness)" do
      assert_raise ArgumentError, fn ->
        Dspy.Signature.define("img: not_a_real_type -> answer: string")
      end
    end
  end

  describe "DSL signatures with the :image atom" do
    defmodule ImageDslSig do
      use Dspy.Signature
      input_field(:img, :image, "The image")
      output_field(:answer, :string, "The answer")
    end

    test "input_field(:img, :image, ...) stores type :image" do
      assert ImageDslSig.signature().input_fields == [
               %{name: :img, type: :image, description: "The image", required: true, default: nil}
             ]
    end
  end

  describe "validate_inputs/2 on a :image field" do
    test "accepts a single %Dspy.Image{}" do
      sig =
        image_signature([
          %{name: :img, type: :image, description: "", required: true, default: nil}
        ])

      assert :ok = Dspy.Signature.validate_inputs(sig, %{img: @image})
    end

    test "accepts a non-empty list of %Dspy.Image{}" do
      sig =
        image_signature([
          %{name: :img, type: :image, description: "", required: true, default: nil}
        ])

      other = %Image{url: "data:image/png;base64,QUJD"}
      assert :ok = Dspy.Signature.validate_inputs(sig, %{img: [@image, other]})
    end

    test "rejects a plain binary with :invalid_image" do
      sig =
        image_signature([
          %{name: :img, type: :image, description: "", required: true, default: nil}
        ])

      assert {:error, {:invalid_input_value, :img, :invalid_image}} =
               Dspy.Signature.validate_inputs(sig, %{img: "not an image"})
    end

    test "rejects a number with :invalid_image" do
      sig =
        image_signature([
          %{name: :img, type: :image, description: "", required: true, default: nil}
        ])

      assert {:error, {:invalid_input_value, :img, :invalid_image}} =
               Dspy.Signature.validate_inputs(sig, %{img: 42})
    end

    test "rejects an atom with :invalid_image" do
      sig =
        image_signature([
          %{name: :img, type: :image, description: "", required: true, default: nil}
        ])

      assert {:error, {:invalid_input_value, :img, :invalid_image}} =
               Dspy.Signature.validate_inputs(sig, %{img: :foo})
    end

    test "rejects a list containing a non-image element with :invalid_image" do
      sig =
        image_signature([
          %{name: :img, type: :image, description: "", required: true, default: nil}
        ])

      assert {:error, {:invalid_input_value, :img, :invalid_image}} =
               Dspy.Signature.validate_inputs(sig, %{img: [@image, "nope"]})
    end

    test "rejects an empty list with :invalid_image" do
      sig =
        image_signature([
          %{name: :img, type: :image, description: "", required: true, default: nil}
        ])

      assert {:error, {:invalid_input_value, :img, :invalid_image}} =
               Dspy.Signature.validate_inputs(sig, %{img: []})
    end
  end

  describe ":string escape-hatch (must remain unchanged)" do
    test "%Dspy.Image{} on a :string field is still accepted" do
      sig =
        image_signature([
          %{name: :img, type: :string, description: "", required: true, default: nil}
        ])

      assert :ok = Dspy.Signature.validate_inputs(sig, %{img: @image})
    end

    test "list of %Dspy.Image{} on a :string field is still accepted" do
      sig =
        image_signature([
          %{name: :img, type: :string, description: "", required: true, default: nil}
        ])

      assert :ok = Dspy.Signature.validate_inputs(sig, %{img: [@image]})
    end
  end
end
