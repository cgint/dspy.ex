# Contributing to dspy.ex

Thanks for helping build an **Elixir-native DSPy port** that’s reliable and welcoming for open-source adoption.

This repo follows an **adoption-first** approach:
- ship small, user-valuable slices
- prove them with deterministic tests (offline)
- document them with evidence links

## Quick links

- What works today + evidence: `docs/OVERVIEW.md`
- North star (priorities): `plan/NORTH_STAR.md`
- Current backlog/health: `plan/STATUS.md`
- End-to-end verification: `scripts/verify_all.sh`

## Requirements

- Elixir: `~> 1.18` (see `mix.exs`)
- OTP: whatever ships with your Elixir distribution for 1.18

## Repo layout (where things go)

- `lib/` — core library (`:dspy`)
- `extras/dspy_extras/` — optional/experimental integrations (Phoenix/UI, GenStage, legacy HTTP, etc.)
- `docs/` — stable, user-facing docs
- `plan/` — roadmap + status + decisions
- `agent/` — assistant context (`MEMORY.md`) + stable working principles (`SOUL.md`)

## Getting started (development)

```bash
mix deps.get
mix format
mix compile --warnings-as-errors
mix test
```

To verify both core + extras:

```bash
scripts/verify_all.sh
```

## Troubleshooting

### `Error opening ETS file ~/.hex/cache.ets: :badfile`

This usually indicates a **corrupted local Hex cache**.

It’s safe to delete the cache file and re-fetch dependencies:

```bash
rm -f ~/.hex/cache.ets
mix deps.get
```

If you prefer not to delete files directly, you can also try:

```bash
mix hex.clean --all
```

## Integration / network tests (opt-in)

By default, `mix test` excludes tests tagged `:integration` and `:network`.

Run opt-in tests locally:

```bash
mix test --include integration --include network test/...
```

Provider smoke tests may require API keys and may incur costs.

## What we consider a “good” contribution

### 1) Keep diffs small and reviewable

Prefer focused PRs that touch one subsystem and include a clear verification step.

### 2) Tests are the spec

If a feature/behavior is user-facing, it should have deterministic proof artifacts:
- acceptance-style tests preferred
- unit tests for tight contracts (parsers, parameter updates, error shapes)

Avoid network calls in default test runs.

### 3) Keep core small

Core `:dspy` should remain lightweight and library-first.
If something is optional/heavy (UI, orchestration frameworks, etc.), it belongs in `extras/`.

### 4) Prefer stable parameter contracts

Teleprompters should mutate programs via the parameter callbacks:
- `parameters/1`
- `update_parameters/2`

Avoid dynamic module generation (BEAM atom leak risk).

### 5) Public-repo hygiene

- Do not commit secrets.
- Don’t print sensitive data.
- Keep logging quiet-by-default (use `Logger` and verbosity gating).

## How to report a bug (or propose a feature)

Please include:

- **dspy.ex version/tag** (see `docs/RELEASES.md`)
- **Elixir + OTP versions** (`elixir -v`)
- A **minimal reproduction**
  - ideally a single `.exs` file
  - avoid API keys and network calls when possible

Tip: a great repro can often be expressed as a deterministic test.

## Documentation expectations

If you add a new user-facing capability, also update at least one of:
- `docs/OVERVIEW.md` (add a proof link)
- `docs/RELEASES.md` (tag-pinned evidence links)

## Running precommit checks

For bigger diffs, run:

```bash
./precommit.sh
```
