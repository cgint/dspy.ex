# Releases (what each tag contains)

This repo ships in **small, user-usable slices**.

- `main` moves quickly.
- For stability, depend on a **semver tag**.
- Note: this file lives on `main`; older tags may not include it.

## Consumer notes

### Zoi compatibility

Fresh installs require Zoi `>= 0.14.0 and < 0.20.0` while dspy.ex uses
LLMDB 2026.5.2 through ReqLLM. Zoi 0.20 rejects duplicate provider keys
during LLMDB startup. Applications that require Zoi 0.20 or newer will
see a dependency resolution conflict. Existing compatible locks can
keep their selected Zoi version.

### Corpus embedding retrieval

`Dspy.Embeddings.new/3` embeds a text corpus once. `query/2` returns
matching passages and their zero-based indices in a prediction.
`query_with_scores/2` also returns aligned similarity scores. Ranking is
exact, with earlier corpus positions first on ties. Vectors are normalized
by default. Pass `normalize: false` for raw dot products.

`Dspy.Embeddings.save/2` writes a versioned JSON checkpoint for the
corpus index. `from_saved/2` accepts a caller-supplied embedder and
restores the stored vectors, settings, and corpus order.

### Named submodules

`Dspy.Module.named_sub_modules/1` lists a program and its nested modules in
breadth-first order. Paths begin at `self` and identify each occurrence,
including equal module values stored at different paths.

### BetterTogether optimizer

`Dspy.Teleprompt.BetterTogether` composes named prompt and weight optimizers
in a strategy such as `"p -> w -> p"`. Each stage receives the previous
stage's program. The optimizer returns the best held-out candidate, or the
latest completed program when validation is disabled. Use
`compile_with_candidates/4` to inspect stage scores and a stopped stage.

### BootstrapFinetune optimizer

`Dspy.Teleprompt.BootstrapFinetune` prepares Chat training conversations
from successful teacher traces. It groups training jobs by the student's
bound LM in multitask mode or by predictor slot in separate mode. Each
multitask job receives all compatible teacher traces. A caller-supplied
LM implements `finetune/3` and returns the trained LM. The optimizer runs
the jobs in order and binds the returned LMs after all jobs succeed.
The built-in Chat formatter accepts text conversations and checks that
the assistant target parses back to the recorded outputs.

### Typed bounding boxes

Use `Dspy.BoundingBox` as a JSON signature schema for a rectangular image
region. Its edges are normalized to `[0, 1]`, and validation requires
positive width and height. Chat, JSON, and XML predictor tests cover
prompt rendering and typed outputs.

### InferRules optimizer

`Dspy.Teleprompt.InferRules` bootstraps one program, induces natural-language
rules for each predictor, and picks the candidate with the highest validation
score. Pass `rules_lm:` to bind the induction model, or let it use the LM in
the current teacher settings. With no `valset:`, the optimizer uses the first
half of the trainset for induction and the rest for validation, in order.
A recognized context-limit error retries with one fewer training row.

### Per-query nearest-neighbor demos

`Dspy.Teleprompt.new(:knn_few_shot, k: k, vectorizer: embedder)` builds an
index when compiled with a student and training set. Each call uses its
own neighbor subset to prepare one student program. Bootstrap metrics
receive the original training example and the teacher's prediction.
The labeled-demo cap takes the closest rows, including structured labels.
For an `Example` query, declare its inputs with `Dspy.Example.with_inputs/2`.
The [offline KNNFewShot example](../examples/offline/knn_few_shot_offline.exs)
verifies that two queries use different demonstrations from one index.

### K-nearest-neighbor lookup

`Dspy.KNN.new/3` indexes the declared inputs of training examples through
`Dspy.Embedder`. `Dspy.KNN.query/2` embeds a map or keyword list and
returns the original examples ranked by dot product. Training and query
field names share a lexical order. Equal scores favor the later training
row. Scoring uses Elixir's native numeric representation.

### ColBERTv2 server search

`Dspy.Retrieve.colbert/1` accepts a ColBERTv2 server URL. Pass the
configured value to `Dspy.Retrieve.ColBERTv2.search/3` for ranked results
and server metadata. GET is the default and supports up to 100 results.
Set `post_requests: true` for JSON POST or `simplify: true` on the
search for passage strings.

### Retrieval modules

`Dspy.Retrieve.new/1` creates a module that returns a prediction
with ordered passages. Bind a ColBERTv2 client, a retriever module,
or a function with `rm:`. An unbound module uses the scoped or
global `rm` setting. Pass `k` with the query to override the default.

### Trace-aware bootstrap metrics

BootstrapRS, BootstrapFewShot, and KNNFewShot accept an arity-three metric
that receives the training example, the teacher prediction, and the ordered
predictor steps from that attempt. Each step contains a typed slot path,
the predictor inputs, and its prediction. A teacher without steps supplies
`[]`. `Dspy.Evaluate` passes `nil` as the third argument, so the same
metric can score validation candidates. KNNFewShot passes the exact indexed
neighbor and runs the configured student once per query.

### Batch bootstrap trace collection

`Dspy.Teleprompt.bootstrap_trace_data/3` runs a program over examples with
declared inputs and returns their predictions and predictor traces. An optional
metric scores each attempt in its worker. Skipping failed rows preserves
the original zero-based indices for batch scoring and reflection.

Set `capture_failed_parses: true` to retain a row that ends in a predictor
parse failure. Its trace includes the successful steps and the exact slot
and inputs of the failed call. The failure record contains the raw completion
text. When a metric is supplied, `format_failure_score:` scores that row
without invoking the metric. Its default is `-1`.

### Reflective GEPA instruction search

`Dspy.Teleprompt.GEPA` accepts a reflection LM and a rollout budget. A
five-argument metric can give feedback about a predictor step. Reflection
proposes an instruction for that slot, and the optimizer keeps candidates
that improve the validation score. The [offline example](../examples/offline/gepa_reflection_offline.exs)
improves from 0% to 100% on a held-out addition question.

Set `candidate_selection_strategy: :pareto` to compare a proposed
instruction with its parent on the same training minibatch before
validation. Parent sampling uses per-example validation leaders, so a
specialist can remain eligible with a lower mean. Failed rows retain
their positions and use the configured `:failure_score`.

With Pareto selection, `frontier_type: :objective` lets the metric
return named `objective_scores` alongside its primary `score`. For each
objective, GEPA averages only the validation rows that report a value.
Every admitted candidate needs at least one objective across its full
validation set. The means determine eligibility for parent sampling and
merging. The primary score still governs minibatch acceptance, merge
acceptance, and the final winner. The default `:instance` uses per-example
leaders.

`frontier_type: :hybrid` combines scalar row leaders and named objective
mean leaders. `frontier_type: :cartesian` tracks each reported validation
row and objective pair separately. Both modes use the existing validation
calls and scalar acceptance rules. An absent objective creates no pair.

With Pareto selection, `use_merge: true` combines compatible instructions
from candidates with a common ancestor. A merge must match or beat both
parents on the same validation subset. Its subset scores count toward
the full validation result and each row is charged once.

Set `add_format_failure_as_feedback: true` to include terminal parse
failures in GEPA's reflection. The configured reflection LM receives a
bounded excerpt of the failed completion, which may contain sensitive
text, and format guidance for that predictor. The failed row uses
`:failure_score` without calling the metric.

Pass an arity-three `instruction_proposer:` callback to supply GEPA
instruction updates in Elixir. It receives all current instructions,
bounded reflective observations, and the selected slots, keyed by exact
typed paths. Return new instructions for selected slots or an empty map
to skip the proposal. A supplied reflection LM is scoped to the callback.
Callers can also use the callback by itself.

Set `component_selector: :all` to propose changes for all slots with
observations in the same training minibatch. GEPA batches their instruction
updates into one candidate and scores it within the existing rollout budget.
The default `:round_robin` selects one slot at a time.

Pass a unary `component_selector:` callback to choose observed slots from
the current training minibatch. It receives the parent ID, current
instructions keyed by typed slot path, eligible paths in seeded order,
and bounded declared-field observations with row indices and scores.
Return the selected paths in proposal order, or `[]` to skip the round.
The snapshot uses the existing rollout results.

`Dspy.Teleprompt.GEPA.InstructionProposer.new/1` configures GEPA's
LM-driven proposer. Set a base prompt, additional instructions, a signature
adapter, or reference skills. Skill strings are inline text. An explicit
`{:path, path}` loads a file or a directory's `SKILL.md` at construction.
With `max_chars:`, an oversized draft gets one correction call before
GEPA evaluates the instruction. The limit counts Unicode code points
after trimming. Reflective examples use the existing bounded text previews.

Set `include_observation_images: true` on the configured proposer to
send declared images from the selected training observations. Numbered
references in the text preview point to the images in wire order.
Each proposal transfers up to eight image parts and eight MiB of image
URL text, including data URIs. The default keeps the text preview.

Set `include_observation_history: true` on the configured proposer to
include declared training histories as structured report data. Setting
`truncate_history_outputs: true` includes those histories and shortens
each long tool result to 500 Unicode code points plus a cut marker.
Call IDs, names, arguments, and error status stay associated with the
same turn. History counts toward the existing 16 KiB report budget.
Typed media within history appears as a placeholder. The original
history and rollout prompts stay intact.

### Multipart image requests

Custom adapters can place image markers in several text parts of one
user message. Each marker now consumes the next image once. Existing
parts retain their order and supplied file attachments follow the
message content. When marker and image counts differ, the adapter
pipeline removes the markers and appends the supplied images once.

### Streaming progress messages

Pass a `status_message_provider:` module to `Dspy.streamify/2` to turn
module and LM lifecycle events into `Dspy.StatusMessage` values. A
provider implements `Dspy.StatusMessageProvider` and receives event
names and allowlisted call metadata. Field chunks, progress messages,
and the final prediction share one demand-driven enumeration.
The [offline ChainOfThought example](../examples/offline/chain_of_thought_streaming_offline.exs)
shows progress beside answer chunks and verifies cleanup after an early halt.

Providers can implement optional `tool_message/2` for tool start and end
events. Pass `Dspy.StatusMessageProvider.ToolProgress` as the status
provider for generic tool messages. Tool events carry the same bounded
metadata as the other progress events.
Use `stream_listeners: :none` to receive progress and the final prediction
through ordinary inference, including for batch-only models and structured
tool requests.

The direct tool task now stops when its caller exits, including when the
tool function traps exit signals. This also applies when an active tool
loses its program stream consumer.

