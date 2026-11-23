# Elixir / OTP Stack Best Practices (`dspy.ex`)

> Standing architectural guardrails for `dspy.ex` (recorded 2026-11-23, incorporating input from the `overview-app` Elixir/OTP review and the `01e5777..2873481` internal audit).

## Core Principle

Lean on built-in BEAM/OTP primitives and immutable functional data flow first. Never port Python's mutable globals, thread-local state, or custom concurrency/streaming protocols literally onto the BEAM.

## Design Red Flags

Stop and verify against OTP idioms before writing code if a design introduces:

1. **Ambient / process-dictionary state:** Any new `Process.put/get` or global `GenServer` lookup where an explicit immutable struct/opt (`%Dspy.Context{}` / `opts`) can be passed.
2. **Unsupervised processes:** Any `GenServer.start/2`, raw `spawn`/`spawn_link`/`spawn_monitor`, or `Task.async_stream` without `Task.Supervisor`, finite timeout, and `:kill_task`.
3. **Fat or blocking GenServers:** Any GenServer > ~250 lines, or performing blocking disk/network I/O (`File.rename/2`, directory scans, HTTP calls) inside `init/1` or `handle_call/3` instead of ETS reads, `handle_continue/2`, or supervised tasks.
4. **Stacked retry loops:** Multiple retry loops across layers (e.g. `Req`/`ReqLLM` wire retries × outer `Process.sleep/1` loop) instead of one transport retry owner (`429` + `Retry-After` + jittered backoff) and one bounded semantic output-parse retry owner.
5. **Unvalidated parity bloat or internal coupling:** Adding zero-consumer Python-parity modules or coupling to dependency internals (long-lived git-SHA pins) before existing downstream consumers can upgrade cleanly.

## "Use X, Don't Build Y" (Library Checklist)

- **Config & Context:** Snapshot defaults once at public boundaries into an explicit immutable `%Dspy.Context{}` / `opts` and thread it down. Back read-heavy global defaults with ETS (`read_concurrency: true`, re-populated on restart from application env). Avoid `:persistent_term` for settings that consumers may reconfigure per request (triggers global BEAM GC). Never do 10+ `GenServer.call`s per inference call or silently drop unknown keys via `struct/2`.
- **Concurrency:** Use `Task.Supervisor.async_stream_nolink` with explicit timeouts and `on_timeout: :kill_task`. Never use raw `spawn_link` coordinators or unref-tagged `receive` loops that can hang trapping callers (GenServers / LiveViews).
- **Streaming:** Maintain one clean, cancellable OTP stream transport. Avoid multi-message hand-rolled backpressure protocols when upstream HTTP clients buffer unconditionally. Never route non-streaming `Predict.forward/2` through streaming plumbing or inject undeclared tuple keys into structs.
- **Durability:** For user checkpoints and disk caches, write to an `:exclusive` temp file in the target directory → `:file.sync/1` → `File.close/1` → `File.rename/2` (with `try/after` temp cleanup). Never evict existing valid records before new publication succeeds.
- **Dependencies & Testing:** Declare direct dependencies honestly in `mix.exs`, keep releases Hex-publishable (no long-lived git-SHA pins to dependency internals), default tests to `async: true` via explicit context/opts instead of global `Dspy.configure/1`, and enforce Credo / Dialyzer / `@spec` hygiene.

## Critic Panel Counterweight

In design and pre-merge reviews (`LEAD.md`), treat **Python-isms, over-engineering, unsupervised processes, blocking GenServer I/O, and zero-consumer parity bloat** as **blocking findings** on par with correctness bugs.

## Software Development Quality Guidelines (Mandatory for All Slices)

Every implementation slice (internal or delegated to Terra) must satisfy:

1. **Red–Green TDD:** Write failing tests reproducing the bug or specifying the new behavior *before* changing `lib/`. Never claim a bug fix without a regression test that fails on the unfixed code.
2. **Small, Cohesive Modules & Functions:** Prefer small focused helpers and structs over god-modules (> 400 lines) or multi-argument positional pipelines (> 5 args).
3. **Typespecs & Static Checks:** Add `@spec` to every new or modified public function; keep `mix compile --warnings-as-errors` and `mix format --check-formatted` 100% clean (plus Credo/Dialyzer once enabled in `mix.exs`).
4. **Async-First Tests:** Default new tests to `async: true` using explicit structs/opts or scoped `Dspy.context/2` — never mutate global `Dspy.configure/1` in new tests.
5. **Evidence-Gated Acceptance:** No slice is accepted without passing focused tests, full `mix test`, and clean `git diff --stat` scoped strictly to the brief.

