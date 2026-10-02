# mutation-harness Specification

## ADDED Requirements

### Requirement: Declared expectations decide the verdict
Every mutation SHALL declare the tests it must kill and the reason kind. The harness SHALL report KILLED only when every declared test failed for the declared kind and no test outside the declared and collateral sets failed.

#### Scenario: Killed by the wrong test
- **WHEN** a mutation declares `t_clamp_hi` and only `t_clamp_lo` fails
- **THEN** the verdict SHALL be SURVIVED-TARGET and the run SHALL exit non-zero

#### Scenario: Wrong reason
- **WHEN** a mutation declares `raise:ArgumentError` and its test fails by raising `KeyError`
- **THEN** the verdict SHALL be WRONG-REASON

#### Scenario: Blunt mutation
- **WHEN** a mutation makes tests outside its declared and collateral sets fail
- **THEN** the verdict SHALL be BLUNT

### Requirement: A failure that is not a test failure is never a kill
A run with no completed test report, or a non-zero exit with no failed test recorded, SHALL be INVALID and a hard failure.

#### Scenario: Compile error
- **WHEN** a mutation's replacement text does not compile
- **THEN** the verdict SHALL be INVALID, not KILLED

### Requirement: Every acceptance test is claimed
Every test in the acceptance files SHALL appear in some mutation's expectations or in a printed exemption list; otherwise the run SHALL fail naming it.

#### Scenario: Unclaimed test
- **WHEN** no mutation declares `t_vacuous` and it is not exempt
- **THEN** the run SHALL fail and name `t_vacuous`

### Requirement: The tree is always restored
Mutated files SHALL be byte-equal to their originals after the run, including after SIGTERM, SIGHUP or an exception, and the harness SHALL verify this.

#### Scenario: SIGTERM mid-run
- **WHEN** the harness receives SIGTERM while a mutation is applied
- **THEN** every mutated file SHALL equal its original afterwards

### Requirement: The harness is tested by its own mutations
Each harness mutation listed in the acceptance map SHALL turn its named self-test red.

#### Scenario: Old kill rule reintroduced
- **WHEN** the verdict logic is changed to "killed if any test failed"
- **THEN** the self-test for the wrong-test case SHALL fail
