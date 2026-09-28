# USER.md — Collaboration preferences and explicit user instructions

This file captures durable preferences the user explicitly gave or that we agreed to. Keep it concise, dated, and actionable.

## 2026-05-17 — Agent self-organization and persistence

User intent:
- The assistant should organize itself in repo files so future sessions can resume from durable context instead of chat history.
- `AGENTS.md` must be treated as the bootstrap entry point: assume it may be the only repo-specific information available at the start of a new session.
- The assistant should collect, persist, and organize knowledge in `agent/`, `plan/`, and related docs.
- Persist information the user specifically says, and decisions we agree on.
- Include timestamps for important arrangements/decisions so the timeline remains understandable.
- The assistant should be a **critical yet constructive partner on eye-level**, not a yes-sayer.

Operational implications:
- When a durable user preference or agreed decision appears in chat, write it down promptly in the appropriate file.
- Keep `AGENTS.md` compact but strong enough to bootstrap the next session.
- Use `agent/MEMORY.md` for compact resume context, `agent/SOUL.md` for stable behavior, and `agent/USER.md` for explicit user preferences.
- For external/web research, persist reusable findings with source/context and date, usually under `plan/research/` or a relevant planning doc.

## 2026-05-17 — Use `quality-discipline` as a standing guardrail

User instruction:
- Treat the `quality-discipline` skill as a guardrail for work in this repo.

Operational implications:
- Work steadily; correctness beats speed.
- Prefer evidence over assumptions; investigate uncertainty before changing code.
- Use small, verified vertical slices.
- No hacks, hidden workarounds, or workaround final states.
- Every claimed-complete feature needs automated test coverage or explicit verification evidence.
- Avoid external provider calls in automated tests unless explicitly required.
- Keep durable notes/status/memory current as work progresses.
- Do not mark work complete until explicit success criteria are mapped to concrete evidence.

## 2026-09-26 — Autonomous parity slices without breaking consumers (Firstmate mode)

User instruction:
- Goal: move dspy.ex step-by-step closer to the original Python DSPy feature set **without breaking existing consumers** (`~/dev/agent-coding-gui`, `elix-live-chat`, `third-eye-liveview`, `finance-partner`, `my-speech-google`; all depend on this repo via git).
- The lead (strong planner model) must **autonomously evaluate and close slice after slice without asking the user**.
- Grunt work (scouting, implementation, verification) is delegated to sub-agents on the **home-network LLM** (cheap but capable; currently `PI_WORKER_DEFAULT_MODEL=home-llm/...`), supervised via Herdr.
- Lead keeps: slice selection, acceptance review, independent verification, commit.

- 2026-09-26: **Python DSPy is the behavioral reference.** When a design choice diverges from upstream (e.g. usage merge-back from child processes), do it the way Python DSPy does it; don't propose "BEAM-better" divergences as defaults.
- 2026-09-26: **Native Elixir port is decided — no Python wrapper, ever silently.** No Python runtime (Pythonx, snakepit/DSPex, ports/erlport, uv) in `lib/` or runtime deps. Any Python-backed piece, even test-only (e.g. a parity oracle), needs explicit user approval first. Jido/LiveView stay optional layers on top.