### Chat field listeners

Pass `stream_listeners: [:answer]` to `Dspy.streamify/2` to receive selected
plain string outputs from a standalone ChatAdapter predictor. Each
`Dspy.StreamResponse` names the predictor and field and carries a text chunk
and an end-of-field flag. The ordinary prediction still ends a successful
stream. A JSON fallback can produce a prediction with no field events.
Take a field chunk and halt the enumerable to cancel the provider request.

### Lazy program streams

`Dspy.streamify/2` wraps a standalone Predict or ChainOfThought in an input
function that returns an enumerable. Each enumeration uses the consumer's
DSPy context and yields `{:delta, text}` events followed by a prediction
or terminal error. Halting the enumeration or stopping its consumer cancels
the ReqLLM HTTP request. Resume a suspended enumeration in its original
process. Streaming makes one DSPy generation attempt and uses the ordinary
adapter to parse the final prediction. Field listeners and status events
remain in M5.

### Composite program streaming

`Dspy.streamify/2` can select Chat text fields from predictors in a
composite. Pass a unique output atom or `{predict_name, field}` using
the name from `Dspy.Module.named_predictors/1`. Selected calls emit
their own field chunks, and unselected calls retain ordinary inference.
An empty selection streams raw deltas. While a stream scope is active,
invoking a selected predictor outside the program worker returns
`{:error, :stream_predictor_outside_owner}`.

### LM streaming transport

`Dspy.LM.stream_generate/3` delivers ReqLLM text deltas to a callback in the
calling process and returns the normalized LM response, including usage.
The callback can halt the stream. A separate provider owner closes the HTTP
connection if the caller exits. A synchronous ReqLLM request hook can delay
cleanup of its provider process until the hook returns. The transport
bypasses response caches and DSPy retries. The loopback suite verifies the
OpenAI Responses route.
Program streaming, field listeners, and status events remain in M5.

### Scoped diagnostic history

`Dspy.capture_history/2` returns the call result and a bounded LM history
snapshot. Successful calls from DSPy workers and cache hits appear even
with usage tracking disabled. Nested scopes have independent limits and
each snapshot reports how many records were evicted. Pass
`include_payloads: true` to retain bounded rendered prompt and completion
text for `Dspy.inspect_history/2`. Structured tool data and non-text
attachments use placeholders. Values rendered as ordinary text can appear
in the excerpts. The VM-wide history keeps its existing metadata format.

### Opt-in lifecycle telemetry

Set `telemetry: true` globally or with `Dspy.context/2` to emit
`[:dspy, boundary, phase]` events for modules, LMs, adapters, tools, and
evaluations. Callbacks and telemetry share call IDs across observed
boundaries. Events carry native durations and selected numeric counts.
Metadata excludes prompts, results, credentials, and failure text.
The direct `:telemetry` dependency uses the existing 1.4.2 lock.

### Opt-in Refine feedback

`Dspy.Refine.new/2` accepts `feedback_lm:`. A scored attempt below the
threshold can send a bounded report of declared fields to that LM when
another attempt remains. Declared text may be sensitive. The report uses
placeholders for images, attachments and tool data. The advisor has five
seconds to respond. Valid advice applies to the addressed predictor slots
for the next attempt, including their output retries. Advisor failures
leave the program's failure allowance available. The offline example
covers both Refine feedback and structured ReAct.

### Opt-in structured ReAct

`Dspy.ReAct.new/3` accepts `mode: :structured` with ChatAdapter and supported
OpenAI models through ReqLLM. It retains provider call IDs, assigns stable IDs
to text tool calls, and returns replayable typed history with the final
prediction. The `submit` tool validates the signature outputs. A forced final
request selects `submit` exclusively. Optional outputs can use JSON null on
the OpenAI strict tools wire. Complex submit schemas use non-strict
provider declarations and retain local validation. Failed final
submissions include the history in the error tuple. The default mode still
returns a text trajectory.

### Typed conversation replay

`Dspy.History.Turn` stores declared input and output fields and completed tool
exchanges. ChatAdapter and XMLAdapter use their live field formatters to
replay user image and attachment parts. Assistant tool calls and their tool
results share their original IDs. Tool-only turns can omit user inputs.
Assistant media fields and replayed demo images use text placeholders. The
offline structured-agent example replays a completed tool call and its
source image through both adapters and verifies a typed output retry on each.

The internal structured tool response path retains provider call IDs from
tool-only responses and parses JSON tool calls in ChatAdapter marker sections.
Ordinary predictor tool outputs still expose `name` and `args`.

### Opt-in XML field adapter

Select `Dspy.Signature.Adapters.XMLAdapter` on a predictor to format field
tags and parse literal text, typed scalars, and JSON-valued fields. Optional
fields support defaults and self-closing nulls. Output retries request XML
tags and preserve multipart images and trailing text. Schema-backed output
records, lists, and dictionaries support nested XML in responses and demos.
Lists use `<item>` and dictionary keys that need escaping use `<entry key="...">`.
Declared lists also accept repeated field tags in encounter order, including
repeated dictionary keys. Use a single wrapper, a JSON array, or repeated
item tags per list field. Put literal strings such as `[draft]`, the empty
string, and `null` on nullable lists inside explicit `<item>` tags.
Nested scalar `enum` and `const` leaves support numeric and boolean literals.
An exact string member takes precedence over a numeric or boolean spelling.
Demos use JSON when literal XML would change the type of a constrained value.
Discriminated record branches with distinct string tags support native XML
responses and demos. The discriminator can appear anywhere in the record.
Discriminated XML rejects inputs that match multiple branch grammars. Demos
with literal closing tags use JSON to preserve their contents.
Record-only `oneOf` and `anyOf` schemas also accept native XML without a
discriminator. Branch constraints and shared constraints participate in
validation. Distinct valid interpretations return an ambiguity error. Use
explicit JSON inside the field tag to choose a value type. Demos for these
unions carry JSON inside the tags.

Unions of strings and records accept literal text and native XML records.
A child tag immediately after the field opener selects the record syntax.
With a framing newline, a child opening tag on its own line selects the
record syntax. A compact line of markup in a multiline field is literal
text. Complete JSON at a valid field boundary selects the type and
preserves these values in demonstrations and history. A JSON object opener
with a quoted key commits to JSON decoding. Bare `null` selects nil when
the union admits it. JSON also supports schemas that rely on
`patternProperties`.

### Refine failure allowance

`Dspy.Refine.new/2` accepts `fail_count:` to bound failed attempts per call.
Program errors, program exceptions, and invalid rewards count toward the
allowance. Exceeding it returns `{:error, {:refine_failed, details}}`, with
the failure count, attempts used, and last error. An omitted or `nil` value
uses the existing attempt limit and exception behavior.

### ReqLLM tool history

The ReqLLM bridge preserves assistant function calls and tool-role results
in request history, including their call IDs. Text-generation responses
carry native function calls for the application to execute. Malformed tool
messages return a local error.

During text generation, set `:tool_choice` on an LM request to select a
declared function for that call. An omitted or `nil` value uses the ReqLLM
client's default options.

### Parallel call concurrency

Pass `num_threads:` to `Dspy.Parallel.run/3` to set concurrency for that
call. An omitted or `nil` value uses the executor's configured count.

### Comparing parsed completions

`Dspy.MultiChainComparison` accepts the ordered collection from
`Dspy.Prediction.parsed_completions/1` as its `:completions` input, alongside
lists of completion maps and predictions.

### Multipart output retries

Output retries update the primary text of the final user message. Images,
trailing text, and other message parts keep their content and order.

### Nested predictor traces

A predictor step can now reach both an inner capture and an enclosing
optimizer capture. Each capture uses its own predictor path. If a detached
worker finishes after an inner capture closes, the enclosing capture can
still record the step while it is open.

### Refine rollouts

`Dspy.Refine` gives each attempt a distinct rollout ID. It sets temperature
`1.0` on named predictors and passes `1.0` as a scoped default to custom
modules. LM response caching partitions attempts by rollout ID. Reward
scoring uses the caller's settings.

### DSPy logging controls

`Dspy.disable_logging/0` silences DSPy diagnostics across the VM.
`Dspy.enable_logging/0` restores them under the host's Logger configuration.
Both calls can be repeated safely. Host logs and DSPy lifecycle callbacks
continue to run while DSPy diagnostics are silenced.

### Tool lifecycle callbacks

`Dspy.Tools.LifecycleCallback` observes direct tool execution and both ReAct
paths through Settings and per-call callback registrations. End events report
timeouts and other failures after the tool task settles. Nested LM calls link
back to the tool call ID. These events contain lifecycle metadata without tool
arguments, results, or failure text.

Legacy ReAct observers keep their callback arities and event data. Catchable
interruptions from those observers are isolated from the tool result.

### Adapter callback completion

Adapter format, call, and parse phases emit an end event when they fail after
emitting start. New failure events report the outcome without provider or
exception details. Transport retries share one adapter call pair, and each
LM invocation retains its own pair. Adapter events include a parent call ID
when they run inside an observed call.

### Evaluation lifecycle callbacks

`Dspy.Evaluate.Callback` adds an optional start and end event around each
evaluation. Module and LM events include the parent call ID when their
enclosing call is observed. A completed evaluation reports the number of
examples and failures. If an evaluation reaches its error budget, pending
workers are stopped before the caller receives the exception and its end
event. The [offline example](../examples/offline/evaluation_callbacks_offline.exs)
traces a successful example and a failed example in the same parallel run.

### LM lifecycle callbacks

`Dspy.LM.Callback` adds optional start and end handlers for resolved LM
calls. Register handlers through Settings or the existing per-call callback
options. A provider call and a cache hit each emit one pair. An adapter
transport retry makes another LM call with its own ID. End events report
the outcome and elapsed microseconds. Prompts, responses, credentials, and
failure details stay out of the event payloads.

### Module lifecycle callbacks

Implement `Dspy.Module.Callback` and register `{handler, state}` in
`Dspy.configure/1`, `Dspy.context/2`, `Dspy.with_callbacks/2`, or a
`Dspy.call/3` call. `Predict` and `ChainOfThought` also accept callbacks on
construction. Each module invocation through `Dspy.Module.forward/2` has its
own call ID. The end handler receives elapsed microseconds and the outcome
for a return, raise, throw, or exit. Payloads omit inputs, results, and error
details. A handler's start state carries through to its matching end.

