# Eliminate contradictory structured-output contracts

## Why

### Summary
A Gemini production response followed the typed schema displayed in the prompt and returned the bare typed payload, while JSONAdapter correctly required the signature-level envelope (`{"result": ...}`) and rejected it. The library currently has two independent authors of the output contract: JSONAdapter states the envelope, but `Dspy.Signature.to_prompt/3` displays only each typed field's inner schema.

The same contract must drive provider-native structured output where available and the text-prompt fallback elsewhere, so model instructions, provider enforcement, and parsing cannot diverge.

### Original user request (verbatim)
"So we are NOT in sync with the python dspy implementation on this one ?"

## What Changes

- Make the active JSON-capable signature adapter own a complete signature-output wire contract: an outer JSON object keyed by adapter-managed output field names, with typed field schemas nested below those keys.
- Change JSONAdapter prompt fallback rendering to state that complete contract and provide a minimal envelope-shaped example; remove the generic, per-field typed-schema hint that can contradict it.
- Extend the adapter-aware LM request path to carry the adapter-composed schema and use ReqLLM object generation only for supported, non-tool-call signatures; a failed native attempt falls back once to the corrected text-prompt path.
- Preserve strict JSONAdapter parsing: all declared output keys remain required, extra top-level keys remain ignored, and bare typed payloads remain rejected.
- Keep non-native providers on the adapter-rendered fallback prompt and retain typed validation/casting after generation.
- Keep the planned BAML adapter limited to an opt-in representation of the same adapter-owned contract; it must not reintroduce a second schema author.

## Capabilities

### New Capabilities
- `signature-adapter-output-contract`: A single adapter-composed signature-output contract shared by fallback prompting, native structured requests for eligible signatures, and parsing.

### Modified Capabilities
- `signature-jsonadapter-parity`: JSONAdapter's JSON-only instructions and parsing contract now include consistent complete-envelope schema delivery.
- `typed-structured-outputs`: Typed-output prompt schema hints move from generic signature construction to adapter-owned complete output-contract rendering.
- `signature-adapter-message-pipeline`: Adapter-aware signature requests can carry an output contract to the LM layer and select native structured generation when supported.

## Impact

- Affected code: `lib/dspy/signature.ex`, `lib/dspy/signature/adapters/json.ex`, adapter pipeline/predictor request construction, `lib/dspy/lm.ex`, and `lib/dspy/lm/req_llm.ex`.
- Affected tests: signature prompt/adapter tests, typed-output tests, LM ReqLLM request-mapping tests, and deterministic mocked native-object-generation tests.
- No dependency, credential, model-ID, or public-signature DSL change is proposed.
- This restores parity with Python DSPy's signature-output envelope behavior. The single composed contract and ReqLLM object-generation normalization are deliberate Elixir designs, verified by local tests rather than claimed as Python implementation parity.
