defmodule Dspy.SettingsContextTest do
  # `async: false` — tests mutate global `Dspy.Settings` via `Dspy.configure/1`.
  use ExUnit.Case, async: false

  defmodule MockLM do
    @behaviour Dspy.LM
    defstruct [:name]

    @impl true
    def generate(%__MODULE__{name: name}, _request) do
      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Answer: #{name}"},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule TestQA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule CapturingLM do
    @moduledoc false

    # Test-only LM that records the request map it receives (after
    # apply_settings_defaults-level processing, i.e. as seen by the
    # behaviour callback) by sending it to a designated process.
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%{pid: pid}, request) do
      send(pid, {:captured, request})

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "ok"},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  describe "override visibility" do
    test "override is visible inside context and restored after" do
      Dspy.configure(lm: %MockLM{name: :lm1}, temperature: 0.5)

      result =
        Dspy.Settings.context([temperature: 1.0], fn ->
          {Dspy.Settings.get(:temperature), Dspy.Settings.get(:lm)}
        end)

      assert {1.0, %MockLM{name: :lm1}} = result
      assert Dspy.Settings.get(:temperature) == 0.5
      assert %MockLM{name: :lm1} = Dspy.Settings.get(:lm)
    end

    test "nested context: inner wins, restored after each level" do
      Dspy.configure(lm: %MockLM{name: :global}, temperature: 0.5)

      Dspy.Settings.context([temperature: 0.2], fn ->
        assert Dspy.Settings.get(:temperature) == 0.2

        Dspy.Settings.context([temperature: 0.1], fn ->
          assert Dspy.Settings.get(:temperature) == 0.1
        end)

        assert Dspy.Settings.get(:temperature) == 0.2
      end)

      assert Dspy.Settings.get(:temperature) == 0.5
    end

    test "restored after fun raises" do
      Dspy.configure(lm: %MockLM{name: :global}, temperature: 0.5)

      assert_raise RuntimeError, "boom", fn ->
        Dspy.Settings.context([temperature: 0.1], fn ->
          raise "boom"
        end)
      end

      assert Dspy.Settings.get(:temperature) == 0.5
    end

    test "restored after fun throws" do
      Dspy.configure(lm: %MockLM{name: :global}, temperature: 0.5)

      assert :raised =
               catch_throw(
                 Dspy.Settings.context([temperature: 0.1], fn ->
                   throw(:raised)
                 end)
               )

      assert Dspy.Settings.get(:temperature) == 0.5
    end

    test "get/0 returns the same struct type with overrides merged" do
      Dspy.configure(lm: %MockLM{name: :global}, temperature: 0.5)

      inside =
        Dspy.Settings.context([temperature: 0.9], fn ->
          Dspy.Settings.get()
        end)

      assert %Dspy.Settings{} = inside
      assert inside.temperature == 0.9
      assert inside.lm == %MockLM{name: :global}

      outside = Dspy.Settings.get()
      assert %Dspy.Settings{} = outside
      assert outside.temperature == 0.5
    end

    test "without overrides, get/0 and get/1 behave as before" do
      Dspy.configure(lm: %MockLM{name: :global}, temperature: 0.5)

      assert %Dspy.Settings{lm: %MockLM{name: :global}, temperature: 0.5} =
               Dspy.Settings.get()

      assert %MockLM{name: :global} = Dspy.Settings.get(:lm)
      assert 0.5 = Dspy.Settings.get(:temperature)
    end
  end

  describe "validation" do
    test "unknown key is dropped like configure/1 (struct/2 rule)" do
      Dspy.configure(lm: %MockLM{name: :global})

      # configure/1 applies struct/2, which silently drops unknown keys;
      # context/2 mirrors that rule.
      :ok = Dspy.Settings.context([nope: 1, temperature: 0.1], fn -> :ok end)
      assert Dspy.Settings.current_overrides() == %{}

      Dspy.Settings.context([nope: 1, temperature: 0.1], fn ->
        assert Dspy.Settings.current_overrides() == %{temperature: 0.1}
        assert 0.1 = Dspy.Settings.get(:temperature)
      end)

      # Global state untouched.
      assert Dspy.Settings.current_overrides() == %{}
      assert Dspy.Settings.get(:lm) == %MockLM{name: :global}
    end
  end

  describe "process isolation" do
    test "overrides are not visible from another process" do
      Dspy.configure(lm: %MockLM{name: :global}, temperature: 0.5)

      Dspy.Settings.context([temperature: 0.1], fn ->
        assert 0.1 = Dspy.Settings.get(:temperature)

        pid = self()
        ref = make_ref()

        spawn(fn ->
          send(pid, {ref, Dspy.Settings.get(:temperature)})
        end)

        assert_receive {^ref, 0.5}, 1_000
      end)
    end
  end

  describe "propagation helpers" do
    test "current_overrides/0 returns the installed map inside, empty outside" do
      Dspy.configure(lm: %MockLM{name: :global}, temperature: 0.5)

      Dspy.Settings.context([temperature: 0.1], fn ->
        Dspy.Settings.context([lm: %MockLM{name: :inner}], fn ->
          # Inner frame composes with the outer one: both overrides visible.
          assert Dspy.Settings.current_overrides() ==
                   %{temperature: 0.1, lm: %MockLM{name: :inner}}

          assert 0.1 = Dspy.Settings.get(:temperature)
        end)

        assert Dspy.Settings.current_overrides() == %{temperature: 0.1}
      end)

      assert Dspy.Settings.current_overrides() == %{}
    end

    test "plain Task.async does NOT inherit overrides (documented behavior)" do
      Dspy.configure(lm: %MockLM{name: :global}, temperature: 0.5)

      Dspy.Settings.context([temperature: 0.1], fn ->
        task = Task.async(fn -> Dspy.Settings.get(:temperature) end)
        assert 0.5 == Task.await(task, 1_000)
      end)
    end

    test "with_overrides propagates overrides into a Task" do
      Dspy.configure(lm: %MockLM{name: :global}, temperature: 0.5)

      Dspy.Settings.context([temperature: 0.1], fn ->
        overrides = Dspy.Settings.current_overrides()

        task =
          Task.async(fn ->
            Dspy.Settings.with_overrides(overrides, fn ->
              Dspy.Settings.get(:temperature)
            end)
          end)

        assert 0.1 == Task.await(task, 1_000)
      end)
    end
  end

  describe "end-to-end" do
    test "Predict forward inside Dspy.context(lm: ...) uses the context LM" do
      Dspy.configure(lm: %MockLM{name: :lm1}, temperature: 0.5)
      predict = Dspy.Predict.new(TestQA)

      Dspy.context([lm: %MockLM{name: :lm2}], fn ->
        # The override is visible to settings reads in this process...
        assert %MockLM{name: :lm2} = Dspy.Settings.get(:lm)

        # ...and a Predict forward resolves its LM through it.
        {:ok, pred} = Dspy.call(predict, %{question: "What is 2+2?"})
        assert pred[:answer] == "lm2"
      end)

      # After the context, the global LM is back in charge.
      assert %MockLM{name: :lm1} = Dspy.Settings.get(:lm)
      {:ok, pred} = Dspy.call(predict, %{question: "What is 2+2?"})
      assert pred[:answer] == "lm1"
    end

    test "Dspy.context(temperature: 1.0) reaches the LM request map" do
      pid = self()
      Dspy.configure(lm: %CapturingLM{pid: pid}, temperature: 0.5)

      Dspy.context([temperature: 1.0], fn ->
        assert {:ok, _} =
                 Dspy.LM.generate(%{messages: [%{role: "user", content: "hi"}]})

        # apply_settings_defaults fills :temperature from Settings (1.0 here).
        assert_receive {:captured, %{temperature: 1.0}}, 1_000
      end)

      # Outside the context the global default (0.5) applies again.
      assert {:ok, _} =
               Dspy.LM.generate(%{messages: [%{role: "user", content: "hi"}]})

      assert_receive {:captured, %{temperature: 0.5}}, 1_000
      assert Dspy.Settings.get(:temperature) == 0.5
    end
  end

  describe "Dspy.context/2 facade" do
    test "delegates to Dspy.Settings.context/2" do
      Dspy.configure(lm: %MockLM{name: :global}, temperature: 0.5)

      assert 0.9 ==
               Dspy.context([temperature: 0.9], fn -> Dspy.Settings.get(:temperature) end)

      assert 0.5 == Dspy.Settings.get(:temperature)
    end
  end
end
