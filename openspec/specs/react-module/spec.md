# react-module Specification

## Purpose
TBD - created by archiving change dspy-react-module. Update Purpose after archive.
## Requirements
### Requirement: `Dspy.ReAct` is a signature-polymorphic `Dspy.Module`
The system SHALL provide a `Dspy.ReAct` module that can be constructed from a module-based signature, `%Dspy.Signature{}`, or arrow-string signature, similar to `Dspy.Predict`.

#### Scenario: Constructing ReAct from an arrow signature string
- **WHEN** the user calls `Dspy.ReAct.new("question -> answer", tools)`
- **THEN** the system SHALL construct a ReAct module that accepts an input map with key `:question` and returns a prediction with `:answer`

#### Scenario: Constructing ReAct from a signature module
- **WHEN** the user calls `Dspy.ReAct.new(MySigModule, tools)`
- **THEN** the system SHALL use `MySigModule.signature()` as the base signature

### Requirement: ReAct executes a tool loop using an internal step predictor
The system SHALL implement ReAct as an iterative loop that selects tool calls via an internal `Dspy.Predict` instance over a generated step signature.

#### Scenario: ReAct selects and executes a tool
- **WHEN** `Dspy.ReAct` is called with a question
- **AND WHEN** the step predictor produces `next_tool_name` and `next_tool_args`
- **THEN** the system SHALL execute the referenced tool with those args
- **AND** it SHALL append the tool execution result as an observation into the trajectory

#### Scenario: ReAct stops when the step predictor selects `finish`
- **WHEN** the step predictor returns `next_tool_name == "finish"`
- **THEN** the system SHALL stop iterating the tool loop

#### Scenario: ReAct stops when max steps is reached
- **WHEN** the tool loop reaches `max_steps` iterations
- **THEN** the system SHALL stop iterating even if `finish` was not selected

### Requirement: Step predictor signature includes constrained tool selection and JSON tool args
The system SHALL generate an internal step signature that encodes tool selection constraints and JSON tool arguments.

#### Scenario: Step signature constrains tool names
- **WHEN** `Dspy.ReAct` is constructed with tools `["add", "search"]`
- **THEN** the step signature’s `next_tool_name` output field SHALL constrain allowed values to `{add, search, finish}`

#### Scenario: Step signature requires JSON tool args
- **WHEN** the step predictor is invoked
- **THEN** the prompt instructions for the step signature SHALL require that `next_tool_args` is a valid JSON object

### Requirement: ReAct performs final output extraction from the accumulated trajectory
After the loop terminates, the system SHALL produce the user signature outputs by running an internal extraction module over the accumulated trajectory.

#### Scenario: Extraction produces final signature outputs
- **WHEN** the tool loop terminates
- **THEN** the system SHALL call the extraction module with the original inputs plus `trajectory`
- **AND** it SHALL return a prediction containing the user signature outputs

### Requirement: ReAct participates in adapter-driven prompt formatting and parsing
The system SHALL ensure that ReAct uses the active signature adapter (global and/or per-module override) for internal predictor/extractor prompt output-format instructions and parsing.

#### Scenario: Global adapter affects ReAct internal calls
- **WHEN** the user configures `Dspy.configure(adapter: SomeAdapter)`
- **AND WHEN** the user executes `Dspy.ReAct`
- **THEN** the internal `Predict` and extraction calls SHALL use `SomeAdapter` for prompt output-format instructions and output parsing

#### Scenario: Module override takes precedence over global adapter
- **WHEN** global adapter is configured
- **AND WHEN** `Dspy.ReAct` is constructed with `adapter: OtherAdapter`
- **THEN** the ReAct execution SHALL use `OtherAdapter` for its internal calls

### Requirement: ReAct returns trajectory information
The system SHALL make the accumulated trajectory available to the caller for debugging and evaluation.

#### Scenario: Prediction includes trajectory
- **WHEN** `Dspy.ReAct` returns successfully
- **THEN** the prediction SHALL include a `:trajectory` attribute representing the tool-usage trace

