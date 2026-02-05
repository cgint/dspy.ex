# QUALITY_BAR.md — High quality, smart (tests as specification)

## Diagram
![Quality loop](./diagrams/quality_loop.svg)

## Summary
Quality is a product feature of this port: we want a library that is **safe to depend on** and **easy to maintain**.

The quality bar is “high but smart”:
- go deep on the **most-used workflows**
- keep tests **deterministic** (no network, no API keys)
- avoid brittle assertions, but lock down key interfaces for adoption

## Testing principles (Elixir)
1. **Mock external boundaries**
   - LLM/provider calls must be mocked.
   - Prefer explicit behaviours + mocks (Mox) when it improves clarity/concurrency.

2. **Determinism first**
   - Fixed mock LM responses.
   - Seed any randomness.
   - Avoid time-based assertions (or freeze time / inject clock).

3. **Layered tests**
   - **Unit tests**: prompt building, output parsing, validation, parameter updates.
   - **Acceptance tests**: end-to-end flows that mimic real usage (from `dspy-intro`).
   - **(Later) Oracle tests**: side-by-side comparisons with Python DSPy for tricky semantics.

4. **Snapshots, carefully**
   - Snapshot tests are useful for long prompt strings.
   - Keep them non-brittle:
     - canonicalize dynamic values
     - prefer asserting key sections/markers unless full-string stability is required

## Reference workflows (source of truth)
- Upstream DSPy code: `../dspy`
- Example suite: `/Users/cgint/dev/dspy-intro/src` (see `plan/REFERENCE_DSPY_INTRO.md`)

## Best-practices research log (asks.sh)
### 2026-02-05 — Testing external services / LLM providers
- Topic: `liveview-elixir-phoenix-beam`
- Question: "What are best practices for testing Elixir libraries that call external HTTP/LLM providers? Mention behaviours, Mox, deterministic tests, and how to avoid brittle tests."
- Takeaways:
  - Use **behaviours** as explicit contracts and decouple core logic from provider implementations.
  - Use **Mox** for concurrent-safe mocks with explicit expectations.
  - Make tests deterministic: mock time/randomness, avoid order sensitivity.

### 2026-02-05 — Snapshot testing
- Topic: `liveview-elixir-phoenix-beam`
- Question: "What are best practices for snapshot testing in Elixir (e.g., long prompt strings), and how to keep snapshots deterministic and not brittle?"
- Takeaways:
  - Treat snapshots as code: version control + review; don’t blindly regenerate.
  - Ensure determinism via canonicalization/mocking.

## Maintenance principle (later)
When we start handling issues publicly, every bug fix should ideally include:
- a minimal reproducible test
- a fix
- verification notes

(We will add an explicit issue-handling playbook once we start open-sourcing or receiving issues.)