### Usage tracking after an interrupted module call

Tracked module calls now release their usage scope on a raise, throw, or
exit. Later calls can report their own usage. A caller that recovers from an
interrupted nested call retains the usage from model requests it already made.

### Numeric output parsing

`-5.e3` now keeps its sign on both numeric output types. The parser matches
DSPy for nested decimal parentheses, matching single or double quotes, and
one underscore immediately after an unwrapped radix prefix. Malformed radix
separators still produce parse errors. Radix values beyond the finite float
range return a parse error on `:number` and retain their exact `:integer` value.

### LM memory cache

Opt-in LM response caching keeps up to 10,000 entries per VM and evicts the
least recently used response. `Dspy.configure_cache(memory_max_entries: 500)`
sets a different limit and clears stored responses. Clearing, reconfiguring,
or restarting the cache discards fills from generations already in flight.

### LM disk cache

`Dspy.configure_cache(disk_cache_dir: path, disk_size_limit_bytes: bytes)` enables
disk storage for eligible LM responses. Use a directory reserved for one BEAM
writer and give the LM a `cache_namespace:` identifying its provider account.
The first supported route is stock ReqLLM `openai:gpt-4.1-mini` Responses.
The `cache:` setting still controls whether a generation uses either cache.

The disk store keeps versioned JSON responses in a private subdirectory. It
counts published response bytes and evicts the oldest records first, using the
key to break timestamp ties. Entries survive a restart or memory clear.
`Dspy.configure_cache(disk_cache_dir: nil)` disables disk access and retains
the existing files. Unsupported requests and unavailable disk storage bypass
the disk tier.

### Provider retries

Predictors retry known transient HTTP and transport failures within their
generation retry budget. Authentication and other known permanent failures
return after the first generation attempt. Opaque custom LM errors still use
the configured budget. Failures return their original reason terms.

ReqLLM structured generation uses text fallback for `:unsupported_schema`
and ReqLLM's `Invalid.Schema`, `Invalid.Capability`, and
`API.SchemaValidation` errors. Provider HTTP errors stay on the structured
route. Retry logs count generation attempts in order. ReqLLM also manages
HTTP retries inside each generation attempt, with a provider-specific budget.

### Metric function arity

Evaluation and optimizers that score programs expect metric functions with one
or two arguments. An unsupported arity raises `ArgumentError` with the supplied
arity before evaluation or optimizer workers run.

### Embedding batches

`Dspy.Embedder.new/2` accepts a hosted model or local embedding function.
`Dspy.Embedder.embed/3` returns vectors in input order and supports a per-call
batch size. A single string returns one vector. The ReqLLM embedding provider
reports malformed batch rows as structured errors.

### Shared concurrency defaults

`Dspy.configure(num_threads: count)` and `Dspy.context/2` set the default
concurrency for `Dspy.Evaluate.evaluate/4` and `Dspy.Parallel.new/1`. Explicit
options take precedence. The default `nil` uses the number of online schedulers.

### Parsed completions

`Dspy.Prediction.from_completions/1,2` accepts ordered output rows or parallel
field columns. Ordinary attributes come from the first row. Use
`Dspy.Prediction.parsed_completions/1` and `Dspy.Completions.fetch/2` to read
other rows or all values for a field. `Dspy.Prediction.completions/1` continues
to expose raw completion metadata. The constructor rejects empty or ragged
inputs and ambiguous atom and string spellings for the same field.
`Dspy.majority/2` can vote over a parsed collection or a prediction built from
one. It uses the last signature output when the caller omits `:field` and
supports numeric and boolean votes in parsed collections.

### Example fields and dictionaries

`Dspy.Example.labels/1` builds an example from the fields outside the selection
made by `with_inputs/2`. `Dspy.Example.without/2` removes one or more fields from
a copy while keeping its input selection and metadata.
`Dspy.Example.to_dict/1` projects examples, predictions, and conversation history
inside fields into plain maps. It also works inside lists and maps.

### Named predictor inspection and updates

`Dspy.Module.named_predictors/1` lists predictor values by their program slots.
It covers immediate list, tuple, and map entries as well as nested modules.
Equal predictor values in separate slots still have separate names.
`Dspy.Module.predictors/1` returns the values alone. `Dspy.Module.map_named_predictors/2`
applies a function to each predictor in discovery order and returns an updated program.
`Dspy.Module.set_lm/2` binds a language model across those slots. Use
`Dspy.Module.get_lm/1` to read their shared stored binding.
`Dspy.Module.reset_copy/1` returns a program with demos and stored LM bindings
cleared across the named predictors. `Predict.reset/1` and `ChainOfThought.reset/1`
provide the same operation for standalone predictors.

### Native program checkpoints

`Dspy.Module.save_state/3` saves predictor instructions, demos, and generation
config as native JSON v1. `Dspy.Module.load_state/3` restores them into a
caller-built program with matching typed slots and ordered signature fields.
Use `lms: %{"name" => lm}` to save and restore stored LM bindings by name.
The bindings' credentials and runtime options stay with the caller. This
format has its own portable demo types and is specific to dspy.ex.

### Predictor generation config

`Dspy.Predict` and `Dspy.ChainOfThought` accept a `config:` map or keyword list
with `:temperature`, `:max_tokens`, `:max_completion_tokens`, `:rollout_id`, or `:n`.
Use `get_config/1` to read the stored options, `update_config/2` to merge a patch
into a predictor, or `Dspy.call/3` with `config:` to override options for one call.
Nil request options inherit settings and LM defaults. An explicit nil rollout
selects the unpartitioned cache. BootstrapRS and BestOfN apply their sampling
options to temporary predictor copies for retries.

An explicit `config: [n: count]` asks a compatible LM for an ordered collection
of parsed choices from one request. This includes `n: 1`. Set `n: nil` to return
to the default single-choice path. The existing temperature precedence applies
to these requests. ReqLLM, Bumblebee, TwoStep, and tool-call signatures currently
support one choice in this path.

### Random search for few-shot demos

`Dspy.Teleprompt.new(:bootstrap_rs, metric: metric)` creates the seeded search
optimizer. Compile it with `Dspy.Teleprompt.compile/3` to get the best program.
Use `Dspy.Teleprompt.BootstrapFewShotWithRandomSearch.compile_with_candidates/4`
for ranked scores, subscores, and a separate validation set. Pass
`teacher_compiled: true` to reuse an already-compiled teacher's demos. The
winning predictors keep their bound LMs. Programs with named predictor slots
can bootstrap each slot from its own teacher calls, including calls inside
tasks. The existing `predict.examples` path continues to support custom teachers.

### Sampling after v0.4.11

Cross-validation, `Trainset`, `Ensemble`, and `BootstrapFewShot` now use explicit
CPython-compatible random state. An integer seed still gives repeatable results.
It can produce different folds, samples, or demonstrations than v0.4.11.
Random `Trainset.sample/3` now matches CPython `random.sample` for the same
population and seed. This also affects demo selection in `LabeledFewShot`,
`SIMBA`, and `MIPROv2`. These calls preserve the caller's Erlang random state.

### Adapter fixes in v0.4.11

- Transport and output retry exhaustion now log at debug level. The original
  v0.4.9 notes advertised this change, but both events still logged at info
  in that tag.
- Untyped `:json` fields now declare an open object in the native JSON schema
  so providers can return arbitrary object keys (`01e5777`). Typed schemas
  keep their existing definitions.

### v0.3.40 erratum

v0.3.40 also added adapter-owned output contracts (`9f11b3e`) and
provider-compatible native structured output through ReqLLM (`1afadc8`).

### JSV and idna security floors

dspy.ex requires JSV 0.28 or newer within the 0.x series and idna 8.x.
JSV 0.28 supports idna 8, which fixes EEF-CVE-2026-117678. It also includes
the fix for EEF-CVE-2026-117680. If your application has older versions
locked, run `mix deps.update dspy jsv idna` for a git dependency on dspy.ex.
If your app uses Swoosh and its lockfile pins a version below 1.30, include
`swoosh` in the update so it can resolve idna 8.

### ReqLLM dependency pin in v0.4.11

dspy.ex now declares the ReqLLM revision already in its own lockfile
(`66b4042`). Updating dspy.ex may move an application that resolved a
different ReqLLM revision onto this tested commit.

### M1-a evaluate output options (fix round 2, 2026-09-29)

M1-a adds the upstream `EvaluationResult` output options to
`Dspy.Evaluate.evaluate/4` (`display_table`, `save_as_csv`, `save_as_json`,
`provide_traceback`, `display_progress`, `metric_name`). Two consumer-facing
behaviours from fix round 2, both declared in `docs/COMPATIBILITY.md`:

- **Per-row collision rename (upstream parity).** A shared example/prediction
  field (e.g. `answer`) is renamed `example_<k>` / `pred_<k>` one row at a
  time (upstream `merge_dicts`, evaluate.py:310-330). After M1-a, saving CSV
  from a QA run whose examples share an `answer` field **will raise if ANY
  example failed** (the failed row keeps the plain `answer`, which is not in
  the header). This is upstream behaviour; unlike upstream we leave no
  partial file.

- **Throwing/exiting metric no longer crashes the caller.** M1-a fixes a
  v0.3.48 path where a metric that `throw`s or `exit`s crashed the caller;
  each is now recorded in its own position as `{:caught, :throw, reason}` /
  `{:caught, :exit, reason}`. A metric EXCEPTION reaching the catch-all is
  now recorded in the standard `{:exception, ...}` shape (the `{:exception, _}`
  catch-kind match was dead code — `catch` yields `:error`, not
  `:exception`).

- **Fields named `example_*`/`pred_*`/`metric` are no longer misrouted to the
  wrong side (fix round 3, BB1).** Every row pair now carries its SOURCE
  explicitly (`:example` / `:prediction` / `:metric`); the lookup is
  tag-driven, never key-name-driven. An example field called `pred_label` or
  a prediction field called `example_ref` is no longer read from the wrong
  side and saved as null.

- **String-keyed examples now collide and rename correctly with atom-keyed
  predictions (fix round 3, BB2); output keys are strings, matching
  upstream.** A string-keyed example (`%{"answer" => _}`) and an atom-keyed
  prediction (`%{answer: _}`) collide on their string form and are renamed
  `"example_answer"` / `"pred_answer"` (strings, NOT atoms — no
  `String.to_atom` on user-supplied key names). Non-colliding keys pass
  through as-is.

### Security dependency floors (SEC-1, 2026-09-28)

