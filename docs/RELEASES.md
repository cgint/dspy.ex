# Releases (what each tag contains)

This repo ships in **small, user-usable slices**.

- `main` moves quickly.
- For stability, depend on a **semver tag**.
- Note: this file lives on `main`; older tags may not include it.

## Tags

The table below is maintained on `main`, but links are **tag-pinned** so they don’t drift.

| Tag | What you get | Evidence (tag-pinned) |
|---|---|---|
| `v0.1.2` | Quieter + more deterministic developer experience on top of `v0.1.1`: don’t start `:os_mon` by default (avoids alarm/log noise in library/test usage); when optional services are enabled, attempt to start `:os_mon` with an explicit warning on failure; make `BootstrapFewShot` determinism test fail loudly if prompt format changes | Optional services startup gate: https://github.com/cgint/dspy.ex/blob/v0.1.2/lib/dspy/application.ex  \
BootstrapFewShot determinism test: https://github.com/cgint/dspy.ex/blob/v0.1.2/test/teleprompt/bootstrap_few_shot_determinism_test.exs |
| `v0.1.1` | Adds additional adoption slices and hygiene on top of `v0.1.0`: contracts-style PDF→JSON→Q&A acceptance workflow, image transcription workflow, quieter library-first startup (optional web/godmode services gated), BootstrapFewShot sampling made explicit + determinism regression test, and Bumblebee local-inference notes | Overview: https://github.com/cgint/dspy.ex/blob/v0.1.1/docs/OVERVIEW.md  \
Acceptance tests: https://github.com/cgint/dspy.ex/tree/v0.1.1/test/acceptance  \
Optional services gate (library-first startup): https://github.com/cgint/dspy.ex/blob/v0.1.1/lib/dspy/application.ex  \
Bumblebee note: https://github.com/cgint/dspy.ex/blob/v0.1.1/docs/BUMBLEBEE.md |
| `v0.1.0` | First public, pin-worthy slice: `Predict` + signatures (module + arrow-string), JSON fenced output parsing + coercion, `one_of` constraints, tools (ReAct + callbacks), attachments request parts + ReqLLM multipart/safety (tested with mocks; no real network calls in CI), and quiet teleprompter logging via Logger | Overview: https://github.com/cgint/dspy.ex/blob/v0.1.0/docs/OVERVIEW.md  \
Acceptance tests: https://github.com/cgint/dspy.ex/tree/v0.1.0/test/acceptance  \
ReqLLM multipart/attachments safety: https://github.com/cgint/dspy.ex/blob/v0.1.0/test/lm/req_llm_multimodal_test.exs |
