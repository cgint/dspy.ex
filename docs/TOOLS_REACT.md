# Tools + ReAct (reasoning + acting)

## Diagram

![Tools/ReAct flow](./diagrams/tools_react_flow.svg)

## What’s proven in core `:dspy`

This repo includes an adoption-first, deterministic slice for **tool use** via a small
ReAct loop:

- Define tools with `Dspy.Tools.new_tool/4`
- Run a ReAct loop with `Dspy.Tools.React.run/3`
- Observe tool calls via callbacks (`Dspy.Tools.Callback`)

It’s designed so you can prove your integrations **offline** by using a fake LM.

## Quick start (offline)

Run the official deterministic example:

```bash
mix run examples/react_tool_logging_offline.exs
```

## Core API surface

### 1) Tools

Create tools using `Dspy.Tools.new_tool/4`:

- `name` and `description` are for the LM
- `function` is executed locally with an **args map** (string keys)
- `timeout` is enforced by `Dspy.Tools.React` (tool functions run in a `Task`)

### 2) ReAct loop

Create a ReAct runner:

```elixir
react = Dspy.Tools.React.new(lm, tools,
  max_steps: 10,
  stop_words: ["Observation:", "Answer:"]
)

{:ok, result} = Dspy.Tools.React.run(react, "What is 2+3?")
result.answer
```

Supported (proven) per-run request-map options:

- `max_tokens:`
- `max_completion_tokens:`
- `temperature:`

These are forwarded into the LM request map.

### 3) Tool callbacks (observability)

Implement `Dspy.Tools.Callback`:

- `on_tool_start(call_id, tool, inputs, state)`
- `on_tool_end(call_id, tool, outputs, error, state)`

Then pass callbacks via `run/3`:

```elixir
cb = {MyCallbackModule, my_state}
{:ok, result} = Dspy.Tools.React.run(react, question, callbacks: [cb])
```

### 4) Tool timeouts

Each tool has a `timeout` (ms). ReAct executes tool functions in a separate `Task` and enforces
this timeout.

On timeout:
- the callback receives `error = %{kind: :timeout, message: "Tool execution timed out"}`
- the ReAct loop appends an `Observation:` error line and continues

## Built-in tools

`Dspy.Tools.builtin_tools/0` currently includes:

- `search` (mock / deterministic; **no network**)
- `calculate` (safe math expression evaluation; **no `Code.eval_string`**)
- `datetime` (UTC time; non-deterministic)

For stable workflows, prefer defining your own tools explicitly.

## Evidence (tests)

- ReAct tool logging callbacks (acceptance): `test/acceptance/simplest_tool_logging_acceptance_test.exs`
- ReAct uses request maps + stop words: `test/tools_request_map_test.exs`
- ReAct tool timeouts: `test/tools_react_tool_timeout_test.exs`
- Tool helper `execute_tool/3` behavior: `test/tools_execute_tool_test.exs`
- ToolRegistry auto-start: `test/tools_registry_autostart_test.exs`
- Builtin tools metadata honesty: `test/tools_builtin_tools_test.exs`