From the next release, `:dspy` declares direct floors on its transitive HTTP stack:
`req >= 0.6.1`, `mint >= 1.11.0`, `hpax >= 1.1.0` (advisory fixes; see `mix.exs`).
If your app already pins a vulnerable version (req 0.5.x, mint < 1.11.0, or
hpax < 1.1.0), add `:dspy` will **fail to resolve** until you update:

    mix deps.update req mint hpax finch

(If you do not depend on req/mint/hpax/finch directly, add them to your
`mix.exs` deps with the same floors, or run `mix deps.unlock --all` then
`mix deps.get`.)

This is deliberate: the vulnerable versions contain high-severity advisories
(e.g. req EEF-CVE-2026-49755 decompression bomb, mint HTTP/2 request smuggling +
EEF-CVE-2026-91043 HPACK cookie memory exhaustion, hpax EEF-CVE-2026-58226 DoS).

**Behavior change in req 0.6.0+ to be aware of:** automatic response
archive/compressed decoding (zip/tar/gz/zst/csv) was removed and automatic
decompression is off. Both are now **opt-in** (`decoders:` and
`compressed: true` respectively). `:dspy` itself never relied on either — all
LM HTTP goes through `req_llm` — but if *your* code calls `Req` directly and
expected automatic decoding/decompression, add the option explicitly.

## Tags

The table below is maintained on `main`, but links are **tag-pinned** so they don’t drift.

