# Status

Goal: Keep `dspy.ex` docs aligned with the Jido ecosystem reality (v2 on main branch; v1.x stable but headed toward deprecation).

Success criteria:
- Docs in `docs/` clearly state that Jido integration targets **Jido v2** (`2.0.0-rc.1` on Hex) and that `../jido` is the main-branch checkout.

Decisions (with rationale):
- Document Jido v2 as the target line (avoids building new work on the soon-deprecated v1.x branch).

Open questions:
- None for this change.

Learnings:
- This repo has a local Jido checkout at `../jido` and should track upstream main (v2).

Verification run:
- `git diff --stat`
- `rg -n "Jido v2|2.0.0-rc.1|../jido|v1.x" docs/*.md`
