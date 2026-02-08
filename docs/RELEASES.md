# Releases (what each tag contains)

This repo ships in **small, user-usable slices**.

- `main` moves quickly.
- For stability, depend on a **semver tag**.
- Note: this file lives on `main`; older tags may not include it.

## Tags

The table below is maintained on `main`, but links are **tag-pinned** so they don’t drift.

| Tag | Commit | What you get | Evidence (tag-pinned) |
|---|---|---|---|
| `v0.1.0` | `1bdb0e38` | First public, pin-worthy slice: `Predict` + signatures (module + arrow-string), JSON fenced output parsing + coercion, `one_of` constraints, tools (ReAct + callbacks), attachments request parts + ReqLLM multipart/safety (tested with mocks; no real network calls in CI), and quiet teleprompter logging via Logger | Overview: https://github.com/cgint/dspy.ex/blob/v0.1.0/docs/OVERVIEW.md  \
Acceptance tests: https://github.com/cgint/dspy.ex/tree/v0.1.0/test/acceptance  \
ReqLLM multipart/attachments safety: https://github.com/cgint/dspy.ex/blob/v0.1.0/test/lm/req_llm_multimodal_test.exs |
