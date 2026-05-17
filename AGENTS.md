# AGENTS.md — How this repo is organized (for continuity)

This repository is being developed as an **Elixir-native port** of the upstream **Python DSPy** library (`../dspy`), designed to be reliable and welcoming for open-source adoption in the BEAM/Elixir ecosystem.

## Bootstrap rule — assume this file is all a new session has

Treat `AGENTS.md` as the only repo-specific information that may be available when a new assistant session starts. Therefore this file must:
- point to the minimum reading path needed to recover context;
- preserve durable user preferences and operating rules by reference;
- tell the assistant where to persist new knowledge before it is lost in chat.

When important information is learned, **write it down** in the right durable place (`agent/`, `plan/`, `docs/`, or `openspec/`). Do not rely on chat memory.

## Start here (reading order)
1. `agent/USER.md` — explicit user preferences and collaboration instructions.
2. `agent/SOUL.md` — the assistant’s stable operating principles and learned habits.
3. `agent/MEMORY.md` — compact context window (decisions + “how to resume quickly”).
4. `agent/WAYOFWORKING.md` — operational playbook (delegation + context hygiene).
5. `plan/NORTH_STAR.md` — the purpose, constraints, and priorities (why/what matters).
6. `plan/STATUS.md` — the current heartbeat (health, decisions, next tasks, verification).
7. `plan/RELEASE_MILESTONES.md` — the step-by-step milestone roadmap (what we ship first).
8. `plan/INTERFACE_COMPATIBILITY.md` — explicit mapping to Python DSPy and DSPex-snakepit.
9. `plan/REFERENCE_DSPY_INTRO.md` — reference Python example suite → acceptance test candidates.
10. `plan/ITERATION_LOOPS.md` — how we keep iterating safely (outer loop + delegated inner loop).
11. `plan/QUALITY_BAR.md` — quality bar + testing principles (tests as specification).
12. `plan/PORTING_CHARTER.md` — scope + operating agreement for how we work.

## Directory intent
- `docs/`
  - “Classic docs”: technical references, user-facing docs, integration notes.
  - Should be reasonably stable and suitable for external readers.

- `plan/`
  - “Agile planning artifacts”: north star, roadmap, milestones, status, decisions, diagrams.
  - Meant to make it easy to resume work after a break without re-deriving context.

- `agent/`
  - Assistant self-organization: compact memory/context, explicit user preferences, and long-lived operating principles.
  - The goal is to reduce context loss between sessions.
  - Current files:
    - `agent/USER.md` — explicit user preferences and agreements.
    - `agent/SOUL.md` — stable assistant posture and decision principles.
    - `agent/MEMORY.md` — compact repo memory / resume context.
    - `agent/WAYOFWORKING.md` — operational loop, delegation, context hygiene.

## Continuity rule: persist + timestamp
- Don’t leave important decisions/learnings only in chat — **persist them** in `plan/` and `agent/`.
- Persist information the user explicitly gives and decisions we agree on.
- Add dates to durable decisions, user preferences, research notes, and process changes so the timeline remains understandable.
- Prefer **frequent, small commits** (including docs) so we can “time travel” and see how the plan/knowledge/assistant evolves.
- Keep `plan/STATUS.md` current so a restart can resume without re-deriving context.
- If web/external research affects direction, save the useful findings with date + source context (usually under `plan/research/` or a relevant planning doc).

## Working mode (Clarity First, standing approval)
- Be a **critical yet constructive partner on eye-level**: challenge unclear goals, weak assumptions, and hidden risks while offering concrete alternatives.
- Planning phase: investigate + propose + update planning artifacts.
- Execution phase: proceed autonomously within this repo (implement + delegate) by default.
  - The user can say **“Hold/Stop”** to pause.
  - I will still proactively flag/ask on “handshake” items (deps changes, broad refactors, system-wide/heavy commands, or anything that might risk leaking secrets).

## Sub-agent handoffs (Pi): when to use them

Persisted learnings from experimenting in this repo:

- Prefer **simple delegated runs** using `pi-profile minimal -p @file ... "goal"` for scouting, inventories, and bounded edits.
- Use handoffs when the task would otherwise bloat/taint the driver context window: multi-file scans, evidence collection, repetitive changes across many files, or independent verification.
- Avoid handoffs for tiny edits (single-line/single-file obvious changes).
- If you run handoffs concurrently (batch scripts), expect possible provider/rate-limit failures; be ready to rerun only the failed handoffs.
- Post-handoff rule of thumb: **review first**. If follow-up edits are needed, prefer a second handoff; if the driver makes fixups anyway, explicitly record what was changed and why.

### Continuity rule: persist handoff learnings

When we experiment with handoffs in this repo, the assistant is expected to:
- persist what worked/failed and why (esp. when provider/model/tool defaults matter)
- record heuristics for when a handoff is beneficial vs when it’s unnecessary overhead
- update the relevant guidance docs (this `AGENTS.md` and/or the global `sub-agent-handoff` skill) so future runs start with the simplest correct approach

### Credentials + networked examples
- I *can* run tools/programs/examples that require credentials (e.g. real provider scripts under `examples/providers/*`) **if the required env vars are already set in the current shell/session** and you explicitly ask me to run them.
- I will **not** edit `.env` files or add secrets to the repo.
- If credentials are missing, I’ll explain what’s needed and stop rather than guessing.

(See `plan/WORKFLOW.md` for the detailed guardrails.)
