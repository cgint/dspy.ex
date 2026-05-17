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