| Tag | What you get | Evidence (tag-pinned) |
|---|---|---|
| `v0.6.0` | **M3a provider hardening.** Predictors distinguish transient and permanent provider failures while preserving error tuples. The opt-in LM cache offers bounded memory and disk storage. Disk support starts with stock ReqLLM OpenAI `gpt-4.1-mini` Responses. This release also fixes signed numeric output and radix handling. | [Offline retry and restart example](https://github.com/cgint/dspy.ex/blob/v0.6.0/examples/offline/provider_retry_disk_cache_offline.exs), [fresh-process disk test](https://github.com/cgint/dspy.ex/blob/v0.6.0/test/lm/disk_cache_test.exs), and [consumer contracts](https://github.com/cgint/dspy.ex/tree/v0.6.0/test/consumer_contract). |
| `v0.5.0` | **M2-a: Save and reuse optimized programs.** BootstrapRS trains composite programs. Native JSON v1 restores learned state by typed predictor slot into a caller-built program with caller-supplied LM bindings. This release also includes parsed completions, scoped concurrency, and ordered embedding batches. Review the [sampling changes](#sampling-after-v0411) before reusing seeded baselines. | [Fresh-BEAM BootstrapRS test](https://github.com/cgint/dspy.ex/blob/v0.5.0/test/module_program_state_fresh_process_test.exs), [checkpoint contract](https://github.com/cgint/dspy.ex/tree/v0.5.0/openspec/changes/m2a-save-load-state), and [consumer contract](https://github.com/cgint/dspy.ex/tree/v0.5.0/test/consumer_contract). |
| `v0.4.11` | **Stabilization.** Includes the v0.4.10 provider-log redaction, patched JSV and idna floors, the ReqLLM pin, a supervised in-memory cache, early failure-score validation, and answer-only comparison attempts for blank rationales. Compatibility gates cover native structured output and fallback. | [Offline evaluation example](https://github.com/cgint/dspy.ex/blob/v0.4.11/examples/offline/semantic_f1_evaluation_offline.exs), [consumer contract](https://github.com/cgint/dspy.ex/tree/v0.4.11/test/consumer_contract), and [reviewed parity baseline](https://github.com/cgint/dspy.ex/blob/v0.4.11/plan/current/UPSTREAM_RECOUNT.md). |
| `v0.4.10` | **Provider error redaction.** The patch release from the v0.4.9 line logs fixed summaries, valid HTTP status codes, and allowlisted reason tags for adapter retries and ReqLLM native fallback. The redaction is also included on `main`, alongside debug-level exhaustion logging. | [Release evidence at v0.4.10](https://github.com/cgint/dspy.ex/blob/v0.4.10/docs/RELEASES.md#tags). |
| `v0.4.9` | **Log-safe adapter retry reasons** (continues OpenSpec `adapter-retry-observability-logging`) — routes all four retry/exhaustion log lines through a new `format_reason/1` so a `%ReqLLM.Error.API.Request{}` (or any exception) renders as its `Exception.message/1` summary (e.g. `"API request failed: timeout"`), meaning its `request_body` (the full prompt + output contract), `response_body`, and `headers` **never** reach a log line; non-exception reasons are `inspect/1`-truncated to 300 chars. See the v0.4.11 adapter fixes for the exhaustion-level correction. | `LeakyLM` no-leak test in `adapter_pipeline_edge_cases` proves a real `%ReqLLM.Error.API.Request{}` with a secret body logs only the summary; focused retry + consumer-contract tests pass (`adapter_pipeline_edge_cases`, `typed_output_retry`, `untyped_output_retry_default_adapter`, `max_output_retries_settings_default`, `test/consumer_contract`); `mix compile --warnings-as-errors` clean; `mix format --check-formatted` clean. |
| `v0.4.8` | **Adapter retry observability** (OpenSpec `adapter-retry-observability-logging`) — the two previously-silent retry loops in `Dspy.Signature.Adapter.Pipeline` now log: each **retry attempt** (transport via `max_retries`, output parse/validate via `max_output_retries`) at the **`:debug`** level, and **retries-exhausted** (the terminal "gave up" moment) at the **`:info`** level. Lines are stable and greppable: `dspy.adapter_retry` / `dspy.adapter_exhausted` with a `kind=` field (`transport`|`output`), the stable `call_id` (the `make_ref` that spans both retry kinds for one call), and a kind-specific attempt counter. Log-only: **no** callback event, **no** `Settings` key, **no** change to `Pipeline.run/4` or any `{:ok,_}`/`{:error,_}` return shape. This is what lets a long LM-heavy run distinguish "one slow call" from "N retried calls". | focused retry tests pass (`adapter_pipeline_edge_cases`, `typed_output_retry`, `untyped_output_retry_default_adapter`, `max_output_retries_settings_default`); `mix compile --warnings-as-errors` clean. |
| `v0.4.7` | **Image input: `:image` is a declared, validatable signature field type** (OpenSpec `align-image-input-with-python`) — the runtime `Dspy.Image` splicing from v0.4.6-era work is now a first-class, *declared* type: `"img: image -> answer: string"` arrow signatures and `input_field(:img, :image, ...)` store `type: :image`, and `Dspy.Signature.validate_inputs/2` accepts only `%Dspy.Image{}` (single, or a non-empty list where every element is a `%Dspy.Image{}`) on a `:image` field — anything else (plain binary, number, atom, mixed or empty list) is rejected with `{:invalid_input_value, name, :invalid_image}`. The `:string` escape-hatch (`%Dspy.Image{}` on a `:string` field) is unchanged for all other field types. Image input is now discoverable in README ("What works today" bullet + the three `examples/playground/image_input_*.exs`), `docs/OVERVIEW.md` (new section 6, e2e proof), `docs/PROVIDERS.md` (`image_url` part), `docs/COMPATIBILITY.md` (`dspy.Image` row), and the `Dspy.Attachments` moduledoc. | 12/12 new field-type tests (6/12 red at baseline, TDD); consumer_contract 33/33; full suite 961 passed; `mix compile --warnings-as-errors` clean; `mix format --check-formatted` clean (this release also sweeps pre-existing formatter drift from the image-input commit `0d7b0d1` across `lib/dspy/signature/**`, `lib/dspy/image.ex` and `test/dspy/image_*_test.exs`); mutation checks (5) each reddened the target test. | 
| `v0.4.6` | **Dataset and DataLoader** (M1-e) — load CSV/JSON/lists into examples and split or sample them **exactly as upstream DSPy 3.4.0 does for the same seed** (`Dspy.Random` reproduces CPython's `random` bit-for-bit). Loaded data works through `Evaluate`, `SemanticF1` and `LabeledFewShot` demos. Six declared deviations (E2–E7, see `COMPATIBILITY.md`), checked mechanically against the fixture. **Also completes H15:** `Example.fetch/2` and `Prediction.fetch/2` (used by `example[:key]`) now go through the same string-key accessor as `get/2`. | Greta PASS after blocks in all three phases; 61/61 contract mutations killed by declared tests (`CONTRACT_IDS` enforced), every acceptance test claimed, `also` lists equal observed failures; golden fixtures regenerate identically from upstream 3.4.0; 925 tests; ci_docker green; canary. Note: the phase-2 mutation report was overwritten by phase 3 (re-runnable, not committed). **CI note:** the tagged commit is red on the Elixir 1.18 matrix leg because a *test* used `String.count/2` (1.19+); library code is unaffected on 1.18. Fixed in the next commit, which also makes `ci_docker.sh` run both matrix legs. |
| `v0.4.5` | **String-keyed data works everywhere** (H15) — fixes two bugs in shipped code. *Silent:* a demo with string keys (e.g. loaded from CSV/JSON) was rendered into the prompt with **blank values** by the Default and JSON adapters, so few-shot optimisers trained on empty demos without any warning. *Loud:* `answer_exact_match` / `answer_passage_match` raised on string-keyed examples, so `Evaluate` scored every loaded example as a failure. All field reads now go through one internal accessor (atom key wins when both exist, as before). `Dspy.majority/2` accepts string-keyed maps. Atom-keyed prompts are byte-identical to v0.4.4. | Greta PASS after 1 block (padded `also` lists); first slice on the C2 mutation library: 15/15 killed by declared tests, every acceptance test claimed; 843 tests; ci_docker green; canary 3 PASS + 2 WARN-BASELINE. |
| `v0.4.4` | **LM-judged metrics** (M1-d): `Dspy.Evaluate.SemanticF1` (precision/recall judged by an LM, F1 with a threshold; `decompositional` mode) and `Dspy.Evaluate.CompleteAndGrounded` (completeness + groundedness against retrieved context), plus `threshold_metric/1`. Metrics return a float, as `Evaluate` expects. A judge answer that cannot be parsed raises `Dspy.Evaluate.JudgeError` carrying the **raw judge answer**. Scores match upstream DSPy 3.4.0 golden fixtures. | Greta PASS after 1 block; 22/22 mutations killed by their declared tests (harness re-broken by Greta); 812 tests 20/20 clean; ci_docker green; canary 3 PASS + 2 WARN-BASELINE. Tests: https://github.com/cgint/dspy.ex/tree/v0.4.4/test/dspy/evaluate |
| `v0.4.3` | **Strict `:number` / `:integer` output parsing** (H12) — a **live bug fix**. Before: an LM answering `"80%"` for a `:number` field was silently parsed as `80.0`, and a judge metric could clamp it to a **perfect 1.0** — a bad answer dressed up as a good one. `"1/2"` likewise became `1.0`. After: only a string that is *wholly* a number is accepted; anything else is a parse failure and the example scores as failed. Now matches upstream DSPy 3.4.0, including its literal quirks (`0x10`, `0b101`, `0o17`, `(5)`, `1_000`, `.5`, `5.`). **Declared deviations:** `NaN`/`inf` and the word `"true"` are rejected — upstream accepts them and its clamp turns them into perfect scores, and the BEAM cannot represent NaN or infinity. Also closes **H6**, a suite-wide flakiness hazard. | Greta PASS after 3 blocks. The lenient parser existed in **three copies** and four of five consumer apps run the JSON adapter, so fixing one would have protected almost nobody — all three now delegate to one shared parser, proven by reverting each call site individually *and* the shared module. Oracle: 230 rows generated from upstream. Mutation harness committed and re-runnable; it refuses to start on leftover debris and fails hard if any mutation is skipped. 767 tests, 20× stable. |
| `v0.4.2` | **`Dspy.majority/2`** (M1-c) — picks the most common completion per field, with ties going to the **earliest** completion, as upstream. Takes a list of completions; `:field` is required unless every completion shares one key; a `normalize` function returning `nil` ignores that completion. `true` and `1` are **not** the same vote (Python counts them as one) — declared in `COMPATIBILITY.md`. | Greta PASS after 4 blocks, none of which a green suite would have shown: a string `:field` **silently ignored** (wrong answer, no error); an explicit `nil` raising "missing field"; a fix that handled only atom keys and broke string-keyed `Prediction`s (the shape anything built from JSON has); an invented upstream signature in the compatibility doc; **two revert-mutations that went red for the wrong reason**; and one fix with no revert-mutation at all. 19-mutation sweep at 19 RED / zero survivors; 600 tests ×10; oracle values generated from upstream 3.4.0. |
| `v0.4.1` | **Python-compatible metrics** (M1-b): `answer_exact_match` (with `frac` and answer lists), `answer_passage_match` with upstream's DPR tokenizer, `em`/`f1` over answer lists, and a public **frozen** `Dspy.Metrics.normalize_text/1` — equal to DSPy 3.4.0 for every binary, never "improved"; a better normaliser would get a new name. Oracle values are generated from upstream by a committed script, not hand-written. | Greta PASS after 1 block. Her **mutation script** found five unpinned behaviours in one sweep where a day of hand-mutation had found two — including that the entire DPR tokenizer could be replaced by `String.split/1` with no test failing (the port was correct, simply unprotected). One fixture row had recorded a **Python error message as its expected value**, so the oracle was silently broken while every test was green. Final proof: 17 mutations, 0 survivors, including one revert-mutation per fix. 573 tests ×10. |
| `v0.4.0` | **M1-a — Evaluation results you can keep** (opens milestone M1). `Dspy.Evaluate.evaluate/4` now returns a `%Dspy.Evaluate.Result{}` struct implementing `Access`, so `r.mean`, `r[:mean]`, `Map.get/2` and pattern matching all keep working. Adds upstream's `score` (a **percentage**, e.g. `67.3`) and an always-populated `results` list of `{example, prediction, score}`. New options: `save_as_csv` (NimbleCSV), `save_as_json`, `display_table`, `display_progress`, `provide_traceback`, `metric_name`; plus the always-on `Average Metric: s / n (p%)` line, as upstream. Also fixes a **v0.3.48** path where a metric that `throw`s or `exit`s crashed the caller. **New dep:** `nimble_csv ~> 1.2`. | Greta PASS after **4 blocks**, each a real data-integrity defect caught before release: CSV header taken as the union of all rows (would have crashed saving any run containing a failure); column order derived from `Map.keys/1`, i.e. decided by the VM's atom table since OTP 26; two silent data-loss bugs (fields routed by key *name*, so `pred_label` on an example was written as `null`; string-keyed examples never colliding, emitting the same JSON key twice); and the two writers disagreeing with each other. Every acceptance row mutation-proven RED; suite repeated 10× per round; consumer canary green. |
| `v0.3.48` | **Evaluation errors and scoring (H0b-2)**: failed examples now score `failure_score` (default `0.0`) *into* the mean instead of being silently dropped, so **reported scores can drop**; evaluation stops at the 10th error (`max_errors`, settable, `Dspy.Evaluate.MaxErrorsExceeded`) — this reaches **6 optimizers**, so a compile with ≥10 failing runs now stops. Boolean metric results count as `1.0`/`0.0` (previously excluded entirely — a bug, since `a == b` is the most common DSPy metric). A metric result that is neither a number nor a boolean raises `Dspy.Evaluate.InvalidMetricResult`; an empty testset raises `ArgumentError`. All four behaviours follow Python DSPy 3.4.0, verified by probe rather than by preference. | Greta PASS after 2 blocks; 4 mutation sites reproduced independently in her clone; orphaned-task probe: pending tasks killed, not leaked; ci_docker 1.19.5/OTP28 + 1.18.4/OTP27 green; `mix hex.audit` clean; canary 3 PASS / 2 WARN-BASELINE; GitHub CI run: https://github.com/cgint/dspy.ex/actions/runs/36468583317 |
| `v0.3.47` | **Extras security: `httpoison` replaced by `req`** in `dspy_extras` (`Dspy.LM.LiteLLM`): removes `hackney` and its 4 advisories (1 high, no fix reachable via httpoison). Same return shapes; transport error text now reads e.g. `"Network error: connection refused"` (was `econnrefused`); other request failures return `{:error, "Request failed: ..."}` instead of crashing. First extras tests (8). Remaining: 2 `cowlib` advisories via `plug_cowboy` (no upstream fix yet). Core unchanged. | Greta PASS after 1 block; ci_docker 1.19 + 1.18 green; GitHub CI run: https://github.com/cgint/dspy.ex/actions/runs/36453181342 |
| `v0.3.46` | **Crash/timeout hardening (H0b-1)**: a child that raises, throws, exits or times out at the runtime spawn sites (`Dspy.Module.parallel` new `:timeout`, ReAct tool calls, Ensemble/BootstrapFewShot/MIPROv2/SIMBA workers) no longer kills the caller; it becomes a failed item. Ensemble weights stay aligned to members. BootstrapFewShot `compile/3` no longer crashes with `Enum.EmptyError` when every candidate fails (returns a usable program, like upstream). No API break. | Behaviour proofs through `compile/3`, each red with its catch removed (mipro:299, bootstrap:274 throw+exit); defense-in-depth sites listed in `openspec/changes/h0b-crash-hardening/proposal.md` (Deviations); 25/25 repeated runs (incl. CPU load) with no flakes; GitHub CI run: https://github.com/cgint/dspy.ex/actions/runs/36435364319 |
| `v0.3.45` | **Security: HTTP dependency floors** (SEC-1): fixes 14 advisories in the LM HTTP path (req, mint, hpax). dspy.ex now requires `req >= 0.6.1`, `mint >= 1.11.0`, `hpax >= 1.1.0` so consumers cannot resolve vulnerable versions; consumers run `mix deps.update req mint hpax finch` (see Consumer notes: req 0.6+ makes decompression/archive decoding opt-in). No dspy.ex API change. | Tested sha in `ci_docker` on 1.19.5/OTP28 + 1.18.4/OTP27 (all green); `mix hex.audit` on the release sha: "No retired or security advisory packages found"; GitHub CI run: https://github.com/cgint/dspy.ex/actions/runs/36430915856 |
| `v0.3.44` | **`Dspy.Context`** (`capture/0` + `with_context/2`): carries caller `Dspy.context/2` overrides (incl. `track_usage`, `callbacks`) and the adapter callback stack into all 13 library spawn sites (Parallel, Module.parallel, Evaluate, Tools x2, Ensemble x3, SIMBA, BootstrapFewShot x2, MIPROv2, Retrieve); installs in the current process and restores on return/raise/throw/exit, spawns nothing. Upstream parity: child usage stays on the child prediction (no merge-back) | Context: https://github.com/cgint/dspy.ex/blob/v0.3.44/lib/dspy/context.ex<br>Proof: https://github.com/cgint/dspy.ex/tree/v0.3.44/test/context |
| `v0.3.43` | **`Dspy.MultiChainComparison`** (Python `dspy.MultiChainComparison`): compares M reasoning attempts via an extended signature (`reasoning_attempt_i` inputs, leading `rationale` output) at a context-scoped temperature | MCC: https://github.com/cgint/dspy.ex/blob/v0.3.43/lib/dspy/multi_chain_comparison.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.43/test/multi_chain_comparison_test.exs |
| `v0.3.42` | **`Dspy.Parallel`** (Python `dspy.Parallel`): `run/3` over `{module, input}` pairs via `Task.async_stream` (bounded `:num_threads`, ordered, per-task timeout), propagates `Dspy.context/2` overrides into tasks, failures → `nil` + optional `return_failed_examples` triple, `:max_errors` halts scheduling | Parallel: https://github.com/cgint/dspy.ex/blob/v0.3.42/lib/dspy/parallel.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.42/test/parallel_test.exs |
| `v0.3.41` | **`Dspy.BestOfN`** (Python `dspy.BestOfN`): up to N attempts, each inside `Dspy.context(temperature: 1.0, rollout_id: start+i)`; early stop at `threshold`, best reward otherwise, `fail_count` budget → `{:error, {:best_of_n_failed, ...}}`. New `:rollout_id` setting participates in the LM cache key (only when non-nil; legacy keys unchanged) and is never sent to providers. Note: temperature 1.0 is a settings default — an explicit per-request temperature still wins | BestOfN: https://github.com/cgint/dspy.ex/blob/v0.3.41/lib/dspy/best_of_n.ex<br>Cache: https://github.com/cgint/dspy.ex/blob/v0.3.41/lib/dspy/lm/cache.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.41/test/best_of_n_test.exs<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.41/test/lm/rollout_id_cache_test.exs |
| `v0.3.40` | **`Dspy.context/2` (process-scoped settings overrides)**: Python `with dspy.context(lm=..., temperature=...)` equivalent; overrides are process-local, nest, restore on return/raise/throw, never mutate global `configure/1` state; `Dspy.Settings.current_overrides/0` + `with_overrides/2` propagate into child processes. Also adds `test/consumer_contract/` (frozen downstream surface) and `scripts/consumer_canary.sh` | Settings: https://github.com/cgint/dspy.ex/blob/v0.3.40/lib/dspy/settings.ex<br>Docs: https://github.com/cgint/dspy.ex/blob/v0.3.40/docs/COMPATIBILITY.md<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.40/test/settings_context_test.exs<br>Contract: https://github.com/cgint/dspy.ex/tree/v0.3.40/test/consumer_contract |
| `v0.3.38` | **Typed structured outputs: bounded retries**: `Dspy.Predict` + `Dspy.ChainOfThought` now support opt-in `max_output_retries` (default `0`) to retry on typed-output JSON decode/validation failures; retry prompts include schema + errors + "JSON only" instruction | Predict: https://github.com/cgint/dspy.ex/blob/v0.3.38/lib/dspy/predict.ex<br>CoT: https://github.com/cgint/dspy.ex/blob/v0.3.38/lib/dspy/chain_of_thought.ex<br>Docs: https://github.com/cgint/dspy.ex/blob/v0.3.38/docs/OVERVIEW.md<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.38/test/typed_output_retry_test.exs |
| `v0.3.37` | **Opt-in LM response caching**: `Dspy.LM.generate/1` and `generate/2` now cache successful responses in ETS when `Dspy.configure(cache: true)`; cache is cleared when `:lm`/`:cache` changes; multimodal/attachment requests are not cached; default is `cache: false` | LM: https://github.com/cgint/dspy.ex/blob/v0.3.37/lib/dspy/lm.ex<br>Cache: https://github.com/cgint/dspy.ex/blob/v0.3.37/lib/dspy/lm/cache.ex<br>Settings: https://github.com/cgint/dspy.ex/blob/v0.3.37/lib/dspy/settings.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.37/test/lm/cache_test.exs |
| `v0.3.36` | **Overview links Tools guide**: `docs/OVERVIEW.md` Tools row now points to `docs/TOOLS_REACT.md` for the stable ReAct surface | Overview: https://github.com/cgint/dspy.ex/blob/v0.3.36/docs/OVERVIEW.md |
| `v0.3.35` | **Tools/ReAct guide (with diagram)**: added `docs/TOOLS_REACT.md` (evidence-backed) and a D2 diagram for the ReAct loop; linked from `docs/COMPATIBILITY.md` | Guide: https://github.com/cgint/dspy.ex/blob/v0.3.35/docs/TOOLS_REACT.md<br>Diagram: https://github.com/cgint/dspy.ex/blob/v0.3.35/docs/diagrams/tools_react_flow.svg |
| `v0.3.34` | **Overview retrieval docs refresh**: `docs/OVERVIEW.md` retrieval section now points at the built-in `InMemoryRetriever` and includes full proof list; also mentions `scripts/verify_examples.sh` for running all offline examples | Overview: https://github.com/cgint/dspy.ex/blob/v0.3.34/docs/OVERVIEW.md |
| `v0.3.33` | **Offline example for request defaults**: added a deterministic script showing how `Dspy.configure/1` defaults propagate into request maps; included it in offline example verification list | Example: https://github.com/cgint/dspy.ex/blob/v0.3.33/examples/request_defaults_offline.exs<br>Verifier: https://github.com/cgint/dspy.ex/blob/v0.3.33/scripts/verify_examples.sh |
| `v0.3.32` | **Providers docs updated**: documented global `max_completion_tokens` defaults and clarified `max_tokens` vs `max_completion_tokens` guidance with evidence pointers | Providers doc: https://github.com/cgint/dspy.ex/blob/v0.3.32/docs/PROVIDERS.md |
| `v0.3.31` | **Trainset determinism + honest docs**: tightened `Dspy.Trainset` moduledoc to avoid overpromising; added deterministic tests for sampling strategies (`:diverse`, `:hard`, `:uncertainty`, `bootstrap_sample/3`) | Trainset: https://github.com/cgint/dspy.ex/blob/v0.3.31/lib/dspy/trainset.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.31/test/trainset_test.exs |
| `v0.3.30` | **RAG indexing reliability**: DocumentProcessor now ensures embedding provider modules are loaded before checking `embed_batch` (fixes silent nil embeddings in scripts); retrieval docs/examples were updated; deterministic proof added | Retrieve: https://github.com/cgint/dspy.ex/blob/v0.3.30/lib/dspy/retrieve.ex<br>Docs: https://github.com/cgint/dspy.ex/blob/v0.3.30/docs/RETRIEVE_RAG.md<br>Examples: https://github.com/cgint/dspy.ex/blob/v0.3.30/examples/retrieve_rag_offline.exs<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.30/test/retrieve/document_processor_provider_loading_test.exs |
| `v0.3.29` | **Builtin tools honesty**: clarified `builtin_tools/0` descriptions (no fake “internet” claims) and aligned metadata return types; added deterministic test to lock behavior | Tools: https://github.com/cgint/dspy.ex/blob/v0.3.29/lib/dspy/tools.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.29/test/tools_builtin_tools_test.exs |
| `v0.3.28` | **Global `max_completion_tokens` defaults**: `Dspy.configure/1` + `Dspy.Settings` now support `:max_completion_tokens` and `Dspy.LM.generate/1` applies it to request maps when missing | Settings: https://github.com/cgint/dspy.ex/blob/v0.3.28/lib/dspy/settings.ex<br>LM defaults: https://github.com/cgint/dspy.ex/blob/v0.3.28/lib/dspy/lm.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.28/test/lm/request_defaults_test.exs |
| `v0.3.27` | **Verify offline examples**: added `scripts/verify_examples.sh` to run the official deterministic examples (helps keep examples trustworthy) | Script: https://github.com/cgint/dspy.ex/blob/v0.3.27/scripts/verify_examples.sh<br>Docs: https://github.com/cgint/dspy.ex/blob/v0.3.27/scripts/README.md |
| `v0.3.26` | **Built-in in-memory retriever (RAG)**: added `Dspy.Retrieve.InMemoryRetriever` (GenServer-backed cosine retriever) + deterministic acceptance proof; offline RAG examples fixed/updated to run | Retriever: https://github.com/cgint/dspy.ex/blob/v0.3.26/lib/dspy/retrieve/in_memory_retriever.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.26/test/acceptance/retrieve_rag_in_memory_retriever_acceptance_test.exs<br>Example: https://github.com/cgint/dspy.ex/blob/v0.3.26/examples/retrieve_rag_genserver_offline.exs |
| `v0.3.25` | **VectorStore safety**: `Dspy.Retrieve.VectorStore` no longer crashes with `:noproc` when not started; it now returns `{:error, :vector_store_not_started}`; added deterministic tests | VectorStore: https://github.com/cgint/dspy.ex/blob/v0.3.25/lib/dspy/retrieve.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.25/test/retrieve/vector_store_safety_test.exs |
| `v0.3.24` | **README example discoverability**: added the official offline Tools/ReAct example to the README examples list | README: https://github.com/cgint/dspy.ex/blob/v0.3.24/README.md |
| `v0.3.23` | **ToolRegistry auto-start**: `Dspy.Tools.register_tool/1`, `get_tool/1`, `list_tools/0`, `search_tools/1` now start the ToolRegistry on-demand (avoids `:noproc` crashes) | Tools: https://github.com/cgint/dspy.ex/blob/v0.3.23/lib/dspy/tools.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.23/test/tools_registry_autostart_test.exs |
| `v0.3.22` | **Safer placeholder retriever**: `Dspy.Retrieve.ColBERTv2` no longer crashes when `VectorStore` is not started; it now returns explicit placeholder errors; Retriever callback types allow structured error reasons (`term()`) | Retrieve: https://github.com/cgint/dspy.ex/blob/v0.3.22/lib/dspy/retrieve.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.22/test/retrieve/colbert_stub_test.exs |
| `v0.3.21` | **ReAct request-map options**: `Dspy.Tools.React.run/3` now forwards `max_tokens`, `max_completion_tokens`, and `temperature` into LM request maps (per-run overrides) | React: https://github.com/cgint/dspy.ex/blob/v0.3.21/lib/dspy/tools.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.21/test/tools_request_map_test.exs |
| `v0.3.20` | **ReAct tool timeouts (proven)**: `Dspy.Tools.React` now executes tool functions in a `Task` and enforces each tool's `timeout` (callbacks receive a `:timeout` error shape); added deterministic tests | Tools: https://github.com/cgint/dspy.ex/blob/v0.3.20/lib/dspy/tools.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.20/test/tools_react_tool_timeout_test.exs<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.20/test/tools_execute_tool_test.exs |
| `v0.3.19` | **RAG doc-shape ergonomics**: `Dspy.Retrieve.RAGPipeline` now accepts retriever documents as maps (atom or string keys) for `content`/`source`/`score`; added proof test | RAGPipeline: https://github.com/cgint/dspy.ex/blob/v0.3.19/lib/dspy/retrieve.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.19/test/retrieve/rag_pipeline_doc_shapes_test.exs |
| `v0.3.18` | **Deterministic balanced sampling**: `Dspy.Trainset.stratified_sample/3` now iterates groups in stable order, making `Trainset.sample(..., strategy: :balanced, seed: ...)` deterministic; added proof test | Trainset: https://github.com/cgint/dspy.ex/blob/v0.3.18/lib/dspy/trainset.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.18/test/trainset_test.exs |
| `v0.3.17` | **Docs/truth-by-evidence polish**: clarified Tools/Retrieve moduledocs (stable vs placeholder); added contributor troubleshooting for Hex cache warning; added Tools+Retrieve offline examples to `docs/OVERVIEW.md` | Tools moduledoc: https://github.com/cgint/dspy.ex/blob/v0.3.17/lib/dspy/tools.ex<br>Retrieve moduledoc: https://github.com/cgint/dspy.ex/blob/v0.3.17/lib/dspy/retrieve.ex<br>Overview: https://github.com/cgint/dspy.ex/blob/v0.3.17/docs/OVERVIEW.md<br>Contributing: https://github.com/cgint/dspy.ex/blob/v0.3.17/CONTRIBUTING.md |
| `v0.3.16` | **Request maps support `max_completion_tokens` + safer chunking**: `generate_text/3`, Tools FunctionCalling, and RAGPipeline forward `max_completion_tokens`; DocumentProcessor validates chunking opts and `process_documents/2` falls back on invalid chunk config (prevents hangs) | LM: https://github.com/cgint/dspy.ex/blob/v0.3.16/lib/dspy/lm.ex<br>Tools: https://github.com/cgint/dspy.ex/blob/v0.3.16/lib/dspy/tools.ex<br>Retrieve: https://github.com/cgint/dspy.ex/blob/v0.3.16/lib/dspy/retrieve.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.16/test/lm/request_defaults_test.exs<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.16/test/tools_request_map_test.exs<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.16/test/acceptance/retrieve_rag_with_embeddings_acceptance_test.exs<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.16/test/retrieve/document_processor_chunk_text_test.exs |
| `v0.3.15` | **Better adoption UX for tools + providers**: added an official offline ReAct+tool-callback example; documented `max_completion_tokens` and token-limit normalization for OpenAI reasoning models | Example: https://github.com/cgint/dspy.ex/blob/v0.3.15/examples/react_tool_logging_offline.exs<br>Providers doc: https://github.com/cgint/dspy.ex/blob/v0.3.15/docs/PROVIDERS.md<br>Evidence (token limits): https://github.com/cgint/dspy.ex/blob/v0.3.15/test/lm/req_llm_token_limits_test.exs |
| `v0.3.14` | **Forward accepts Example inputs**: `Dspy.Module.forward/2` now accepts `%Dspy.Example{}` and forwards `Dspy.Example.inputs/1` (pairs naturally with `Example.with_inputs/2`) | Module: https://github.com/cgint/dspy.ex/blob/v0.3.14/lib/dspy/module.ex<br>Example: https://github.com/cgint/dspy.ex/blob/v0.3.14/lib/dspy/example.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.14/test/module_forward_example_test.exs |
| `v0.3.13` | **Quiet ReqLLM token limits + faster GEPA no-candidates path**: `Dspy.LM.ReqLLM` maps token limits to `max_completion_tokens` for OpenAI reasoning models (avoids `req_llm` warning spam); `GEPA.compile/3` skips baseline evaluation when no candidates are provided | ReqLLM adapter: https://github.com/cgint/dspy.ex/blob/v0.3.13/lib/dspy/lm/req_llm.ex<br>GEPA: https://github.com/cgint/dspy.ex/blob/v0.3.13/lib/dspy/teleprompt/gepa.ex<br>Proof (ReqLLM opts): https://github.com/cgint/dspy.ex/blob/v0.3.13/test/lm/req_llm_token_limits_test.exs<br>Proof (GEPA no-candidates): https://github.com/cgint/dspy.ex/blob/v0.3.13/test/teleprompt/gepa_test.exs |
| `v0.3.12` | **Example.with_inputs supported**: examples can mark which attrs are inputs; `Evaluate` (and key teleprompt flows) forward only those inputs when configured | Example: https://github.com/cgint/dspy.ex/blob/v0.3.12/lib/dspy/example.ex<br>Evaluate: https://github.com/cgint/dspy.ex/blob/v0.3.12/lib/dspy/evaluate.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.12/test/example_with_inputs_test.exs |
| `v0.3.11` | **Metrics proven**: built-in `Dspy.Metrics` functions are covered by deterministic tests; docs examples were corrected to match `Example`/`Prediction` access | Metrics: https://github.com/cgint/dspy.ex/blob/v0.3.11/lib/dspy/metrics.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.11/test/metrics_test.exs |
| `v0.3.10` | **Keyword-list inputs supported**: `Dspy.Module.forward/2` accepts keyword lists (kwargs-like) in addition to maps | Module: https://github.com/cgint/dspy.ex/blob/v0.3.10/lib/dspy/module.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.10/test/predict_test.exs |
| `v0.3.9` | **Access for Example + JSON-friendly attr updates**: `Dspy.Example` now implements `Access` (`ex[:question]`) and `Example`/`Prediction` preserve existing string-key attrs when updating via atom keys | Example: https://github.com/cgint/dspy.ex/blob/v0.3.9/lib/dspy/example.ex<br>Prediction: https://github.com/cgint/dspy.ex/blob/v0.3.9/lib/dspy/prediction.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.9/test/example_prediction_access_test.exs |
| `v0.3.8` | **String-key inputs supported**: `Predict` + `ChainOfThought` accept input maps with atom *or* string keys (JSON-friendly) | Signature input validation: https://github.com/cgint/dspy.ex/blob/v0.3.8/lib/dspy/signature.ex<br>Predict prompt fill: https://github.com/cgint/dspy.ex/blob/v0.3.8/lib/dspy/predict.ex<br>CoT prompt fill: https://github.com/cgint/dspy.ex/blob/v0.3.8/lib/dspy/chain_of_thought.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.8/test/predict_test.exs |
| `v0.3.7` | **ReqLLM provider parity smoke tests**: opt-in multi-provider network smoke tests for Predict + embeddings + clearer provider-key docs | Predict smoke: https://github.com/cgint/dspy.ex/blob/v0.3.7/test/integration/req_llm_predict_integration_test.exs<br>Embeddings smoke: https://github.com/cgint/dspy.ex/blob/v0.3.7/test/integration/req_llm_embeddings_integration_test.exs<br>Provider docs: https://github.com/cgint/dspy.ex/blob/v0.3.7/docs/PROVIDERS.md |
| `v0.3.6` | **MIPROv2 proven for ChainOfThought + offline demo**: MIPROv2 now supports `%Dspy.ChainOfThought{}` (deterministic proof) and has an offline CoT + persistence demo | MIPROv2: https://github.com/cgint/dspy.ex/blob/v0.3.6/lib/dspy/teleprompt/mipro_v2.ex<br>Predict proof: https://github.com/cgint/dspy.ex/blob/v0.3.6/test/teleprompt/mipro_v2_improvement_test.exs<br>CoT proof: https://github.com/cgint/dspy.ex/blob/v0.3.6/test/teleprompt/mipro_v2_chain_of_thought_improvement_test.exs<br>CoT example: https://github.com/cgint/dspy.ex/blob/v0.3.6/examples/chain_of_thought_mipro_v2_persistence_offline.exs |
| `v0.3.5` | **MIPROv2 proven + offline demo**: joint optimizer for `predict.instructions` + `predict.examples` (Predict-only) + deterministic persistence demo | MIPROv2: https://github.com/cgint/dspy.ex/blob/v0.3.5/lib/dspy/teleprompt/mipro_v2.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.5/test/teleprompt/mipro_v2_improvement_test.exs<br>Example: https://github.com/cgint/dspy.ex/blob/v0.3.5/examples/predict_mipro_v2_persistence_offline.exs<br>Teleprompt factory: https://github.com/cgint/dspy.ex/blob/v0.3.5/lib/dspy/teleprompt.ex |
| `v0.3.4` | **Offline COPRO + persistence demo**: deterministic ChainOfThought optimization via COPRO + JSON parameter save/restore | Example: https://github.com/cgint/dspy.ex/blob/v0.3.4/examples/chain_of_thought_copro_persistence_offline.exs<br>Examples index: https://github.com/cgint/dspy.ex/blob/v0.3.4/examples/README.md |
| `v0.3.3` | **COPRO proven for ChainOfThought**: COPRO now supports `%Dspy.ChainOfThought{}` in addition to `%Dspy.Predict{}` (deterministic improvement proofs for both) | COPRO: https://github.com/cgint/dspy.ex/blob/v0.3.3/lib/dspy/teleprompt/copro.ex<br>Predict proof: https://github.com/cgint/dspy.ex/blob/v0.3.3/test/teleprompt/copro_improvement_test.exs<br>CoT proof: https://github.com/cgint/dspy.ex/blob/v0.3.3/test/teleprompt/copro_chain_of_thought_improvement_test.exs |
| `v0.3.2` | **COPRO proven + promoted**: coordinate-ascent teleprompter that selects improved `predict.instructions` (deterministic improvement proof) | COPRO: https://github.com/cgint/dspy.ex/blob/v0.3.2/lib/dspy/teleprompt/copro.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.3.2/test/teleprompt/copro_improvement_test.exs<br>Teleprompt factory: https://github.com/cgint/dspy.ex/blob/v0.3.2/lib/dspy/teleprompt.ex |
| `v0.3.1` | **Signature core-slimming**: removed the large, unproven predefined signature catalog from core (reduces onboarding noise and compile surface) | Signature: https://github.com/cgint/dspy.ex/blob/v0.3.1/lib/dspy/signature.ex |
| `v0.3.0` | **Core scope quarantine + examples curation**: moved unproven/experimental modules out of core `lib/` into `extras/` and separated exploratory scripts into `examples/experimental/` | Core scope audit: https://github.com/cgint/dspy.ex/blob/v0.3.0/plan/CORE_SCOPE_AUDIT.md<br>Quarantine: https://github.com/cgint/dspy.ex/tree/v0.3.0/extras/dspy_extras/unsafe/quarantine/lib/dspy<br>Teleprompt factory (core): https://github.com/cgint/dspy.ex/blob/v0.3.0/lib/dspy/teleprompt.ex<br>Examples index: https://github.com/cgint/dspy.ex/blob/v0.3.0/examples/README.md<br>Extras compilation paths: https://github.com/cgint/dspy.ex/blob/v0.3.0/extras/dspy_extras/mix.exs |
| `v0.2.18` | **LabeledFewShot generalization**: supports any program exposing `predict.examples` (not just Predict/CoT structs) | LabeledFewShot: https://github.com/cgint/dspy.ex/blob/v0.2.18/lib/dspy/teleprompt/labeled_few_shot.ex<br>Proof: https://github.com/cgint/dspy.ex/blob/v0.2.18/test/teleprompt/labeled_few_shot_generic_program_test.exs |
| `v0.2.17` | **CoT parameter persistence proven**: JSON roundtrip preserves SIMBA improvement for ChainOfThought | Proof: https://github.com/cgint/dspy.ex/blob/v0.2.17/test/module_parameter_json_persistence_chain_of_thought_test.exs |
| `v0.2.16` | **BootstrapFewShot error-shape cleanup**: internal bootstrapping errors are tagged tuples (no bare strings) | BootstrapFewShot: https://github.com/cgint/dspy.ex/blob/v0.2.16/lib/dspy/teleprompt/bootstrap_few_shot.ex |
| `v0.2.15` | **Offline SIMBA + persistence demo**: ChainOfThought optimized via SIMBA + JSON parameter save/restore | Example: https://github.com/cgint/dspy.ex/blob/v0.2.15/examples/chain_of_thought_simba_persistence_offline.exs |
| `v0.2.14` | **Teleprompt support hardening**: GEPA + BootstrapFewShot now fail fast on unsupported programs (parameter contract) | GEPA: https://github.com/cgint/dspy.ex/blob/v0.2.14/lib/dspy/teleprompt/gepa.ex<br>BootstrapFewShot: https://github.com/cgint/dspy.ex/blob/v0.2.14/lib/dspy/teleprompt/bootstrap_few_shot.ex<br>Error shape proof: https://github.com/cgint/dspy.ex/blob/v0.2.14/test/teleprompt/error_shapes_test.exs |
| `v0.2.13` | **Offline Ensemble demo**: deterministic `Ensemble.compile/3` example script | Example: https://github.com/cgint/dspy.ex/blob/v0.2.13/examples/ensemble_offline.exs |
| `v0.2.12` | **Ensemble parity + docs**: Ensemble proven for ChainOfThought; `Dspy.Teleprompt` docs clarify proven vs experimental teleprompters | CoT ensemble proof: https://github.com/cgint/dspy.ex/blob/v0.2.12/test/teleprompt/ensemble_chain_of_thought_improvement_test.exs<br>Teleprompt docs: https://github.com/cgint/dspy.ex/blob/v0.2.12/lib/dspy/teleprompt.ex |
| `v0.2.11` | **Ensemble teleprompt (fixed)**: returns a struct program (no runtime modules) + deterministic compile smoke | Ensemble implementation: https://github.com/cgint/dspy.ex/blob/v0.2.11/lib/dspy/teleprompt/ensemble.ex<br>Compile improvement proof: https://github.com/cgint/dspy.ex/blob/v0.2.11/test/teleprompt/ensemble_compile_improvement_test.exs<br>Majority vote proof: https://github.com/cgint/dspy.ex/blob/v0.2.11/test/teleprompt/ensemble_program_test.exs |
| `v0.2.10` | **Offline workflow demo**: ChainOfThought + LabeledFewShot + JSON parameter persistence | Example: https://github.com/cgint/dspy.ex/blob/v0.2.10/examples/chain_of_thought_teleprompt_persistence_offline.exs<br>Overview docs: https://github.com/cgint/dspy.ex/blob/v0.2.10/docs/OVERVIEW.md |
| `v0.2.9` | **BootstrapFewShot + GEPA proven for ChainOfThought**: deterministic improvement for CoT via `predict.examples` and `predict.instructions` | BootstrapFewShot CoT proof: https://github.com/cgint/dspy.ex/blob/v0.2.9/test/teleprompt/bootstrap_few_shot_chain_of_thought_improvement_test.exs<br>GEPA CoT proof: https://github.com/cgint/dspy.ex/blob/v0.2.9/test/teleprompt/gepa_chain_of_thought_improvement_test.exs |
| `v0.2.8` | **SIMBA proven for ChainOfThought**: deterministic improvement via `predict.instructions` on `%Dspy.ChainOfThought{}` | CoT improvement proof: https://github.com/cgint/dspy.ex/blob/v0.2.8/test/teleprompt/simba_chain_of_thought_improvement_test.exs  \
SIMBA teleprompter: https://github.com/cgint/dspy.ex/blob/v0.2.8/lib/dspy/teleprompt/simba.ex |
| `v0.2.7` | **Teleprompter parity**: LabeledFewShot supports ChainOfThought; docs clarify Predict-like parameter callbacks | LabeledFewShot: https://github.com/cgint/dspy.ex/blob/v0.2.7/lib/dspy/teleprompt/labeled_few_shot.ex  \
CoT improvement proof: https://github.com/cgint/dspy.ex/blob/v0.2.7/test/teleprompt/labeled_few_shot_chain_of_thought_improvement_test.exs  \
Overview docs: https://github.com/cgint/dspy.ex/blob/v0.2.7/docs/OVERVIEW.md |
| `v0.2.6` | **ChainOfThought parity**: supports arrow-string signatures, attachments request parts, and teleprompt parameter callbacks | CoT implementation: https://github.com/cgint/dspy.ex/blob/v0.2.6/lib/dspy/chain_of_thought.ex  \
CoT acceptance: https://github.com/cgint/dspy.ex/blob/v0.2.6/test/acceptance/chain_of_thought_acceptance_test.exs  \
CoT attachments: https://github.com/cgint/dspy.ex/blob/v0.2.6/test/acceptance/chain_of_thought_attachments_acceptance_test.exs |
| `v0.2.5` | **Dependency slimming**: core `:dspy` no longer depends on Bumblebee/Nx/EXLA (local inference remains an opt-in adapter) | Core deps: https://github.com/cgint/dspy.ex/blob/v0.2.5/mix.exs  \
Bumblebee adapter note: https://github.com/cgint/dspy.ex/blob/v0.2.5/docs/BUMBLEBEE.md |
| `v0.2.4` | **Parameter persistence (file helpers)**: write/read parameters JSON to/from disk; offline demo script | File persistence tests: https://github.com/cgint/dspy.ex/blob/v0.2.4/test/parameter_file_persistence_test.exs  \
Offline demo: https://github.com/cgint/dspy.ex/blob/v0.2.4/examples/parameter_persistence_json_offline.exs  \
Helpers: https://github.com/cgint/dspy.ex/blob/v0.2.4/lib/dspy/parameter.ex |
| `v0.2.3` | **JSON-friendly parameter persistence**: encode/decode parameter lists to JSON (supports `%Dspy.Example{}` values) | JSON roundtrip proof: https://github.com/cgint/dspy.ex/blob/v0.2.3/test/module_parameter_json_persistence_test.exs  \
Encoder/decoder: https://github.com/cgint/dspy.ex/blob/v0.2.3/lib/dspy/parameter.ex  \
Overview: https://github.com/cgint/dspy.ex/blob/v0.2.3/docs/OVERVIEW.md |
| `v0.2.2` | **ReqLLM provider wiring**: apply `Dspy.configure/1` defaults (`temperature`/`max_tokens`) to request maps; add ReqLLM+Predict offline acceptance; add opt-in real-provider smoke test | Settings defaults applied: https://github.com/cgint/dspy.ex/blob/v0.2.2/test/lm/request_defaults_test.exs  \
ReqLLM Predict acceptance: https://github.com/cgint/dspy.ex/blob/v0.2.2/test/acceptance/req_llm_predict_acceptance_test.exs  \
ReqLLM real-provider smoke (opt-in): https://github.com/cgint/dspy.ex/blob/v0.2.2/test/integration/req_llm_predict_integration_test.exs  \
Provider docs: https://github.com/cgint/dspy.ex/blob/v0.2.2/docs/PROVIDERS.md |
| `v0.2.1` | **Evaluation + optimization maturity**: per-example evaluation results (`return_all: true`), deterministic `Trainset.split/2` + `Trainset.sample/3` tests, deterministic SIMBA improvement, teleprompt errors standardized (no bare strings), parameter export/apply, and ChainOfThought end-to-end acceptance | Evaluate detailed results: https://github.com/cgint/dspy.ex/blob/v0.2.1/test/evaluate_detailed_results_test.exs  \
SIMBA improvement: https://github.com/cgint/dspy.ex/blob/v0.2.1/test/teleprompt/simba_improvement_test.exs  \
Teleprompt error shapes: https://github.com/cgint/dspy.ex/blob/v0.2.1/test/teleprompt/error_shapes_test.exs  \
Parameter persistence: https://github.com/cgint/dspy.ex/blob/v0.2.1/test/module_parameter_persistence_test.exs  \
ChainOfThought acceptance: https://github.com/cgint/dspy.ex/blob/v0.2.1/test/acceptance/chain_of_thought_acceptance_test.exs |
| `v0.2.0` | **Dependency slimming / library-first core**: extracted optional Phoenix/"godmode"/GenStage/legacy HTTP modules into `extras/dspy_extras` and removed Phoenix/GenStage/HTTPoison deps from core `:dspy` | Optional package: https://github.com/cgint/dspy.ex/tree/v0.2.0/extras/dspy_extras  \
Core deps (slim): https://github.com/cgint/dspy.ex/blob/v0.2.0/mix.exs |
| `v0.1.2` | Quieter + more deterministic developer experience on top of `v0.1.1`: don’t start `:os_mon` by default (avoids alarm/log noise in library/test usage); when optional services are enabled, attempt to start `:os_mon` with an explicit warning on failure; make `BootstrapFewShot` determinism test fail loudly if prompt format changes | Optional services startup gate: https://github.com/cgint/dspy.ex/blob/v0.1.2/lib/dspy/application.ex  \
BootstrapFewShot determinism test: https://github.com/cgint/dspy.ex/blob/v0.1.2/test/teleprompt/bootstrap_few_shot_determinism_test.exs |
| `v0.1.1` | Adds additional adoption slices and hygiene on top of `v0.1.0`: contracts-style PDF→JSON→Q&A acceptance workflow, image transcription workflow, quieter library-first startup (optional web/godmode services gated), BootstrapFewShot sampling made explicit + determinism regression test, and Bumblebee local-inference notes | Overview: https://github.com/cgint/dspy.ex/blob/v0.1.1/docs/OVERVIEW.md  \
Acceptance tests: https://github.com/cgint/dspy.ex/tree/v0.1.1/test/acceptance  \
Optional services gate (library-first startup): https://github.com/cgint/dspy.ex/blob/v0.1.1/lib/dspy/application.ex  \
Bumblebee note: https://github.com/cgint/dspy.ex/blob/v0.1.1/docs/BUMBLEBEE.md |
| `v0.1.0` | First public, pin-worthy slice: `Predict` + signatures (module + arrow-string), JSON fenced output parsing + coercion, `one_of` constraints, tools (ReAct + callbacks), attachments request parts + ReqLLM multipart/safety (tested with mocks; no real network calls in CI), and quiet teleprompter logging via Logger | Overview: https://github.com/cgint/dspy.ex/blob/v0.1.0/docs/OVERVIEW.md  \
Acceptance tests: https://github.com/cgint/dspy.ex/tree/v0.1.0/test/acceptance  \
ReqLLM multipart/attachments safety: https://github.com/cgint/dspy.ex/blob/v0.1.0/test/lm/req_llm_multimodal_test.exs |
