# signature-json-adapter-parity — harden JSONAdapter parsing + keyset contract

## Summary

Harden `Dspy.Signature.Adapters.JSONAdapter` to be more robust to common malformed JSON outputs (fences/trailing text) while making keyset and typed-casting behavior explicit and parity-aligned with upstream Python DSPy.

## What’s already true today

- JSONAdapter exists and is JSON-only.
- Typed `schema:` casting is already integrated.

## What this change adds

- Deterministic preprocessing/repair (no new deps initially).
- Explicit keyset rule: require all signature output keys; ignore extras (upstream parity).
- Test-pinned error tags.
