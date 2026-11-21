defmodule Dspy.ModuleProgramStateTest do
  use ExUnit.Case, async: true

  alias Dspy.{ChainOfThought, Example, Module, Predict}

  @moduletag :tmp_dir
  @signature "question -> answer"

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:marker, :items, :mapping, :pair]

    @impl true
    def forward(_program, _inputs), do: {:error, :forward_was_not_expected}
  end

  defmodule OfflineLM do
    @behaviour Dspy.LM
    defstruct [:api_key, :transport, :marker]

    @impl true
    def generate(_lm, _request), do: {:error, :inference_was_not_expected}
  end

  test "round trips root predictor state using a filename without an extension", %{tmp_dir: dir} do
    path = Path.join(dir, "checkpoint")
    demo = Example.new(%{question: "demo", answer: "learned"}) |> Example.with_inputs(:question)

    for {module, kind} <- [{Predict, "predict"}, {ChainOfThought, "chain_of_thought"}] do
      source = module.new(@signature, examples: [demo]) |> with_instructions("learned")
      fresh = module.new(@signature, max_retries: 1)

      assert :ok = Module.save_state(source, path)

      assert %{
               "format" => "dspy_ex.program_state",
               "version" => 1,
               "slots" => [%{"path" => [], "kind" => ^kind}]
             } = read_checkpoint(path)

      assert {:ok, %{__struct__: ^module} = restored} = Module.load_state(fresh, path)
      assert restored.signature.instructions == "learned"
      assert restored.examples === [demo]
      assert restored.max_retries == 1
      assert fresh.examples == []
    end
  end

  test "restores exact atom, integer and string slots alongside list and tuple slots", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "checkpoint")
    fresh = Predict.new(@signature)

    target = %Program{
      marker: :target,
      items: [fresh],
      mapping: %{1 => fresh, "1" => fresh, :"1" => fresh},
      pair: {:opaque, fresh}
    }

    source = %Program{
      marker: :source,
      items: [with_instructions(fresh, "list")],
      mapping: %{
        1 => with_instructions(fresh, "integer"),
        "1" => with_instructions(fresh, "string"),
        :"1" => with_instructions(fresh, "atom")
      },
      pair: {:ignored_source, with_instructions(fresh, "tuple")}
    }

    assert :ok = Module.save_state(source, path)

    assert read_checkpoint(path)["slots"] |> Enum.map(& &1["path"]) |> MapSet.new() ==
             MapSet.new([
               [["field", "items"], ["index", 0]],
               [["field", "mapping"], ["key", "integer", 1]],
               [["field", "mapping"], ["key", "string", "1"]],
               [["field", "mapping"], ["key", "atom", "1"]],
               [["field", "pair"], ["index", 1]]
             ])

    assert {:ok, %Program{marker: :target} = restored} = Module.load_state(target, path)
    assert [list_member] = restored.items
    assert {:opaque, tuple_member} = restored.pair
    assert list_member.signature.instructions == "list"
    assert tuple_member.signature.instructions == "tuple"
    assert restored.mapping[1].signature.instructions == "integer"
    assert restored.mapping["1"].signature.instructions == "string"
    assert restored.mapping[:"1"].signature.instructions == "atom"
  end

  test "rejects missing and extra slots even when display keys use the same spelling", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "checkpoint")
    predictor = Predict.new(@signature)
    integer_path = [["field", "mapping"], ["key", "integer", 1]]
    string_path = [["field", "mapping"], ["key", "string", "1"]]

    assert :ok = Module.save_state(%Program{mapping: %{1 => predictor}}, path)

    assert {:error, {:slot_set_mismatch, %{missing: [^string_path], extra: [^integer_path]}}} =
             Module.load_state(%Program{mapping: %{"1" => predictor}}, path)
  end

  test "rejects different kinds and reordered or moved signature fields", %{tmp_dir: dir} do
    path = Path.join(dir, "checkpoint")
    signature = "question, context -> answer, summary"
    assert :ok = Module.save_state(Predict.new(signature), path)

    assert {:error, {:predictor_kind_mismatch, []}} =
             Module.load_state(ChainOfThought.new(signature), path)

    for other_signature <- [
          "context, question -> answer, summary",
          "question, context -> summary, answer",
          "question, summary -> answer, context"
        ] do
      assert {:error, {:signature_mismatch, []}} =
               Module.load_state(Predict.new(other_signature), path)
    end
  end

  test "rejects duplicate predictor slots and malformed typed paths in a later record", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "checkpoint")
    predictor = Predict.new(@signature)
    program = %Program{mapping: %{1 => predictor, "1" => predictor}}

    assert :ok = Module.save_state(program, path)
    assert %{"slots" => [first, second]} = document = read_checkpoint(path)

    write_checkpoint(path, %{document | "slots" => [first, second, second]})
    second_path = second["path"]

    assert {:error, {:duplicate_slot, ^second_path}} = Module.load_state(program, path)

    malformed = %{second | "path" => [["field", "mapping"], ["index", -1]]}
    write_checkpoint(path, %{document | "slots" => [first, malformed]})

    assert {:error, {:invalid_state, _location}} = Module.load_state(program, path)

    first = %{first | "instructions" => "Must not apply"}
    malformed = %{second | "config" => %{"n" => 0}}
    write_checkpoint(path, %{document | "slots" => [first, malformed]})

    assert {:error, {:invalid_state, ["slots", 1, "config"]}} =
             Module.load_state(program, path)
  end

  test "rejects duplicate JSON members inside a checkpoint slot", %{tmp_dir: dir} do
    path = Path.join(dir, "checkpoint")
    predictor = Predict.new(@signature)
    assert :ok = Module.save_state(predictor, path)
    assert %{"slots" => [slot]} = document = read_checkpoint(path)
    assert {:ok, _restored} = Module.load_state(predictor, path)

    duplicate = Jason.OrderedObject.new([{"inputs", slot["inputs"]} | Map.to_list(slot)])
    write_checkpoint(path, %{document | "slots" => [duplicate]})

    assert {:error, {:invalid_state, _location}} = Module.load_state(predictor, path)
  end

  test "rejects duplicate exact keys in a typed demo map", %{tmp_dir: dir} do
    path = Path.join(dir, "checkpoint")
    predictor = Predict.new(@signature, examples: [Example.new(%{question: "demo"})])
    assert :ok = Module.save_state(predictor, path)

    duplicate =
      update_in(
        read_checkpoint(path),
        ["slots", Access.at(0), "demos", Access.at(0), "attrs", "entries"],
        fn [entry] -> [entry, entry] end
      )

    write_checkpoint(path, duplicate)
    assert {:error, {:duplicate_demo_key, _location}} = Module.load_state(predictor, path)
  end

  test "preserves portable demo values and replaces stored config exactly", %{tmp_dir: dir} do
    path = Path.join(dir, "checkpoint")

    demo =
      Example.new(
        %{"question" => "text", :question => "atom", :answer => [%{"score" => 0.5}, true, nil]},
        %{"details" => %{"rank" => 2}, inputs: ["question"]}
      )

    source = %Program{
      items: [
        Predict.new(@signature, examples: [demo], config: [rollout_id: nil, n: 2]),
        Predict.new(@signature, examples: [Example.new(%{answer: "other"}, nil)])
      ]
    }

    target = %Program{items: List.duplicate(Predict.new(@signature, config: [rollout_id: 9]), 2)}

    assert :ok = Module.save_state(source, path)
    assert {:ok, %Program{items: [first, second]}} = Module.load_state(target, path)
    assert first.examples === [demo]
    assert second.examples === [Example.new(%{answer: "other"}, nil)]
    assert Predict.get_config(first) === %{rollout_id: nil, n: 2}
    assert Predict.get_config(second) === %{}
  end

  test "rejects atom example keys outside the target's vocabulary", %{tmp_dir: dir} do
    path = Path.join(dir, "checkpoint")
    predictor = Predict.new(@signature, examples: [Example.new(%{question: "demo"})])
    assert :ok = Module.save_state(predictor, path)
    document = read_checkpoint(path)

    existing = Atom.to_string(:module_program_state_unrecognized_key)
    never_seen = existing <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    assert_raise ArgumentError, fn -> String.to_existing_atom(never_seen) end

    for name <- [existing, never_seen] do
      invalid =
        put_in(
          document,
          ["slots", Access.at(0), "demos", Access.at(0), "attrs", "entries"],
          [[["atom", name], "value"]]
        )

      write_checkpoint(path, invalid)
      assert {:error, {:invalid_state, _location}} = Module.load_state(predictor, path)
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(never_seen) end
  end

  test "shared labeled demos can use fields declared by different slots", %{tmp_dir: dir} do
    path = Path.join(dir, "checkpoint")

    demo =
      Example.new(question: "Where?", answer: "There", context: "Evidence", summary: "Result")
      |> Example.with_inputs([:question, :context])

    target = %Program{
      items: [Predict.new("question -> answer"), Predict.new("context -> summary")]
    }

    source = %{target | items: Enum.map(target.items, &%{&1 | examples: [demo]})}

    assert :ok = Module.save_state(source, path)
    assert {:ok, %Program{items: [first, second]}} = Module.load_state(target, path)
    assert first.examples === [demo]
    assert second.examples === [demo]
  end

  test "stores only LM names, restores through the caller and clears null bindings", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "checkpoint")
    old_lm = %OfflineLM{api_key: "secret-checkpoint-sentinel", transport: "transport-sentinel"}
    caller_lm = %OfflineLM{marker: :caller}

    source = %Program{items: [Predict.new(@signature, lm: old_lm), Predict.new(@signature)]}

    target_predictor =
      Predict.new(@signature,
        lm: old_lm,
        adapter: Dspy.Signature.Adapters.JSONAdapter,
        max_retries: 6
      )

    target = %Program{items: [target_predictor, target_predictor]}

    assert :ok = Module.save_state(source, path, lms: %{"local" => old_lm})
    json = File.read!(path)
    refute json =~ "secret-checkpoint-sentinel"
    refute json =~ "transport-sentinel"
    assert %{"slots" => [%{"lm" => "local"}, %{"lm" => nil}]} = Jason.decode!(json)

    assert {:ok, %Program{items: [bound, unbound]}} =
             Module.load_state(target, path, lms: %{"local" => caller_lm})

    assert bound === %{target_predictor | lm: caller_lm}
    assert unbound === %{target_predictor | lm: nil}
  end

  test "reports missing, ambiguous and unknown LM names and compares bindings exactly", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "checkpoint")
    lm = %OfflineLM{marker: 1}
    predictor = Predict.new(@signature, lm: lm)

    assert {:error, {:missing_lm_reference, []}} = Module.save_state(predictor, path)

    assert {:error, {:ambiguous_lm_reference, []}} =
             Module.save_state(predictor, path, lms: %{"a" => lm, "b" => lm})

    assert {:error, :invalid_lm_registry} =
             Module.save_state(predictor, path, lms: %{"bad" => nil})

    assert {:error, :invalid_lm_registry} =
             Module.save_state(predictor, path, lms: %{"bad" => %{__struct__: Dspy.LM}})

    assert :ok =
             Module.save_state(predictor, path, lms: %{"a" => lm, "float" => %{lm | marker: 1.0}})

    assert %{"slots" => [%{"lm" => "a"}]} = read_checkpoint(path)
    assert {:error, {:unknown_lm_reference, []}} = Module.load_state(predictor, path)
  end

  test "unsupported values preserve an existing checkpoint and rename failure cleans up", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "checkpoint")
    predictor = Predict.new(@signature)
    assert :ok = Module.save_state(predictor, path)
    original = File.read!(path)

    unsupported = %{predictor | examples: [Example.new(question: self())]}
    assert {:error, {:unsupported_state_value, _location}} = Module.save_state(unsupported, path)
    assert File.read!(path) == original
    assert File.ls!(dir) == ["checkpoint"]

    destination = Path.join(dir, "directory")
    File.mkdir!(destination)
    File.write!(Path.join(destination, "marker"), "sentinel")
    entries = dir |> File.ls!() |> Enum.sort()

    assert {:error, {:file_error, :rename, _reason}} = Module.save_state(predictor, destination)
    assert dir |> File.ls!() |> Enum.sort() == entries
    assert File.read!(Path.join(destination, "marker")) == "sentinel"
  end

  test "rejects unsupported runtime map keys and tolerates old predictor structs", %{tmp_dir: dir} do
    path = Path.join(dir, "checkpoint")
    predictor = Predict.new(@signature)

    assert {:error, {:unsupported_slot_key, _location}} =
             Module.save_state(%Program{mapping: %{1.0 => predictor}}, path)

    old = Map.drop(predictor, [:lm, :config])
    assert :ok = Module.save_state(old, path)
    assert {:ok, ^predictor} = Module.load_state(old, path)
  end

  test "returns structured errors for I/O, malformed JSON, foreign format and version", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "checkpoint")
    predictor = Predict.new(@signature)

    assert {:error, {:file_error, :read, :enoent}} = Module.load_state(predictor, path)
    File.write!(path, "{")
    assert {:error, :invalid_json} = Module.load_state(predictor, path)
    assert :ok = Module.save_state(predictor, path)
    document = read_checkpoint(path)

    write_checkpoint(path, %{document | "format" => "foreign"})
    assert {:error, :unsupported_state_format} = Module.load_state(predictor, path)

    write_checkpoint(path, %{document | "version" => 2})
    assert {:error, {:unsupported_state_version, 2}} = Module.load_state(predictor, path)
  end

  test "uses caller-selected chardata paths and returns errors for invalid paths", %{tmp_dir: dir} do
    path = [String.to_charlist(dir), "/checkpoint"]
    predictor = Predict.new(@signature)

    assert :ok = Module.save_state(predictor, path)
    assert {:ok, ^predictor} = Module.load_state(predictor, path)

    assert {:error, {:file_error, :read, :badarg}} = Module.load_state(predictor, nil)
    assert {:error, {:file_error, :write, :badarg}} = Module.save_state(predictor, nil)

    missing_parent = Path.join([dir, "missing", "checkpoint"])
    assert {:error, {:file_error, :write, :enoent}} = Module.save_state(predictor, missing_parent)
    assert File.ls!(dir) == ["checkpoint"]
  end

  defp with_instructions(predictor, instructions) do
    put_in(predictor.signature.instructions, instructions)
  end

  defp read_checkpoint(path), do: path |> File.read!() |> Jason.decode!()
  defp write_checkpoint(path, document), do: File.write!(path, Jason.encode!(document))
end
