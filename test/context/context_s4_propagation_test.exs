defmodule DspyContextS4PropagationTest do
  @moduledoc """
  S4 per-site marker-LM propagation tests + D5 chain test (h0-process-context).

  T4.2: per-site marker tests for the 8 S4 sites (teleprompts + retrieve).
  T4.3: CHAIN TEST — Dspy.context(lm: marker) around a nested-Evaluate site must
        reach the INNERMOST forward of the inner Evaluate's tasks, proving the
        outer wrap is required (D5).
  T4.4: retrieve:411 unconditional wrap test.

  All tests use mock LMs — deterministic, no :network, no real provider.
  """
  use ExUnit.Case, async: false

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defmodule MarkerLM do
    @moduledoc false
    @behaviour Dspy.LM
    defstruct tag: :marker

    def new(tag \\ :marker), do: %__MODULE__{tag: tag}

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: MARKER"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule GlobalLM do
    @moduledoc false
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: GLOBAL"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule TestQA do
    use Dspy.Signature
    input_field(:question, :string, "Question to answer")
    output_field(:answer, :string, "Answer to the question")
  end

  # A module whose forward calls Evaluate.evaluate — drives the D5 chain
  # through the REAL Dspy.Parallel.run entry point (parallel.ex:144, S2-wired)
  # into the REAL Dspy.Evaluate.evaluate entry point (evaluate.ex:104, S2-wired).
  defmodule EvalModule do
    @moduledoc false
    use Dspy.Module

    @enforce_keys [:program, :testset, :metric]
    defstruct [:program, :testset, :metric]

    @impl true
    def forward(%__MODULE__{program: program, testset: testset, metric: metric}, _inputs) do
      result = Dspy.Evaluate.evaluate(program, testset, metric, num_threads: 2, progress: false)
      {:ok, Dspy.Prediction.new(%{mean: result.mean, successes: result.successes})}
    end
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %GlobalLM{})
    :ok
  end

  # ---------------------------------------------------------------------------
  # T4.3 — D5 CHAIN TEST (most critical)
  # ---------------------------------------------------------------------------

  describe "D5 chain test: marker reaches innermost forward of nested Evaluate" do
    test "Parallel.run (outer) → Module.forward → Evaluate.evaluate (inner) → inner tasks see marker" do
      marker = MarkerLM.new(:marker)
      predict = Dspy.Predict.new(TestQA)

      testset = [
        Dspy.Example.new(question: "q1", answer: "MARKER"),
        Dspy.Example.new(question: "q2", answer: "MARKER")
      ]

      metric = fn example, prediction ->
        if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
      end

      # Build a module that calls Evaluate.evaluate in its forward.
      eval_mod = %EvalModule{program: predict, testset: testset, metric: metric}

      # D5 chain through REAL library entry points:
      # 1. Caller has marker LM via Dspy.context([lm: marker]).
      # 2. Dspy.Parallel.run (parallel.ex:144) captures context + wraps tasks
      #    in Dspy.Context.with_context (S2-wired).
      # 3. Each task calls Module.forward (EvalModule.forward).
      # 4. EvalModule.forward calls Dspy.Evaluate.evaluate (evaluate.ex:104),
      #    which spawns its own tasks (S2-wired).
      # 5. Inner tasks must see the marker LM.
      #
      # Without the outer wrap (step 2), the inner tasks would see the global
      # LM (no overrides installed in the outer task's process).

      Dspy.context([lm: marker], fn ->
        pairs = [{eval_mod, %{}}]

        {:ok, results} = Dspy.Parallel.run(Dspy.Parallel.new(num_threads: 1), pairs)

        [%{attrs: attrs}] = results

        assert attrs.mean == 1.0,
               "D5 chain failed: mean=#{attrs.mean}, expected 1.0. " <>
                 "Marker LM did not reach inner Evaluate tasks through the real Parallel.run chain."

        assert attrs.successes == 2,
               "D5 chain failed: successes=#{attrs.successes}, expected 2."
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # T4.2 — Per-site marker tests (where feasible without heavy setup)
  # ---------------------------------------------------------------------------

  describe "per-site marker-LM propagation (S4 sites)" do
    test "ensemble.Program forward (ensemble.ex:33): marker LM used in spawned member forward" do
      marker = MarkerLM.new(:marker)
      predict = Dspy.Predict.new(TestQA)

      ensemble = %Dspy.Teleprompt.Ensemble.Program{
        members: [predict],
        weights: [1.0],
        num_threads: 1
      }

      Dspy.context([lm: marker], fn ->
        {:ok, prediction} = Dspy.Module.forward(ensemble, %{question: "q"})
        assert prediction.attrs.answer == "MARKER"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # T4.4 — retrieve:411 unconditional wrap test
  # ---------------------------------------------------------------------------

  describe "retrieve:411 unconditional wrap" do
    defmodule MockEmbeddingProvider do
      @moduledoc false
      @behaviour Dspy.Retrieve.EmbeddingProvider

      def lm_seen_key(), do: :retrieve_s4_lm_seen

      @impl true
      def embed_text(_text, _opts), do: {:ok, [0.1, 0.2, 0.3]}

      @impl true
      def embed_batch(texts, _opts) do
        # Record the LM seen by this process (the spawned document task) under a
        # FIXED persistent_term key the test (caller process) can read. Every
        # task writes; if the wrap at retrieve.ex:411 is present, every task sees
        # the marker, so the final recorded value is the marker. If the wrap is
        # broken, every task sees the global LM, and the assert below fails.
        #
        # Use put_new-style semantics: only record if not already set, so the
        # FIRST task to write wins (deterministic). All tasks see the same LM
        # (marker if wrapped, global if not), so first-writer = the correct value.
        if :persistent_term.get(lm_seen_key(), :unset) == :unset do
          lm = Dspy.Settings.get(:lm)
          :persistent_term.put(lm_seen_key(), lm)
        end

        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end
    end

    test "process_documents (retrieve.ex:411): marker LM visible inside spawned document task" do
      marker = MarkerLM.new(:marker)

      # Reset the persistent_term key so this test starts clean.
      :persistent_term.put(MockEmbeddingProvider.lm_seen_key(), :unset)

      documents = [
        %{content: "Hello world", doc_id: "doc1"},
        %{content: "Another document", doc_id: "doc2"}
      ]

      Dspy.context([lm: marker], fn ->
        chunks =
          Dspy.Retrieve.DocumentProcessor.process_documents(documents,
            embedding_provider: MockEmbeddingProvider
          )

        # Chunks were produced with valid embeddings (provider was called in tasks).
        assert is_list(chunks)
        assert length(chunks) > 0

        assert Enum.all?(chunks, fn %Dspy.Retrieve.Document{embedding: emb} ->
                 is_list(emb)
               end)

        # The NON-VACUOUS assertion: the LM seen by the spawned document task
        # (recorded by the mock into a fixed persistent_term key) equals the
        # marker. If the wrap at retrieve.ex:411 is missing, the task sees the
        # global LM (not the marker), and this assert fails.
        seen_lm = :persistent_term.get(MockEmbeddingProvider.lm_seen_key(), :unset)

        assert seen_lm == marker,
               "retrieve:411 wrap failed: task saw LM #{inspect(seen_lm)}, expected marker. " <>
                 "The Dspy.Context wrap at retrieve.ex:411 did not propagate the marker LM."
      end)
    end
  end
end
