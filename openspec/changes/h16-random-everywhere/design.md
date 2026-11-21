# Preserve the caller’s random state

The active target is the core library. The [proposal](proposal.md) records the original inventory and alternatives. The [specification](specs/random-everywhere/spec.md) defines the observable requirements.

## Design decisions

- R1. The caller’s Erlang random state is independent of library sampling. Seeded selections can differ from v0.4.11. Record the affected APIs in the release and compatibility notes.
- R2. Random `Trainset.sample/3` uses CPython’s sampling algorithm for sampling without replacement. `LabeledFewShot` inherits that algorithm. Its existing time-based default seed stays in place, and an explicit seed of `0` matches Python’s labeled-only selection.
- R3. Keep the `Trainset` signatures. Document DataLoader’s corresponding operations for callers who need them. Keep the full Trainset strategy and three-way split support.
- R4. Retain `{state, result}` for every `Dspy.Random` draw. Add CPython’s 53-bit `random/1` and list `choice/2` in that form. Bootstrap sampling keeps constant-time indexed access to its population and preserves `Enum.EmptyError` for an empty population. Direct unseeded sampling uses fresh entropy, following DataLoader. Configured optimizers retain their existing stored seed defaults.
- R5. Keep existing optimizer and evaluation algorithms around the draws. The candidate search and trace semantics of Python’s BootstrapFewShot are follow-up parity work. Ensemble aggregation uses an explicit size stream independent of member sampling.

## Verification

Use exact CPython vectors for the generator and public sample order. Verify caller state in fresh processes through evaluation, Trainset, and the optimizer entry points. The normal test suite and the consumer gates cover the wider integration path. The historical proposal’s mutation inventory remains useful for targeted fault injection. Tests that exercise the public result carry the acceptance claims.
