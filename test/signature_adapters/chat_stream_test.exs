defmodule Dspy.Signature.Adapters.ChatStreamTest do
  use ExUnit.Case, async: true

  alias Dspy.Signature
  alias Dspy.Signature.Adapters.{ChatAdapter, ChatStream}

  @fields [:answer, :reasoning, :other]
  @cases [
    {
      "preamble[[\t\v\f\r \n##\t answer \r\n##\t ]]\u00a0first🙂 \u202f  " <>
        "[[ ## unknown ## ]]skip[[ ## answer ## ]]second" <>
        "[[ ## reasoning ## ]]\u00a0résumé\u202f",
      %{answer: "first🙂", reasoning: "résumé"},
      [:answer, :reasoning]
    },
    {
      "discard [[[ ## answer ## ]]a[[[ ## reasoning ## ]]b[[[[ ## other ## ]]c",
      %{answer: "a[", reasoning: "b[[", other: "c"},
      [:answer, :reasoning, :other]
    },
    {
      "[[ ## answer ## ]]  one [[ # partial [[ ## answer-name ## ]] " <>
        "[[ ## reasoning ## ]] tail [[",
      %{answer: "one [[ # partial [[ ## answer-name ## ]]", reasoning: "tail [["},
      [:answer, :reasoning]
    },
    {
      "[[ ## answer ## ]] before[[\u00a0## reasoning ## ]]after [[ ## answer ## ]]dupe",
      %{answer: "before[[\u00a0## reasoning ## ]]after"},
      [:answer]
    },
    {
      "[[ ## reasoning ## ]]\u202f \n [[ ## answer ## ]]\n\u00a0",
      %{answer: "", reasoning: ""},
      [:reasoning, :answer]
    },
    {
      "[[ ## Answer ## ]]ignored[[ ## answer ## ]]x \u00a0\u0301ẞ [[ ## other ## ]] y ",
      %{answer: "x \u00a0\u0301ẞ", other: "y"},
      [:answer, :other]
    },
    {
      "[[ ## answer ## ]] prefix \u202f" <> <<226, 128>>,
      %{answer: "prefix \u202f" <> <<226, 128>>},
      [:answer]
    }
  ]

  test "every two-way byte split agrees with ordinary ChatAdapter" do
    for {text, expected, closing_order} <- @cases do
      assert ChatAdapter.parse_outputs(signature(@fields), text) == expected

      for offset <- 0..byte_size(text) do
        <<left::binary-size(offset), right::binary>> = text
        assert_fields([left, right], expected, closing_order)
      end
    end
  end

  test "one-byte deltas preserve overlaps, Unicode trimming, and field order" do
    for {text, expected, closing_order} <- @cases do
      bytes = for <<byte <- text>>, do: <<byte>>
      assert_fields(bytes, expected, closing_order)
    end
  end

  test "stable content arrives before the closing marker or EOF" do
    state = ChatStream.new([:answer, :reasoning])

    assert {[], state} = ChatStream.push(state, "preamble [[ ## ans")

    assert {[{:answer, "first", false}], state} =
             ChatStream.push(state, "wer ## ]]\u00a0first \n")

    assert {[], state} = ChatStream.push(state, "\u202f[[ #")

    assert {[{:answer, " \n\u202f[[ # incomplete", false}], state} =
             ChatStream.push(state, " incomplete")

    assert {[{:answer, "", true}], state} =
             ChatStream.push(state, " \n[[ ## other ## ]]discarded")

    assert [] = ChatStream.finish(state)
  end

  test "a selected final field closes once even without a visible text chunk" do
    state = ChatStream.new([:answer, :reasoning])

    assert {[{:answer, "early", false}], state} =
             ChatStream.push(state, "[[ ## answer ## ]]early")

    assert {[{:answer, "", true}], state} =
             ChatStream.push(state, "[[ ## answer ## ]]duplicate[[ ## reasoning ## ]]\u00a0")

    assert [{:reasoning, "", true}] = ChatStream.finish(state)
  end

  test "JSON fallback and prose without a marker produce no field events" do
    json = ~s({"answer":"No markers"})
    assert ChatAdapter.parse_outputs(signature([:answer]), json) == %{answer: "No markers"}

    for text <- [json, "preamble with incomplete [[ ## answer", ""] do
      state = ChatStream.new([:answer])
      assert {[], state} = ChatStream.push(state, text)
      assert ChatStream.finish(state) == []
    end
  end

  test "unknown markers close fields without interning the marker name" do
    unknown = "scanner_unseen_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    state = ChatStream.new([:answer])

    assert {[{:answer, "a", true}], state} =
             ChatStream.push(state, "[[ ## answer ## ]]a[[ ## #{unknown} ## ]]ignored")

    assert ChatStream.finish(state) == []
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  defp assert_fields(parts, expected, closing_order) do
    {batches, state} =
      Enum.map_reduce(parts, ChatStream.new(@fields), fn text, state ->
        ChatStream.push(state, text)
      end)

    events = Enum.concat([List.flatten(batches), ChatStream.finish(state)])
    assert for({field, _, true} <- events, do: field) == closing_order

    actual =
      events
      |> Enum.group_by(&elem(&1, 0))
      |> Map.new(fn {field, chunks} ->
        assert {^field, _, true} = List.last(chunks)

        for {_, text, false} <- chunks do
          assert text != ""
        end

        {field, Enum.map_join(chunks, &elem(&1, 1))}
      end)

    assert actual == expected
  end

  defp signature(fields) do
    Signature.new("Test Chat streaming",
      output_fields: Enum.map(fields, &%{name: &1, type: :string, required: false, default: nil})
    )
  end
end
