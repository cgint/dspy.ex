defmodule Dspy.RetrieveModuleTest do
  use ExUnit.Case, async: false

  alias Dspy.{Example, Prediction, Retrieve, Settings}
  alias Dspy.Retrieve.Document

  defmodule DocumentBackend do
    def retrieve(query, k: k) do
      {:ok, [%Document{content: "#{query}: #{k}", score: 0.7, metadata: %{rank: 1}}]}
    end
  end

  defmodule Observer do
    def on_module_start(%{module: Retrieve, call_id: id}, payload, owner) do
      send(owner, {:retrieval_start, id, payload})
      {owner, id}
    end

    def on_module_end(%{module: Retrieve, call_id: id}, payload, {owner, id}) do
      send(owner, {:retrieval_end, id, payload})
    end
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "local bindings win and unbound modules follow scoped and global settings" do
    global = fn _, _ -> ["global"] end
    scoped = fn _, _ -> ["scoped"] end
    local = fn _, _ -> ["local"] end

    assert :ok = Dspy.configure(rm: global)
    assert %{__struct__: Settings, rm: ^global} = Dspy.settings()
    unbound = Retrieve.new()
    bound = Retrieve.new(rm: local)

    assert passages(unbound, %{query: "query"}) == ["global"]

    Dspy.context([rm: scoped], fn ->
      assert passages(unbound, %{query: "query"}) == ["scoped"]
      assert passages(bound, %{query: "query"}) == ["local"]

      Dspy.context([rm: nil], fn ->
        assert {:error, :no_rm_configured} = Dspy.call(unbound, %{query: "query"})
        assert passages(bound, %{query: "query"}) == ["local"]
      end)

      Dspy.context([rm: false], fn ->
        assert {:error, :invalid_rm} = Dspy.call(unbound, %{query: "query"})
      end)

      assert passages(unbound, %{query: "query"}) == ["scoped"]
    end)

    assert passages(unbound, %{query: "query"}) == ["global"]
  end

  test "forwards the effective k and backend options across native input forms" do
    rm = fn query, opts ->
      send(self(), {:lookup, query, opts})
      {:ok, [query]}
    end

    default = Retrieve.new(rm: rm)
    configured = Retrieve.new(rm: rm, k: 5)

    assert passages(default, "binary") == ["binary"]
    assert_received {:lookup, "binary", [k: 3]}

    assert passages(configured, %{"query" => "strings", "k" => 0}) == ["strings"]
    assert_received {:lookup, "strings", [k: 0]}

    assert passages(configured, query: "keyword", k: nil, rm_opts: [k: 99, language: "en"]) ==
             ["keyword"]

    assert_received {:lookup, "keyword", opts}
    assert Map.new(opts) == %{k: 5, language: "en"}
    assert Keyword.get_values(opts, :k) == [5]

    example =
      %{query: "example", k: 11}
      |> Example.new()
      |> Example.with_inputs([:query])

    assert passages(configured, example) == ["example"]
    assert_received {:lookup, "example", [k: 5]}

    input = %{"query" => "shadowed", "k" => 99, query: "atom wins", k: 2}
    assert passages(configured, input) == ["atom wins"]
    assert_received {:lookup, "atom wins", [k: 2]}
  end

  test "returns ordered passages from supported rows and existing retriever modules" do
    rm = fn _, _ ->
      [
        "plain",
        %Document{content: "document", id: "opaque-id"},
        %{"long_text" => "json", "score" => 0.2},
        %{"long_text" => "shadowed", long_text: "atom"},
        "plain"
      ]
    end

    assert passages(Retrieve.new(rm: rm), %{query: "query"}) ==
             ["plain", "document", "json", "atom", "plain"]

    assert passages(Retrieve.new(rm: DocumentBackend), %{query: "query", k: 2}) == ["query: 2"]
    assert passages(Retrieve.new(rm: fn _, _ -> {:ok, []} end), %{query: "empty"}) == []
  end

  test "passes backend failures through and rejects malformed results as a whole" do
    failure = {:error, {:http_status, 503}}
    assert Dspy.call(Retrieve.new(rm: fn _, _ -> failure end), %{query: "query"}) == failure

    for malformed <- [
          :malformed,
          {:ok, :malformed},
          ["valid" | :malformed],
          {:ok, ["valid", %{long_text: nil}]},
          ["valid", %Document{content: :malformed}],
          ["valid", %{text: "short only"}],
          ["valid", <<255>>]
        ] do
      assert {:error, :invalid_retrieval_result} =
               Dspy.call(Retrieve.new(rm: fn _, _ -> malformed end), %{query: "query"})
    end
  end

  test "rejects malformed inputs before invoking the retriever" do
    program = Retrieve.new(rm: fn _, _ -> flunk("invalid input reached the retriever") end)

    assert {:error, :invalid_query} = Dspy.call(program, %{})
    assert {:error, :invalid_query} = Dspy.call(program, %{query: 42})
    assert {:error, :invalid_query} = Dspy.call(program, %{query: <<255>>})
    assert {:error, :invalid_k} = Dspy.call(program, %{query: "query", k: -1})
    assert {:error, :invalid_k} = Dspy.call(program, %{query: "query", k: 1.5})
    assert {:error, :invalid_rm_opts} = Dspy.call(program, %{query: "query", rm_opts: %{}})

    assert {:error, :invalid_rm_opts} =
             Dspy.call(program, %{query: "query", rm_opts: [{:language, "en"} | :invalid]})
  end

  test "validates constructor options without exposing configuration values" do
    for opts <- [
          %{rm: "private configuration"},
          [unknown: "private configuration"],
          [k: -1],
          [rm: "private configuration"],
          [rm: URI],
          [callbacks: [:malformed]]
        ] do
      error = assert_raise ArgumentError, fn -> Retrieve.new(opts) end
      refute Exception.message(error) =~ "private configuration"
    end

    assert passages(Retrieve.new(k: 0, rm: fn _, [k: 0] -> [] end), %{query: "query"}) == []
  end

  test "uses existing module lifecycle callbacks for success and error" do
    for {backend_result, status} <- [{["passage"], :ok}, {{:error, :unavailable}, :error}] do
      program = Retrieve.new(rm: fn _, _ -> backend_result end, callbacks: [{Observer, self()}])
      assert {^status, _} = Dspy.call(program, %{query: "private query"})
      assert_received {:retrieval_start, id, empty}
      assert empty == %{}
      assert_received {:retrieval_end, ^id, %{status: ^status, duration_us: duration}}
      assert is_integer(duration) and duration >= 0
      refute_received {:retrieval_start, _, _}
      refute_received {:retrieval_end, _, _}
    end
  end

  defp passages(program, input) do
    assert {:ok, %Prediction{attrs: attrs}} = Dspy.call(program, input)
    assert %{passages: passages} = attrs
    assert attrs == %{passages: passages}
    passages
  end
end
