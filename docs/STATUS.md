# Status

Goal: Keep `dspy.ex` docs aligned with the Jido ecosystem reality (v2 on main branch; v1.x stable but headed toward deprecation).

Success criteria:
- Docs in `docs/` clearly state that Jido integration targets **Jido v2** (`2.0.0-rc.1` on Hex) and that `../jido` is the main-branch checkout.
- An implementation plan exists for sequencing DSPy-core vs Jido integration work.
- `dspy.ex` remains library-only; any web UI lives in a separate package/app.
- Low-level LLM provider access is delegated to `req_llm` via an adapter.

Decisions (with rationale):
- Document Jido v2 as the target line (avoids building new work on the soon-deprecated v1.x branch).
- Keep `dspy.ex` library-only; avoid bundling Phoenix/web concerns (matches upstream DSPy and reduces maintenance).
- Use `req_llm` as the provider layer to avoid maintaining LLM HTTP APIs inside `dspy.ex`.

Open questions:
- Do we want a separate repo/package for `dspy_jido`, or keep it in-tree initially?
- Should `dspy.ex` ship only `Dspy.LM.ReqLLM`, or also keep other LM adapters as optional add-ons?

Learnings:
- This repo has a local Jido checkout at `../jido` and should track upstream main (v2).

Verification run:
- `git diff --stat`
- `rg -n "Jido v2|2.0.0-rc.1|../jido|v1.x" docs/*.md`
- `ls -la docs/IMPL_PLAN.md docs/impl_plan.d2`
