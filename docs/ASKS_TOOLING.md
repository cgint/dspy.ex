# `asks.sh`: research tool for planning & implementation (DSPy + Elixir)

This project can use `asks.sh` to quickly query curated documentation topics during **Planning** (RFCs, design choices) and **Implementation** (API details, patterns, best practices).

## Key point

Use `asks.sh` as the default way to gather **DSPy** and **Elixir/Phoenix/LiveView** reference material while working on `dspy.ex`.

Also note: this repo includes a full checkout of the upstream DSPy Python code at:

- `../dspy`

That codebase is often the **most authoritative source** for behavior and edge-cases.
Some documentation content scraped from the DSPy website may lag behind current implementation details, so when in doubt:

1. prefer checking `../dspy` source, and
2. use `asks.sh` to quickly locate relevant concepts/examples.

This repo also includes a checkout of **Jido** at:

- `../jido`

Important: `dspy.ex` work that integrates with Jido should target the **Jido v2** line (currently published as a pre-release on Hex at `https://hex.pm/packages/jido/2.0.0-rc.1`), which corresponds to the **main branch** of `https://github.com/agentjido/jido`. The `v1.x` branch is the stable line but expected to be deprecated soon.

## Usage

### List available topics

```bash
asks.sh
```

### Ask DSPy questions

Recommended topics:
- `dspy-general-knowhow`
- `dspy-code-examples`

Examples:

```bash
asks.sh dspy-general-knowhow "What are DSPy Signatures and how do they map to Modules?"
asks.sh dspy-code-examples "Show a minimal BootstrapFewShot loop and explain how metrics are applied"
```

### Ask Elixir / Phoenix / LiveView questions

Recommended topic:
- `liveview-elixir-phoenix-beam`

Examples:

```bash
asks.sh liveview-elixir-phoenix-beam "What’s a good pattern to stream long-running task progress to LiveView?"
asks.sh liveview-elixir-phoenix-beam "How should OTP supervision be structured for agent-style workflows?"
```

## Working agreement

When we make non-trivial architectural decisions (e.g. LM adapter shape, evaluation design, optimizer loops), we should:

1. Query `asks.sh` for relevant DSPy/Elixir references.
2. Summarize the findings in the relevant planning doc (or PR description) with:
   - topic used
   - question
   - short takeaway
