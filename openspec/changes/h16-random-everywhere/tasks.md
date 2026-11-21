# Tasks

## 1. Core sampling

- [x] 1.1 Check existing tests and establish TDD failures for caller-state mutation in evaluation, Trainset, Ensemble, and BootstrapFewShot.
- [x] 1.2 Thread explicit state through the four paths. Verify caller-state preservation and CPython fold, aggregation size, and candidate demo order in their public tests.
- [x] 1.3 Match CPython’s sample and choice algorithms. Verify pool and set sampling through Trainset, labeled-only demo order, and exact float and choice vectors.
- [x] 1.4 Verify transitive caller-state preservation through LabeledFewShot, SIMBA, and MIPROv2. Document seed changes and DataLoader alternatives in the release and API docs.

## 2. Verification

- [ ] 2.1 Verify the final source inventory, full precommit, and frozen consumer contract. Run the offline examples and committed consumer replays before merging.
- [ ] 2.2 [User Verification] Review the documented seeded-order change against a project that pins a seed. This task belongs exclusively to the human user and must never be checked off by the agent.
