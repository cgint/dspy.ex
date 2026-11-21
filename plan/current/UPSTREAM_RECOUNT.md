# DSPy 3.5.0 parity recount

The independent maintainer review accepted this pinned first baseline.
Of 162 inventory rows, 152 are in scope and 10 are approved exclusions.
Two are done, 66 are partial, and 84 are missing.
The upstream target is DSPy 3.5.0 at `4e9db7a83e71e4c36315a2402ae7ffd0c6493404`.
The Elixir reference is `07e3cb272de9c831462615ec4bed65871255db92`.

## Scope changes from 3.4.0

| Prior ID | Symbol | Evidence and decision |
|---|---|---|
| S034 | `CodeAct` | Removed from `dspy.predict` and its source file deleted in 3.5.0. Remove from the active inventory. |
| S039 | `ProgramOfThought` | Removed from `dspy.predict` and its source file deleted in 3.5.0. Remove from the active inventory. |
| S042 | `ReActV2` | Still exported in 3.5.0 as a deprecated subclass alias. Count its behavior under S041 `ReAct`. |
| U019 | `TypeSafe` | The DSPy experimental export and client were removed. The separately named vendored lm15 client does not restore this API. |
| N001 | `BoundingBox` | New root and adapter-type export. |
| N002 | `Prompt` | New `dspy.adapters` export. |
| N003 | `InterpreterPool` | New `dspy.primitives` export. |
| N004 | `InstructionProposer` | New explicit GEPA package export in 3.4.1. |
| N005 | `InferencePricing` | New explicit `dspy.lm15` export in 3.5.0. |
| N006 | `PricingTier` | New explicit `dspy.lm15` export in 3.5.0. |

The starting scope is the 3.4.0 inventory. Compare the pinned Git trees and
include new public exports in the same families, including explicit `dspy.lm15`
exports. The 3.4.0 scope tracked `BAMLAdapter` separately and excluded engine
internals and the proposer package. This recount retains those boundaries.
Aliases with the same behavior share a capability row. An `approved_exclusion`
records a separately approved capability outside the port's scope.

Rows marked `needs_golden` require fresh behavioral fixtures before a stronger
parity claim. `EvaluationResult`, `answer_exact_match`, and `answer_passage_match`
remain partial while approval for their Elixir-specific contracts is unresolved.

Run `mix run --no-start scripts/check_upstream_inventory.exs` from the
repository to validate the inventory and reproduce its status totals. The check
uses the Elixir commit in `UPSTREAM_PIN` to resolve source references.
