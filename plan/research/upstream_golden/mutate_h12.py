#!/usr/bin/env python3
"""Exercise the H12 numeric parser with the shared mutation harness.

The shared shape gate, the six public caller/type pairs, and eleven acceptance
branches are tested separately. A compile failure cannot kill a mutation.

Structural preflight catches missing delegation and partial guard injections.
The shared harness also checks complete mutation text and requires a green base
before applying any mutation. The base run is the backstop for debris outside
the recognized source shapes. The shared harness restores byte snapshots on a
normal exit, SIGTERM, or SIGHUP. Run in a scratch copy with its own Mix build.

Usage: python3 plan/research/upstream_golden/mutate_h12.py
"""

import json
import re
import sys
from pathlib import Path
from textwrap import indent

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "plan" / "research" / "harness"))

from mutlib import EXIT_FAIL, Harness, Mutation  # noqa: E402

LIB = ROOT / "lib" / "dspy" / "signature"
TARGET = LIB / "number_parser.ex"
SIG = LIB.with_suffix(".ex")
CHAT = LIB / "adapters" / "chat.ex"
JSON = LIB / "adapters" / "json.ex"

GOLDEN = ROOT / "test" / "signature_h12_golden_fixture_test.exs"
STRICT = ROOT / "test" / "signature_number_integer_strict_test.exs"
TEST_FILES = [
    STRICT,
    GOLDEN,
    ROOT / "test" / "signature_h12_adapter_paths_test.exs",
]

FLOAT_PARITY = "non-deviation float rows: our verdict equals upstream's"
INT_PARITY = "non-deviation int rows: our verdict equals upstream's"
DEVIATIONS = "every deviation row is marked and rejected by us (Horst rulings)"
FIXTURE_SHAPE = "fixture is well-formed: every row has an explicit verdict of a claimed type"
REFERENCE_LITERALS = "reference numeric literals produce the same signed values on both paths"
MALFORMED_LITERALS = "malformed radix separators and quoted parentheses remain rejected"
OVERSIZED_RADIX = "a radix literal outside the float range still parses as an exact integer"
NONFINITE = ("NaN", "nan", "NAN", "inf", "-inf", "INF", "+inf")
BOOLEANS = ("true", "True", "False")
TEST_TITLE = re.compile(r'^    test ("(?:[^"\\]|\\.)*") do$', re.MULTILINE)
INJECTED_GUARD = re.compile(
    r"^  defp do_parse\(raw, :(?:float|int)\) do\n"
    r"    t = String\.trim\(raw\)\n"
    r"    if t (?:==|in) ",
    re.MULTILINE,
)
SHARED_DEBRIS = re.compile(
    r"^  defp strict_shape\?\(_?value\) do\n    true\n  end$", re.MULTILINE
)


def delegated_call(annotation):
    return f"Dspy.Signature.NumberParser.parse_{annotation}(value)"


def detect_leftovers():
    issues = []
    for site in (SIG, CHAT, JSON):
        source = site.read_text()
        for annotation in ("number", "integer"):
            if delegated_call(annotation) not in source:
                issues.append((site, f":{annotation} shared-parser call is missing"))

    source = TARGET.read_text()
    if INJECTED_GUARD.search(source):
        issues.append((TARGET, "injected acceptance guard found in do_parse/2"))
    if SHARED_DEBRIS.search(source):
        issues.append((TARGET, "shared shape check already replaced by true"))
    return issues


def body(source, head):
    pattern = re.compile(rf"^{re.escape(head)}\n(.*?)^  end\n", re.MULTILINE | re.DOTALL)
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        raise ValueError(f"expected one body for {head.strip()}, found {len(matches)}")
    return matches[0].group(0), matches[0].group(1)


def mutation(mutation_id, file, old, new, expect, why, *, also=(), kind="assertion"):
    return Mutation(
        id=mutation_id,
        file=file,
        old=old,
        new=new,
        expect=list(expect),
        also=list(also),
        kind=kind,
        why=why,
    )


def strict_test(annotation, title):
    return f":{annotation} strict parsing {title}"


def ruled_out(annotation, spellings):
    return [strict_test(annotation, f'reject: "{value}" (Horst ruling)') for value in spellings]


def signature_expectations(annotation, parity_test):
    # Null-reverting a call intentionally rejects all previously accepted
    # strings of this annotation. Other failures still count as blunt kills.
    _, tests = body(STRICT.read_text(), f'  describe ":{annotation} strict parsing" do')
    accepts = [json.loads(match) for match in TEST_TITLE.findall(tests)]
    ordinary = {
        "number": 'ordinary case: "0.8" -> 0.8 (float)',
        "integer": 'ordinary case: "1" -> 1 (integer)',
    }
    expected = [strict_test(annotation, ordinary[annotation])]
    collateral = [
        parity_test,
        REFERENCE_LITERALS,
        *(strict_test(annotation, title) for title in accepts if title.startswith("accept:")),
    ]
    if annotation == "integer":
        collateral.append(OVERSIZED_RADIX)
    return expected, collateral


