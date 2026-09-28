# evaluation-result Specification

## ADDED Requirements

### Requirement: Evaluate returns an EvaluationResult struct
`Dspy.Evaluate.evaluate/4` SHALL return `%Dspy.Evaluate.Result{}` containing every existing key unchanged plus `score` (a percentage rounded to 2 places) and `results` (`{example, prediction, score}` tuples aligned with the testset, always populated).

#### Scenario: Percentage score
- **WHEN** 3 of 4 examples score 1.0 and one scores 0.0
- **THEN** `score` SHALL equal `75.0` and `mean` SHALL equal `0.75`

#### Scenario: Rounding
- **WHEN** 2 of 3 examples score 1.0
- **THEN** `score` SHALL equal `66.67`

#### Scenario: Results without return_all
- **WHEN** `return_all` is false
- **THEN** `results` SHALL have one `{example, prediction, score}` tuple per testset example, in testset order

### Requirement: Old access patterns keep working
The struct SHALL implement `Access`, so that `r.mean`, `r[:mean]`, `Map.get(r, :mean)` and `%{mean: m} = r` return the same value as before.

#### Scenario: All access forms
- **WHEN** a caller reads `mean` in each of the four forms
- **THEN** every form SHALL return the same number, and `Access.pop/2` SHALL raise `ArgumentError`

### Requirement: Readable inspect
The struct SHALL inspect as `#Dspy.Evaluate.Result<score: S, results: <N results>>`.

#### Scenario: Inspect
- **WHEN** a result with 4 results and score 75.0 is inspected
- **THEN** the output SHALL be `#Dspy.Evaluate.Result<score: 75.0, results: <list of 4 results>>`

### Requirement: Table display
`:display_table` SHALL log a plain-text table of the result rows: `true` shows all rows, an integer n shows the first n plus a "... k more rows not displayed ..." line; cells longer than 25 words SHALL be truncated to 25 words followed by `...`.

#### Scenario: Truncated table
- **WHEN** `display_table: 2` is used on 4 examples, one of which has a 30-word field
- **THEN** the log SHALL show 2 rows, the line "... 2 more rows not displayed ...", and the long cell cut to 25 words plus `...`

### Requirement: Saving results
`:save_as_json` and `:save_as_csv` SHALL write one row per example: example fields merged with prediction fields (collisions renamed `example_<k>` / `pred_<k>`), plus a column named after the metric holding the score. A failed item SHALL be written as the example fields plus the metric column only (its prediction is an empty `Prediction`, upstream `evaluate.py:181`, `:237`).

#### Scenario: JSON with a key collision
- **WHEN** the example and the prediction both have `answer` and `save_as_json` is given a path
- **THEN** the file SHALL contain `example_answer`, `pred_answer` and the metric column for every row

#### Scenario: CSV with special characters
- **WHEN** a value contains a comma, a quote and a newline and `save_as_csv` is given a path
- **THEN** parsing the file SHALL give back identical rows

### Requirement: Tracebacks on request
With `provide_traceback: true`, an item failure SHALL be logged with the stacktrace captured in the child process.

#### Scenario: Traceback logged
- **WHEN** an item raises and `provide_traceback: true` is set
- **THEN** the log SHALL contain a stacktrace line naming the raising module

### Requirement: No side effects by default
Without output options, Evaluate SHALL NOT write files or log tables.

#### Scenario: Defaults are silent
- **WHEN** Evaluate runs with no output options
- **THEN** no file SHALL be created and no table SHALL be logged

### Requirement: Failed items in results
A failed item SHALL appear in `results` as `{example, %Dspy.Prediction{}, failure_score}` (upstream `evaluate.py:181`), while `predictions` and `items` keep their H0b-2 meaning.

#### Scenario: Raising program
- **WHEN** the program raises for one of 4 examples
- **THEN** that `results` entry SHALL be `{example, %Dspy.Prediction{}, 0.0}` and `score` SHALL count it as 0.0

### Requirement: Average Metric log line
Every evaluation SHALL log `Average Metric: <sum> / <n> (<pct>%)` at info level, with the percentage rounded to 1 place (upstream `evaluate.py:185`).

#### Scenario: Log line
- **WHEN** 3 of 4 examples score 1.0
- **THEN** the log SHALL contain `Average Metric: 3.0 / 4 (75.0%)`
