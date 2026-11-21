defmodule Dspy.Module.PredictorTraceTest do
  use ExUnit.Case, async: true

  alias Dspy.{Prediction, Predict}
  alias Dspy.Module.PredictorTrace

  defmodule QA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule TestLM do
    @behaviour Dspy.LM
    defstruct [:gate]

    @impl true
    def generate(%__MODULE__{gate: {owner, gate}}, _request) do
      send(owner, {:worker_entered, gate, self()})

      receive do
        {:resume, ^gate} -> {:ok, "Answer: observed"}
      after
        2_000 -> {:error, :test_worker_not_released}
      end
    end

    def generate(%__MODULE__{}, _request), do: {:ok, "Answer: observed"}
  end

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:slots, :run]

    @impl true
    def forward(program, inputs), do: program.run.(program.slots, inputs)
  end

  test "nested captures record equal predictors at each sink's own typed path with shared indices" do
    owner = self()
    predictor = predictor()
    first_inputs = %{question: "first nested call"}
    second_inputs = %{question: "second nested call"}
    outer_only = %{question: "outer only"}

    outer = %Program{
      slots: %{1 => predictor, "1" => predictor},
      run: fn slots, _inputs ->
        inner = %Program{
          slots: {slots["1"], slots[1]},
          run: fn {first, second}, _inputs ->
            assert {:ok, %Prediction{}} = Dspy.call(first, first_inputs)
            Dspy.call(second, second_inputs)
          end
        }

        assert {:ok, %Prediction{} = pred, inner_steps} = PredictorTrace.capture(inner, %{})
        send(owner, {:inner_steps, inner_steps})
        assert {:ok, %Prediction{}} = Dspy.call(slots["1"], outer_only)
        {:ok, pred}
      end
    }

    assert {:ok, %Prediction{attrs: %{answer: "observed"}} = pred, steps} =
             PredictorTrace.capture(outer, %{})

    assert [
             {first, [{:field, :slots}, {:key, "1"}], ^first_inputs, first_pred},
             {second, [{:field, :slots}, {:key, 1}], ^second_inputs, ^pred},
             {third, [{:field, :slots}, {:key, "1"}], ^outer_only, _}
           ] = steps

    assert_received {:inner_steps,
                     [
                       {^first, [{:field, :slots}, {:index, 0}], ^first_inputs, ^first_pred},
                       {^second, [{:field, :slots}, {:index, 1}], ^second_inputs, ^pred}
                     ]}

    assert first < second and second < third
    assert trace_tables() == []
  end

  test "a detached worker records to a live outer sink after its inner sink closes" do
    owner = self()
    gate = make_ref()
    inputs = %{question: "late invocation"}
    predictor = predictor(%TestLM{gate: {owner, gate}})

    outer = %Program{
      slots: [predictor],
      run: fn [outer_slot], inputs ->
        outer_tables = trace_tables()
        assert [_] = outer_tables

        inner = %Program{
          slots: %{1 => outer_slot},
          run: fn %{1 => inner_slot}, inputs ->
            {worker, monitor} =
              spawn_monitor(fn ->
                send(owner, {:worker_result, gate, Dspy.call(inner_slot, inputs)})
              end)

            assert_receive {:worker_entered, ^gate, ^worker}, 1_000
            send(owner, {:worker_monitor, gate, worker, monitor})
            {:ok, Prediction.new()}
          end
        }

        assert {:ok, %Prediction{}, []} = PredictorTrace.capture(inner, inputs)
        assert trace_tables() == outer_tables
        assert_received {:worker_monitor, ^gate, worker, monitor}
        send(worker, {:resume, gate})

        assert_receive {:worker_result, ^gate, {:ok, %Prediction{} = pred}}, 1_000
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
        {:ok, pred}
      end
    }

    assert {:ok, %Prediction{attrs: %{answer: "observed"}} = pred, steps} =
             PredictorTrace.capture(outer, inputs)

    assert [{_, [{:field, :slots}, {:index, 0}], ^inputs, ^pred}] = steps
    assert trace_tables() == []
  end

  test "a legacy single-sink predictor records directly and inside a new capture" do
    legacy_table = :ets.new(:legacy_trace, [:ordered_set, :public])
    legacy_path = [{:field, :legacy}]
    tagged = Map.put(predictor(), {PredictorTrace, :sink}, {legacy_table, legacy_path})
    direct_input = %{question: "direct legacy call"}
    nested_input = %{question: "nested legacy call"}

    assert {:ok, %Prediction{} = pred} = Dspy.call(tagged, direct_input)
    assert [{direct_index, ^legacy_path, ^direct_input, ^pred}] = :ets.tab2list(legacy_table)

    assert {:ok, ^pred, [{nested_index, [], ^nested_input, ^pred}]} =
             PredictorTrace.capture(tagged, nested_input)

    assert [
             {^direct_index, ^legacy_path, ^direct_input, ^pred},
             {^nested_index, ^legacy_path, ^nested_input, ^pred}
           ] = :ets.tab2list(legacy_table)

    assert :ets.delete(legacy_table)

    assert {:ok, ^pred, [{_, [], ^nested_input, ^pred}]} =
             PredictorTrace.capture(tagged, nested_input)

    assert {:ok, ^pred} = Dspy.call(tagged, direct_input)
    assert trace_tables() == []
  end

  defp predictor(lm \\ %TestLM{}) do
    Predict.new(QA, lm: lm, adapter: Dspy.Signature.Adapters.Default, max_retries: 0)
  end

  defp trace_tables do
    owner = self()

    Enum.filter(:ets.all(), fn table ->
      :ets.info(table, :owner) == owner and :ets.info(table, :name) == :dspy_bootstrap_trace
    end)
  end
end
