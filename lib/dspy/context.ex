defmodule Dspy.Context do
  @moduledoc """
  Carry per-process DSPy state across spawned work.

  `Dspy.Context` captures, in the caller, the process-local DSPy state that is
  lost whenever a new process is spawned (`Task.async`, `Task.async_stream`,
  `spawn`, ...):

  - **Settings overrides** — process-scoped overrides from `Dspy.context/2` /
    `Dspy.Settings.context/2` (including `track_usage` and `callbacks` when set
    via overrides), stored under `{Dspy.Settings, :process_overrides}`;
  - **Callback stack** — the RAW process-local per-call callback stack
    (`{Dspy.Signature.Adapter.Callbacks, :stack}` frames, innermost first).
  - **Active call ID** — the current observed lifecycle call, when present.
    A worker uses it to correlate its own hooks to the caller.
  - **History capture scopes** — the active collectors, when present.
    A worker can contribute its LM calls while those captures remain open.

  Usage accumulators (`Dspy.LM.UsageAcc`) are **intentionally NOT captured**:
  the usage frame is opened per `Dspy.Module.forward/2` in whichever process
  runs the forward (`lib/dspy/module.ex`), so installing a caller's frame in
  the target would double-count the caller's pre-existing LM calls. `track_usage`
  itself travels with the overrides, so the target's own forward opens its own
  frame and attaches its own usage to its own prediction. Nothing is merged
  back to the caller. This matches upstream Python DSPy
  (`dspy/utils/parallelizer.py:88-96` copies parent thread-local overrides per
  worker; `:93-95` — "each thread tracks its own usage" — and nothing is merged
  back; `dspy/dsp/utils/settings.py:56-57,63,177` — thread-local context).

  ## Why the raw callback stack (not the flattened list)

  Each lifecycle boundary resolves its registrations in settings, program,
  and per-call order. The per-call list comes from the flattened process-local
  stack, and settings are re-read in the process running the boundary.
  If we captured the flattened list and reinstalled it as a per-call frame, global/program
  callbacks already present in the caller's flattened list would fire **twice**
  in the target. Reinstalling the RAW caller frames reproduces exactly the
  caller's per-call nesting, so every callback (global, program, per-call, and
  overrides-carried `Dspy.context(callbacks: ...)`) fires exactly once.

  ## Usage (no merge-back)

  `with_context/2` returns the fun's value only. No usage is returned to the
  caller and none is merged back. A target's LM usage surfaces on the target's
  own prediction (`metadata[:lm_usage]`); an outer caller-side `track_usage`
  frame does NOT accumulate target LM usage (same as today's behavior at every
  spawn site).

  ## Nested-evaluate redundancy (design.md §4)

  Sites that wrap `Dspy.Evaluate.evaluate/4` inside a task (ensemble.ex:455,
  simba.ex:163, bootstrap_few_shot.ex:416) install context in the OUTER task,
  and `Evaluate.evaluate` installs context again in its OWN inner tasks
  (evaluate.ex:104). The outer wrap is REQUIRED: without it, the inner
  Evaluate's `capture/0` would see no overrides (the outer task's process
  dictionary is empty), and the inner tasks would run with global settings
  only. The double-install is not redundant — each level captures from its
  own process and installs into its own children.

  ## Usage

      # In the caller (before the spawn):
      ctx = Dspy.Context.capture()

      # In the task body (the target process):
      Task.async(fn ->
        Dspy.Context.with_context(ctx, fn ->
          Dspy.Module.forward(program, inputs)
        end)
      end)

  `with_context/2` installs in the **current** process, runs `fun`, and
  restores the previous values in an `after` clause (return, raise, throw, and
  exit all restore). It does **not** spawn anything, so it adds no timeout,
  link, or monitor of its own.
  """

  @type t :: %{
          required(:overrides) => map(),
          required(:callback_stack) => list() | nil,
          optional(:active_call_id) => reference(),
          optional(:history_captures) => [Dspy.LM.HistoryCapture.scope()]
        }

  alias Dspy.Lifecycle
  alias Dspy.LM.HistoryCapture
  alias Dspy.Signature.Adapter.Callbacks

  @stack_key {Callbacks, :stack}

  @doc """
  Capture the caller's process-local DSPy state.

  Reads the current settings overrides, raw callback stack, lifecycle call ID
  and history capture scopes. The lifecycle and history keys are present only
  when those scopes are active.

  The result is meant to be installed later in another process via
  `with_context/2` (see the module docs for the capture/install split).

  ## Example

      ctx = Dspy.Context.capture()
      Task.async(fn -> Dspy.Context.with_context(ctx, fn -> ... end) end)

  """
  @spec capture() :: t()
  def capture do
    context = %{
      overrides: Dspy.Settings.current_overrides(),
      callback_stack: Process.get(@stack_key)
    }

    context =
      case Lifecycle.active_call_id() do
        call_id when is_reference(call_id) -> Map.put(context, :active_call_id, call_id)
        _ -> context
      end

    case HistoryCapture.current() do
      [] -> context
      scopes -> Map.put(context, :history_captures, scopes)
    end
  end

  @doc """
  Install a captured context in the **current** process, run `fun`, and restore
  the previous values afterwards (in an `after` clause, so the restore happens
  on return, raise, throw, and exit alike).

  Installs:

  - the captured settings overrides via `Dspy.Settings.with_overrides/2`
    (which saves/restores its own frame);
  - the captured RAW callback stack, preserving the target's previous stack;
  - the captured active call ID when present, restoring the target's previous
    ID afterward. A context without that key leaves the enclosing ID in scope.
  - the captured history scopes when present, restoring the target's previous
    scopes afterward. A context without that key leaves enclosing captures in scope.

  Installs **no** usage frame (usage accumulators are not captured — see the
  module docs).

  Returns the value of `fun.()`.

  ## Example

      Dspy.Context.with_context(ctx, fn ->
        Dspy.Module.forward(program, inputs)
      end)

  """
  @spec with_context(t(), (-> any())) :: any()
  def with_context(ctx, fun)
      when is_map(ctx) and is_function(fun, 0) do
    prev_stack = Process.get(@stack_key)
    install? = ctx.callback_stack != nil

    if install? do
      Process.put(@stack_key, ctx.callback_stack)
    end

    try do
      case ctx do
        %{history_captures: scopes} ->
          HistoryCapture.with_scopes(scopes, fn -> with_lifecycle(ctx, fun) end)

        _ ->
          with_lifecycle(ctx, fun)
      end
    after
      if install? do
        restore_stack(prev_stack)
      end
    end
  end

  defp with_lifecycle(%{active_call_id: call_id, overrides: overrides}, fun)
       when is_reference(call_id) do
    Lifecycle.with_active_call_id(call_id, fn -> Dspy.Settings.with_overrides(overrides, fun) end)
  end

  defp with_lifecycle(%{overrides: overrides}, fun),
    do: Dspy.Settings.with_overrides(overrides, fun)

  defp restore_stack(nil), do: Process.delete(@stack_key)

  defp restore_stack(prev), do: Process.put(@stack_key, prev)
end
