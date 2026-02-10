# Publishing strategy (incremental, user-usable slices)

## Diagram

![Publishing loop](./diagrams/publishing_loop.svg)

## Goal

Publish **feature-by-feature** so users can adopt the library early, while keeping each increment something we feel good putting into a public repo.

This doc defines what we consider **publishable** and **when** we push changes.

## Policy (default)

- **Push continuously to `main`** once a change is *publishable* (see checklist below).
- Use **semver tags/releases** (0.x) to give users a stable reference point.
  - `main` can move quickly; tags are the user pin.
  - Policy: when a change is publishable, tag it as the next patch/minor in `0.x`.

If the repo later adopts branch protection / PR-only workflow, we can switch to: push a branch → open a PR → merge, while keeping the same publishable checklist.

## What is “publishable” (minimum bar)

A change is publishable when:

1. **Works end-to-end for a user slice**
   - A minimal workflow can be executed (e.g. Predict + signature + parse outputs).
2. **Proven deterministically (offline)**
   - At least one deterministic test exists (acceptance-style preferred).
3. **Documented in a human way**
   - `docs/OVERVIEW.md` updated with:
     - a short example (copy/paste)
     - and an evidence link to the test(s).
4. **Public-repo hygiene**
   - No secrets, no captured sensitive logs.
   - Quiet-by-default behavior (avoid noisy logging defaults).
5. **Verification green**
   - `mix format` and `mix test` pass.
   - Run `./precommit.sh` for larger diffs.

## Release tagging (suggested)

- Tag a release when a new user-visible workflow slice becomes stable enough to recommend publicly.
- Keep early versions in `0.x` and document limitations explicitly.

## Version single source of truth

- The repo-root `VERSION` file is the **canonical** library version.
- The recommended stable git tag is always: `v` + `VERSION`.
- `mix.exs` reads `VERSION` at compile-time; do not hardcode versions across multiple docs.

## Release checklist (minimal)

1. Update `VERSION` to `X.Y.Z`.
2. Run verification:
   - `./precommit.sh`
   - (optionally) `scripts/verify_all.sh`
3. Prepend a new row to `docs/RELEASES.md` for `vX.Y.Z` with tag-pinned evidence links.
4. Commit changes.
5. Create an annotated tag:

   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z: <short summary>"
   ```

6. Push `main` and the tag:

   ```bash
   git push origin main
   git push origin vX.Y.Z
   ```

## Notes

- We prefer "small", "shippable" increments over large batches.
- The acceptance suite derived from `dspy-intro/src` is the primary driver for user-facing parity.
