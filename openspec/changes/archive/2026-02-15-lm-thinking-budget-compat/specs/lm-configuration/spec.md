## ADDED Requirements

### Requirement: Accept Python DSPy Google model prefixes
The system SHALL accept Python-DSPy-style model strings using `gemini/<model>` and `vertex_ai/<model>` prefixes when creating an LM via `Dspy.LM.new/2`.

#### Scenario: Normalize gemini/ prefix
- **WHEN** the user calls `Dspy.LM.new("gemini/gemini-2.5-flash")`
- **THEN** the returned LM SHALL target the `req_llm` Google provider with internal model spec `"google:gemini-2.5-flash"`

#### Scenario: Normalize vertex_ai/ prefix
- **WHEN** the user calls `Dspy.LM.new("vertex_ai/gemini-2.5-flash")`
- **THEN** the returned LM SHALL target the `req_llm` Google Vertex provider with internal model spec `"google_vertex:gemini-2.5-flash"`

### Requirement: Support thinking_budget for Gemini via LM constructor
The system SHALL allow configuring Gemini thinking token budget via `thinking_budget: <non-negative integer>` in `Dspy.LM.new/2` options.

For Google/Gemini models, `thinking_budget` SHALL be translated to `req_llm` provider options as `google_thinking_budget: <value>`.

#### Scenario: Set a positive thinking budget
- **WHEN** the user calls `Dspy.LM.new("google/gemini-2.5-flash", thinking_budget: 4096)`
- **THEN** the returned LM SHALL be configured such that `req_llm` receives `provider_options: [google_thinking_budget: 4096]` as a default option

#### Scenario: Disable thinking via budget 0
- **WHEN** the user calls `Dspy.LM.new("google/gemini-2.5-flash", thinking_budget: 0)`
- **THEN** the returned LM SHALL be configured such that `req_llm` receives `provider_options: [google_thinking_budget: 0]` as a default option

#### Scenario: Reject negative thinking budget
- **WHEN** the user calls `Dspy.LM.new("google/gemini-2.5-flash", thinking_budget: -1)`
- **THEN** the call SHALL return an error indicating the value is invalid

### Requirement: Define precedence between thinking_budget and provider_options
If both `thinking_budget` and `provider_options: [google_thinking_budget: ...]` are provided, the system SHALL keep the explicit `provider_options` value.

#### Scenario: provider_options wins over thinking_budget
- **WHEN** the user calls `Dspy.LM.new("google/gemini-2.5-flash", thinking_budget: 4096, provider_options: [google_thinking_budget: 8192])`
- **THEN** the returned LM SHALL be configured such that `req_llm` receives `provider_options: [google_thinking_budget: 8192]` as a default option
