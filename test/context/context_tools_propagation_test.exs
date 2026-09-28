defmodule DspyContextToolsPropagationTest do
  @moduledoc """
  Per-site marker-LM propagation tests for Dspy.Tools (h0-process-context, spec R2).

  T3.2: two marker tests — tool fn reads `Dspy.Settings.get(:lm)` inside
  `Dspy.context([lm: marker_lm], ...)` and asserts marker.

  - `execute_tool` (tools.ex:756): direct test.
  - `call_tool` (tools.ex:503): tested via the same pattern (Task.async + rescue-only).
    Since `call_tool` is private, we test it via the public `Dspy.Tools.execute_tool/3`
    which shares the identical wrap shape. The brief notes both sites are
    rescue-only with linked tasks; the wrap must not add a catch.
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

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %GlobalLM{})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Scripted React LM (for call_tool test)
  # ---------------------------------------------------------------------------

  defmodule ScriptedReactLM do
    @moduledoc false
    @behaviour Dspy.LM
    defstruct []

    def new(), do: %__MODULE__{}

    @impl true
    def generate(%__MODULE__{}, _request) do
      # Use a process-dict counter to track which call this is.
      # The React loop calls the LM sequentially in the caller process.
      count = Process.get({__MODULE__, :call_count}) || 0
      Process.put({__MODULE__, :call_count}, count + 1)

      content =
        case count do
          # First call: trigger tool
          0 -> "Action: echo_lm"
          # Second call: finish
          _ -> "Answer: done"
        end

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  describe "tools marker-LM propagation" do
    test "execute_tool (tools.ex:756): tool fn sees marker LM via Dspy.Settings.get(:lm)" do
      marker = MarkerLM.new(:marker)

      tool =
        Dspy.Tools.new_tool("echo_lm", "Echoes LM", fn _args ->
          Dspy.Settings.get(:lm)
        end)

      Dspy.context([lm: marker], fn ->
        {:ok, seen_lm} = Dspy.Tools.execute_tool(tool, %{})
        assert seen_lm == marker
      end)
    end

    test "call_tool (tools.ex:503): tool fn sees marker LM via Dspy.Settings.get(:lm) in React run" do
      marker = MarkerLM.new(:marker)

      # Scripted mock LM: first call returns "Action: echo_lm", second returns "Answer: done".
      # This drives the React loop: parse_react_step → {:action, "echo_lm"} →
      # execute_action → call_tool (tools.ex:503) → tool fn reads Dspy.Settings.get(:lm).
      Process.delete({ScriptedReactLM, :call_count})

      scripted_lm = ScriptedReactLM.new()

      tool =
        Dspy.Tools.new_tool("echo_lm", "Echoes LM", fn _args ->
          # Return a string encoding whether the marker LM was seen.
          # The React loop stringifies the observation, so we return a string.
          case Dspy.Settings.get(:lm) do
            %DspyContextToolsPropagationTest.MarkerLM{} -> "MARKER_SEEN"
            _ -> "NOT_MARKER"
          end
        end)

      react = Dspy.Tools.React.new(scripted_lm, [tool], max_steps: 2)

      Dspy.context([lm: marker], fn ->
        {:ok, result} = Dspy.Tools.React.run(react, "test question")

        # The tool fn returned "MARKER_SEEN" as the observation (stringified by React loop).
        observations =
          result.history
          |> Enum.filter(fn {type, _val, _step} -> type == :observation end)
          |> Enum.map(fn {_type, val, _step} -> val end)

        assert ["MARKER_SEEN"] = observations
      end)
    end
  end
end
