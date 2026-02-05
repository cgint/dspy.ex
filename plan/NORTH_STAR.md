# NORTH_STAR.md — Why we’re building this, and how we will prioritize

## Summary
We are building an open-source, Elixir-native DSPy port that lets people combine:
- the **DSPy way** of composing and optimizing LM programs
- with the **BEAM/Elixir stack** (concurrency, fault tolerance, OTP ergonomics)

The north star is **adoption + reliability**: users should be able to pick up this library and get value early, without waiting for “complete parity”.

## User direction (verbatim)
(first, about organizing persistent docs)

> first i would like to sharpen the north star so you can orientate without the need for me to micromanage you
> and i would also find it beneficial if the different types of persisting documentation is done in different directories.
> The current docs I see more as classic docs although there is some mix in there already. what i would like you to do it organise the plan in one directory as it should not be classic docs but kind of an agile roadmap, rough plan with step by step milestones that make sense splitting the whole endeavour into manageble 'release-milestones' probably. and then i want you to organise your self . maybe a SOUL.md, information that is crucial to memorize and to always look at when starting new work, compacting the context-window and so on - the last thing should reflect the YOU - so your personality and your learnings independent from the current work. and an entry point where it is easy to know how this was organised by you - maybe an AGENTS.md in the project root describing that idea and pointing to the most relevant files that need to be considered before continuing work on that repo.

(and second, about interfaces, open source, and priorities)

> regaring north star and milestones on the way. i would like to build up the repository very closely matching interfaces like the ones from python dspy but also from ../DSPex-snakepit where it makes sense to allow people to feel at home when they start adopting this dspy-port we are working on. so most important - we are doing this to open source the result to allow us and everyone else to combine the power of DSPy with the power of the BEAM, Elixir Stack. The steps should be in a way so that parts of the system that are often used can be used in a reliable and stable way instead of heading to feature completion - all the usage possibilities have to be testes thoroughly - there is no need to do all the implementation without having brought any benefit to the community - so it will be important to agree on which parts of the system we address first and which parts e.g. more special use cases we address later - e.g. using the current feature set with JSONAdapter is in my view very important and also allowing to use more llm-providers - we need to make adoption easy for people - pls also not down those ideas i gave you in verbatim pls

## What success looks like (practical)
- A Python DSPy user can read the README/examples and feel “at home”.
- Common workflows are stable and well-tested:
  - define a signature
  - run `Predict` / `ChainOfThought`
  - parse outputs reliably (including JSON-style outputs)
  - evaluate on a dataset deterministically
  - improve a program via at least one teleprompter
- Adding providers is easy (through `req_llm`) without the core owning provider quirks.

## Product principles (priority order)
1. **Interface familiarity**
   - Prefer names and shapes similar to upstream Python DSPy.
   - Where useful for Elixir adoption, align with patterns from `../DSPex-snakepit`.

2. **Stable slices over full breadth**
   - We ship in release milestones where each milestone is something users can depend on.

3. **Thorough testing as a feature**
   - Every advertised capability should have deterministic tests.

4. **Keep core small; integrations optional**
   - Core is `:dspy` library.
   - Optional layers (Jido runner, UI) are separate.

## Early-adoption priorities
- Use real reference workflows as acceptance specs:
  - `/Users/cgint/dev/dspy-intro/src` (see `plan/REFERENCE_DSPY_INTRO.md`)
- Output parsing that works in practice for real models:
  - label-based parsing
  - JSON object outputs ("JSONAdapter"-style behavior)
- More LLM providers via `req_llm` with a clean adapter and clear configuration.