def call_site_mutations():
    for site, label in [(SIG, "signature"), (CHAT, "chat"), (JSON, "json")]:
        for annotation, golden_test in [("number", FLOAT_PARITY), ("integer", INT_PARITY)]:
            call = delegated_call(annotation)
            if site == CHAT:
                branch = (
                    f"defp validate_field_type(value, :{annotation}) when is_binary(value),\n"
                    "    do: "
                )
            else:
                branch = f":{annotation} when is_binary(value) ->\n        "

            if site == SIG:
                expected, collateral = signature_expectations(annotation, golden_test)
                # The ordinary signature tests supply a custom message on their
                # pattern match, so the formatter observes MatchError.
                kind = "raise:MatchError"
            else:
                expected = [f"{label} adapter :{annotation} accepts a strict {annotation}"]
                collateral = []
                kind = "assertion"

            yield mutation(
                f"revert-{label}-{annotation}",
                site,
                branch + call,
                branch + f"{{:error, :invalid_{annotation}}}",
                expected,
                f":{annotation} on the {label} path must use the shared parser",
                also=collateral,
                kind=kind,
            )


def behaviour_mutations(source):
    # Wrap each function body so the injected branch can short-circuit parsing.
    def number(title):
        return strict_test("number", f"reject: {title}")

    # The golden parity tests use `assert pattern = result, message`.
    # Their failed match is reported as MatchError by the shared formatter.
    cases = [
        (
            "M1", "float", 't == "80%"', "{:ok, 80.0}",
            [number('"80%"'), "chat adapter :number rejects a lenient number ('80%')",
             "json adapter :number rejects a lenient number ('80%')"],
            [FLOAT_PARITY],
        ),
        (
            "M2", "float", f"t in {json.dumps(BOOLEANS)}",
            '{:ok, (if t == "False", do: 0.0, else: 1.0)}',
            [DEVIATIONS, *ruled_out("number", BOOLEANS)], [],
        ),
        (
            "M3", "float", f"t in {json.dumps(NONFINITE)}", "{:ok, 0.0}",
            [DEVIATIONS, *ruled_out("number", NONFINITE)], [],
        ),
        ("M4", "float", 't == "0x10G"', "{:ok, 16.0}", [number('"0x10G"')], [FLOAT_PARITY]),
        ("M5", "float", 't == "1,000"', "{:ok, 1000.0}", [number('"1,000"')], [FLOAT_PARITY]),
        (
            "M6", "float", 't == ""', "{:ok, 0.0}",
            [number('"" (empty string)'), number('" " (whitespace only)')], [FLOAT_PARITY],
        ),
        ("M7", "float", 't == "1e"', "{:ok, 1.0}", [FLOAT_PARITY], [number('"1e"')]),
        (
            "M8", "float", 't == "1 000"', "{:ok, 1000.0}",
            [number('"1 000" (interior whitespace)')], [FLOAT_PARITY],
        ),
        (
            "M9a", "int", 't == ",1"', "{:ok, 1}",
            ["chat adapter :integer rejects a lenient integer (',1')",
             "json adapter :integer rejects a lenient integer (',1')"], [INT_PARITY],
        ),
        ("M9b", "int", 't == "1,"', "{:ok, 1}", [INT_PARITY], []),
        (
            "M10", "int", f"t in {json.dumps(NONFINITE)}", "{:ok, 0}",
            ruled_out("integer", NONFINITE), [],
        ),
    ]
    for mutation_id, annotation, guard, result, expected, collateral in cases:
        head = f"  defp do_parse(raw, :{annotation}) do"
        old, content = body(source, head)
        new = (
            f"{head}\n"
            "    t = String.trim(raw)\n"
            f"    if {guard} do\n"
            f"      {result}\n"
            "    else\n"
            f"{indent(content, '  ')}"
            "    end\n"
            "  end\n"
        )
        yield mutation(
            mutation_id,
            TARGET,
            old,
            new,
            expected,
            f":{annotation} rejects {guard}",
            also=collateral,
            kind="raise:MatchError" if mutation_id in ("M7", "M9b") else "assertion",
        )


def build_harness():
    source = TARGET.read_text()
    head = "  defp strict_shape?(value) do"
    old, _ = body(source, head)
    mutations = [
        mutation(
            "shared-shape",
            TARGET,
            old,
            "  defp strict_shape?(_value) do\n    true\n  end\n",
            [
                strict_test(annotation, title)
                for annotation in ("number", "integer")
                for title in ('reject: "_1"', 'reject: "1_"')
            ],
            "bypassing the shared shape check must change both numeric verdicts",
            also=[
                FLOAT_PARITY,
                INT_PARITY,
                MALFORMED_LITERALS,
                *(strict_test(annotation, 'reject: "0x10G"')
                  for annotation in ("number", "integer")),
            ],
        ),
        *call_site_mutations(),
        *behaviour_mutations(source),
    ]
    return Harness(
        mutations=mutations,
        test_files=TEST_FILES,
        # The golden file is the acceptance inventory. The other files cover the
        # public paths and individual values using described test groups.
        acceptance_files=[GOLDEN],
        root=ROOT,
        exempt={FIXTURE_SHAPE: "fixture schema integrity, independent of runtime parsing"},
        report_path=ROOT / "tmp" / "h12-mutation-report.json",
    )


def main():
    issues = detect_leftovers()
    if issues:
        for path, reason in issues:
            print(f"PRE-FLIGHT: {path.relative_to(ROOT)}: {reason}")
        print("Refusing to start with partial mutation source.")
        return EXIT_FAIL

    try:
        harness = build_harness()
    except ValueError as error:
        print(f"PRE-FLIGHT: {error}")
        return EXIT_FAIL
    return harness.run()


if __name__ == "__main__":
    sys.exit(main())
