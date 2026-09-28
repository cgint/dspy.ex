# PLAN — dspy.ex toward Python DSPy 3.4.0 parity

| Target | Symbols done/total (facet %) | Phase | Next | Updated |
|---|---|---|---|---|
| Python DSPy **3.4.0** (`2413b67a4d`) | ? / 160 (count running) | A→B | Phase B inventory | 2026-09-26 |

Status: **v2 — agreed Horst + Greta 2026-09-26** (risk noted by Greta: medium-value "done" rows judged at symbol level may overstate; the checker pass re-verifies all done/n-a rows). Detail: enough to steer and measure; each slice gets its own contract (Clarity Gate).
Current position lives in `00_NOW.md` (single source; not repeated here).

## 1. Target
Behavioral parity with Python DSPy **3.4.0** (tag `3.4.0`, sha `2413b67a4d`, reference worktree `../dspy-3.4.0`) for everything public and user-facing, native Elixir.
- 3.4.0 is well past our last audited pin (`661a612c`, ≈3.2+). New surface never audited (e.g. `lm15`, Flex, typed LM exception hierarchy, XMLAdapter). `GAP_ANALYSIS_2026-05.md` is background only.
- Parity with 3.4.0 is the **end point**, reached through usable milestones (§4), not the first milestone. Not v2 first: dspy.ex is built on the 3.x API.

## 2. Scope and status vocabulary
- **Item = public symbol** (every `__all__` export + top-level functions; list generated mechanically → fixed denominator).
- **Status**: `done` (test pins it AND behavior matches upstream; cite upstream test as oracle where one exists) · `partial` · `missing` · `idiom` (Elixir-equivalent, different shape, e.g. `asyncify` → Task) · `n/a` (Python-only mechanism).
- **`n/a` needs user approval**: one table, reason each. Candidates: pickle, Deno sandbox, async/sync duplication. Streaming and GEPA are *not* n/a by default.
- **Denominator frozen at phase-B exit** (baseline v1); later finds are reported as "added +n".

## 3. How we prioritize (user guidance + rubric)
Two maps side by side: where dspy.ex stands, and which DSPy release introduced each item (≤2.6, 3.0 … 3.4).
- **Value** H/M/L: H = used by a consumer (5 repos) or on the core path (signature→predict→adapter→LM→evaluate); M = in upstream tutorials/top-level docs; L = otherwise.
- **Effort** S/M/L: S = <1 slice, 1 module, no invariant; M = 1–2 slices or touches an invariant; L = multi-slice, new subsystem, or needs a dependency.
- **Score** = value (3/2/1) ÷ effort (1/2/4); ties → earlier DSPy release first. Ranked **within dependency order** (e.g. callbacks before streaming).
- Low-hanging fruit with real value goes first. Items flagged **breaking** (would change the consumer contract) are never picked as quick wins; they are batched for a user decision.

## 4. Milestones (defined in phase C)
- dspy.ex milestones M1..Mn = usable bundles, each defined by what a user can do afterwards and mapped to "covers features introduced up to 3.x" (M1 may take cheap 3.3/3.4 wins).
- **Milestone exit test**: a runnable end-to-end example (`examples/` or `test/acceptance`) exercising the bundle + consumer canary green + consumer-contract tests green.
- Each milestone reports "% of 3.x surface covered" so both maps stay visible.

## 5. Phases
| Phase | Content | Exit |
|---|---|---|
| A. Foundations | H0 (done, v0.3.44), H0b crash/timeout hardening | H0b released; its user decisions (D-U1/D-U2) answered |
| B. Inventory | 3.4.0 surface inventory (method §6) | Greta+Horst agree; denominator frozen; numbers in 00_NOW |
| C. Milestones | M1..Mn cut from ranked backlog; `n/a` list | Greta+Horst agree → **user agrees milestones + n/a list** |
| D. Execute | Slices via HOW_WE_WORK | per milestone exit test |
| E. Keep up | Delta inventory at each upstream release | recurring |

## 6. Phase B method (Greta runs, Horst verifies)
- **Step 0 (script, not scouts):** `symbols.csv` from `../dspy-3.4.0` `__init__`/`__all__` + top-level fns: id, symbol, kind, upstream file:line, `introduced_in` (first tag containing it).
- **6 readonly scouts in parallel:** B1 top-level/settings/primitives/signatures/exceptions · B2 predict (+Flex) · B3 adapters/types · B4 clients/lm15/cache/streaming · B5 evaluate/teleprompt/propose · B6 retrievers/utils/datasets/experimental. Scouts fill rows; they cannot add or drop rows silently.
- **Columns:** id · symbol · kind · upstream file:line · upstream test · dspy.ex file:line · dspy.ex test · status · gap note · value (+why) · effort (+why) · deps (`DEP:<pkg>` for external) · breaking Y/N · introduced_in · confidence.
- **Facets only where they matter** (Horst amendment to avoid a 100% deep-dive): constructor params / key methods / key behaviors are itemized only for symbols with value H and status done/partial. Other symbols are judged at symbol level.
- **Checks:** one adversarial checker scout re-verifies every `done`/`n/a`/`idiom` row; Greta consolidates, reviews all n/a/idiom/partial notes, samples 10% refs; Horst verifies 2 rows per area (12) + row count = symbols.csv count.
- **Output:** `plan/current/GAP_ANALYSIS_3.4.0.md` (per-area + per-release table, ranked backlog, first M1..Mn proposal); raw CSVs under `plan/research/pi_handoffs/phaseB/`. Estimate ≈ half a day wall-clock.

## 7. Policies
- **Breaking changes:** 0.x semver; `test/consumer_contract/` is frozen; a parity item needing a break → user decision, batched.
- **Dependencies:** any new dep (e.g. streaming, MCP, GEPA) → escalate to user. No Python runtime ever (user decision).

## 8. Open decisions
| # | Question | Owner | Status |
|---|---|---|---|
| 1 | Scope of `experimental/`, `datasets/`, GEPA, streaming | proposed in phase B/C → user | open |
| 2 | Phase B in parallel with H0b | Horst+Greta | agreed: parallel |
| 3 | H0b user decisions D-U1/D-U2 | user (via Horst) | pending Greta's H0b package |

## 9. Maintenance
Horst owns this; Greta reviews every material change; the user sees changes via 00_NOW. At each phase exit: record what we assumed that turned out wrong.
