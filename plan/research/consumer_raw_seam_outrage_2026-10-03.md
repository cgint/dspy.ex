# Consumer finding: OptimusTower/overview-app raw seam is a category error — and half of it is our gap

Date: 2026-10-03. Source: read of herdr pane wE:p2S (qwen worker session in
`~/dev-private/OptimusTower/overview-app`), cross-checked against this repo.

## What the consumer does (verified in their tree)

`overview-app`'s `do_real_lm_request` (`lib/overview/pipeline_engine/stages/schema.ex:626`)
calls the real LM through a **raw seam**:

- hand-built `messages` map (text part + per-page PNG `image_url` parts)
- `Dspy.LM.generate(lm, request)` with `response_format: {"type" => "json_object"}`
- hand-rolled parse: strip fence → JSON-decode → JSV-validate vs `AnswerContractSchema`
- `Dspy.Signature` used only as prompt template (`to_prompt/1`) + schema home
- `Dspy.Predict` not used ("Ruling B")

Their `ExtractPDFInfo` signature keeps the **Python field names verbatim**
(`pdf_document`, `page_details_list`) but both are phantom: no value is ever
supplied through them. Python (`ingest-pipeline/processor_schema.py`) passes
real values: `pdf_document=dspy.Image.from_file(...)`, `page_details_list=<typed list>`.
The Elixir port downgraded `dspy.Image` → `:string` and routes data around the
signature. One worker summary: "a raw-HTTP call with a DSPy coat of paint."

Also found: their moduledoc (`stages/schema.ex:~204`) mis-describes what
`to_prompt/1` renders (claims no literal `[input]` placeholders;
`input_section/1` does emit them).

## Responsibility split

**Theirs (fair blame):** fossilized signature as prompt scaffolding, type
downgrade, lying moduledoc. Deliberate "byte-identical prompt parity" choice
that made the seam dishonest in shape.

**Ours (mirror): dspy.ex gaps that *enabled* the raw seam.**

Verified in this repo (2026-10-03):

- No `:image` / `dspy.Image`-equivalent input-field type anywhere in `lib/`
  (Python has `dspy.Image` as an InputField type).
- `Dspy.Attachments` (lib/dspy/attachments.ex) supports **files only**
  (`input_file` parts); no `image_url` / base64 image part type.
- The first-class path (`Dspy.Predict.forward/2` + attachments +
  `<attachments>` prompt marker, commit c25acd3, 2026-02-08) **predates their
  v0.4.1 pin** — so "Predict was unavailable" is not why they went raw.
- The real block (per their pane, Unverified — their U-A probe notes are in
  their repo, not mine): qwen can't ingest document uploads, and their
  per-page-PNG deviation needs image parts that dspy.ex does not model.

So the "not using dspy.ex properly" is only half their fault: the deviation
they *need* (per-page images + inlined markdown as first-class inputs) has no
first-class shape in dspy.ex today. The raw seam is a workaround for our
missing capability, plus their fossil-signature discipline on top.

## Candidate follow-ups (not yet queued)

1. `Dspy.Attachments` image parts: `image_url` / data:-base64 item types
   (parity with what their raw request hand-builds).
2. An `:image` input-field type (Python `dspy.Image` parity) so a signature
   can carry real image data and `Dspy.Predict` can fill it.
3. Consider whether (1)+(2) unblock the consumer's U-A migration to first-class
   `Dspy.Predict` — that would make their "first-class Predict migration"
   possible and kill the raw seam.

Never break `test/consumer_contract/`; any of the above must stay
consumer-contract-safe.

## Outcome (2026-10-03, implemented and verified)

(2) landed as `Dspy.Image` + an `:image` input-field escape hatch; (1) is
unchanged (attachments stay file-only).

**Wire format (decided after real-backend failure):** image values are
spliced into the user message content as `image_url` parts **at the field
position**, in field-declaration then list order. The prompt text carries no
marker tokens and no base64. Rendering emits an internal sentinel
(`AdapterPipeline.image_ref_token/0`, printable `<<DSPY-IMAGE-REF>>`); the
single merge point `AdapterPipeline.merge_media/3` (called by the adapter
pipeline runner before every LM call) splits the text at sentinels and
interleaves the parts. Content without sentinels (hand-built `messages:`
overrides — the raw seam) falls back to append-at-end, so the raw seam keeps
working during migration. This matches upstream Python DSPy's final wire
shape (its `<<CUSTOM-TYPE-...>>` identifiers are spliced into parts before
send; the client never manages markers).

**Why no `<image>` markers in the text:** the consumer's real backend
(sglang serving Qwen-VL via litellm, `http://pluto:40115/v1`) 500s with
`Mismatch: More 'IMAGE' tokens found than corresponding data provided` when
the prompt text contains literal image tokens — its chat template already
injects per-image placeholders. Verified by direct curl: marker payload 500s,
marker-free payload works. Literal markers are therefore unsafe as a general
default, not just for this backend.

**Not handled by req_llm (checked 2026-10-03):** `param_transform.ex` only
rewrites top-level request options; `image_url` references in req_llm are
telemetry counters. Messages content is passed through verbatim — the
adapter-pipeline splice stays in dspy.ex.

**Verified (final, 2026-10-03):**
- full suite green (949 passed after the raw-bytes `ArgumentError` fix in
  `plain_url?/1`); `Dspy.Image` + `merge_media` + pipeline suites included;
- offline playground: `mix run examples/playground/image_input_offline.exs`;
- real e2e, multi-image shape (list `:image` field, one forward):
  `mix run examples/playground/image_input_real_multimage.exs` — three
  solid-color pages (red/blue/green) → `[red, blue, green]` in order against
  `qwen3.8-27b-nvfp4-dflash2-direct` (SGLang via litellm);
- real e2e, per-page shape (one forward per page, order by the app loop):
  `mix run examples/playground/image_input_real_per_page.exs` — ALL PASS
  against the 35b llama.cpp judge.

**Judge saga — resolved (peer diagnosis, pane w2J:p2):** the judge's vision
works; its multi-image loss is a **llama.cpp build defect, not dspy.ex**.
Build v9653 (commit 9dbc6621a) predates upstream PR #27348, which fixes
issue #27313 ("llama-server silently drops the second of two adjacent images
with identical dimensions" — Qwen temporal-merge of same-size bitmaps, zero
diagnostics; server log shows the middle image never gets a `process_mtmd`
line). Consequence: on this judge, adjacent same-dimension images → N−1
embedded. Fix = upgrade the judge's llama-server to a build ≥ the #27348
fix (≥ b10481); until then use the per-page shape (which is also the
consumer's natural shape). llama.cpp wire-format notes: `image_url.url` must
be a `data:...;base64` URI (raw base64 or container-external file paths →
"Invalid url value").

**Scope decision (user, 2026-10-03):** acceptance bar = dspy.ex properly
supports **one image per forward**. Both real-model e2e shapes above pass;
multi-image-on-judge is tracked as a backend upgrade, not a dspy.ex gap.

**Open:** consumer-side migration (replace `do_real_lm_request` with
`Dspy.Predict.forward` + `:image` fields) is now possible but not started;

