# Reference: Python DSPy Intro Examples → Elixir Acceptance Specs

## Diagram
![Reference examples to tests](./diagrams/dspy_intro_to_tests.svg)

## Summary
A local checkout of `dspy-intro/src` (path varies) contains important, real-world **Python DSPy usage examples** that we will treat as a *behavior reference suite*.

We will use these scripts to:
- decide what needs to work **early** (adoption-first)
- derive **deterministic ExUnit tests** that mimic the workflows (using a mock LM)
- prevent regressions and keep maintenance **hassle-free** as the codebase grows

## User request (verbatim)
> `dspy-intro/src` contains some sample/learning usage of python dspy that I deem important - pls also not that down so we might use this for rahter important opportunities that should work rather soon on the way - pls make tests that mimic such behaviour so that we also build up a proper set of tests (aka specification) for professional and hasstle free maintainance on the go - i plan to also put you in charge of organising issue-handling and maintainance later on and i would like to learn from your outcome as well - so pls put the quality bar high but smart - seek for best practices from the stack through web-search and asks.sh - reflect on the best-practices regularly as we need to produce well maintainable logic as code and in tests

## What’s inside `dspy-intro/src` (high-level)
- `simplest/` — minimal Predict usage, JSONAdapter structured outputs, tools/callback logging, Refine loop, RLM demo, multimodal attachments/images.
- `classifier_credentials/` — simple classifier module with constrained output (`Literal["safe", "unsafe"]`).
- `knowledge_graph/` — structured JSON outputs, chunking, reuse of extracted context, and optimization/evaluation flows.
- `text_component_extract/` — structured extraction + labeled few-shot training loops.

## Acceptance-test candidates (initial)
These are the *high-leverage* scripts to turn into tests first.

### R0 (Adoption Baseline) candidates
1. `simplest/simplest_dspy.py`
   - **Behavior:** string signatures, Predict, number parsing (`int` → numeric)
   - **Elixir target:** `Dspy.Predict` with string signature + `Dspy.Signature.parse_outputs/2` numeric coercion

2. `simplest/simplest_dspy_with_signature_onefile.py`
   - **Behavior:** signature class + structured output + `JSONAdapter`
   - **Elixir target:** stable prompt format + robust JSON-object output parsing for required fields

3. `classifier_credentials/dspy_agent_classifier_credentials_passwords.py`
   - **Behavior:** constrained outputs (safe/unsafe)
   - **Elixir target:** output parsing should be resilient and validation-friendly (likely still `:string` with higher-level validation later)

### Later (post-R0) candidates
- `simplest/simplest_tool_logging.py` (callbacks/tool interception)
- `simplest/simplest_dspy_refine.py` (Refine loop)
- `text_component_extract/*` (LabeledFewShot-like loops)
- `knowledge_graph/*` (JSON structured outputs + evaluation + optimization)
- multimodal (`simplest_dspy_with_attachments.py`, `simplest_dspy_with_transcription.py`)

## How we will turn examples into Elixir tests (approach)
- Use **deterministic MockLM** implementations (no network, no API keys).
- Prefer **behavior-level assertions**:
  - prompt construction contains the right sections/labels
  - output parsing accepts both label-style and JSON-object style outputs
  - module contracts (`forward/2`, `parameters/1`, `update_parameters/2`) behave predictably
- For prompts, consider **snapshot-style tests** for long strings, but keep them non-brittle via canonicalization.

## Proposed test matrix (to be implemented after approval)
| Python example | What it proves | Target milestone | Proposed Elixir test |
|---|---|---:|---|
| `simplest_dspy.py` | string signature, numeric parsing | R0 | `test/acceptance/simplest_predict_test.exs` |
| `simplest_dspy_with_signature_onefile.py` | JSONAdapter-like structured outputs | R0 | `test/acceptance/json_outputs_acceptance_test.exs` |
| `classifier_credentials_passwords.py` | constrained output strings | R0 | `test/acceptance/classifier_acceptance_test.exs` |
| `extract_prompt_parts_101_guide.py` | LabeledFewShot + structured extraction | R2/R3 | `test/acceptance/labeled_few_shot_acceptance_test.exs` |

## Notes / next steps
- This doc is a planning artifact; implementation will happen via an OpenSpec change dedicated to “Acceptance tests from dspy-intro examples”.
- We should keep a short list of “must not break” workflows and grow it over time.
