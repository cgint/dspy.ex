#!/usr/bin/env python3
"""Meta-mutation harness: applies every contract HM (HM1-HM21, row 17 = HM17a+HM17b)
to mutlib.py and verifies each turns its named row red.

The contract (A6) says: "meta_mutate.py applies the harness mutations listed in the acceptance
map to mutlib.py, one at a time. It runs test_mutlib.py for each, and fails unless every harness
mutation turns its named self-test red."

Each HM is a textual mutation of mutlib.py (the library, never the tests) that breaks a
specific verdict or behavior. The named self-test must go RED when the HM is applied.
Row 17's HMs (HM17a/HM17b) are verified by running the named self-test under `python3`
(test_sigterm.py, which drives the real Harness.run() in a subprocess).

Usage: python3 plan/research/harness/meta_mutate.py
"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HARNESS = ROOT / "plan" / "research" / "harness"
MUTLIB = HARNESS / "mutlib.py"
TEST_SIGTERM = HARNESS / "test_sigterm.py"
# HM21 lives in the selftest project's test helper (the G1 line), not in mutlib.py.
SELFTEST_HELPER = HARNESS / "selftest" / "test" / "test_helper.exs"

# (HM id, old text in mutlib.py, new text, named self-test that must go red, description)
HMUTATIONS = [
    (
        "HM1",
        # V7 never reached: always return SURVIVED-TARGET
        '        return "KILLED", f"failed as declared: {m.expect}"',
        '        return "SURVIVED-TARGET", f"never killed (HM1)"',
        "test_row1_normal_kill",
        "V7 never reached (everything reported as SURVIVED) — sanity",
    ),
    (
        "HM2",
        # "killed if any test failed" (the old harness rule)
        '        missing = [t for t in expected if by_name.get(t, _PASSED).state != "failed"]',
        '        missing = []  # HM2: killed if any test failed',
        "test_row2_wrong_test",
        '"killed if any test failed" (the old harness rule)',
    ),
    (
        "HM3",
        # `any` instead of `all` over `expect`: a mutation is killed if ANY one
        # expect test fails, even when another expect test survived.
        # Correct code: killed only if ALL expect tests failed (any survivor -> SURVIVED-TARGET).
        # Mutated: kill if at least one expect failed (ignore survivors).
        '        missing = [t for t in expected if by_name.get(t, _PASSED).state != "failed"]\n        if missing:\n            absent = [t for t in missing if t not in by_name]\n            return "SURVIVED-TARGET", f"expected to fail but did not: {missing}" + (\n                f" (absent from records: {absent})" if absent else ""\n            )',
        '        missing = [t for t in expected if by_name.get(t, _PASSED).state == "failed"]\n        if not missing:  # HM3: any expect failure kills, survivors ignored\n            return "SURVIVED-TARGET", f"no expect test failed"\n        # HM3: at least one expect failed -> proceed to kill (survivors ignored)',
        "test_row3_several_expects_one_missed",
        "`any` instead of `all` over `expect`",
    ),
    (
        "HM4",
        # Non-zero exit counted as a kill: remove the INVALID check for compile errors
        '        if res.enfile or not res.finished or (res.returncode != 0 and not (failed or invalid)):',
        '        if res.enfile or not res.finished:  # HM4: non-zero exit counted as a kill (remove INVALID check)',
        "test_row4_compile_error",
        "non-zero exit counted as a kill",
    ),
    (
        "HM5",
        # Missing suite_finished accepted
        '        if res.enfile or not res.finished or (res.returncode != 0 and not (failed or invalid)):',
        '        if res.enfile:  # HM5: missing suite_finished accepted',
        "test_row4_compile_error",
        "missing suite_finished accepted (stand-in for truncated report)",
    ),
    (
        "HM6",
        # Invalid records ignored
        '        if invalid:',
        '        if False:  # HM6: invalid records ignored',
        "test_row6_setup_all_invalid",
        "`invalid` records ignored",
    ),
    (
        "HM7",
        # V6 check removed: BLUNT verdict never triggered
        # Change the BLUNT check to never trigger
        '        extra = sorted({r.name for r in failed if r.name not in declared})\n        if extra:\n            return "BLUNT", f"unexpected failures outside expect+also: {extra}"',
        '        extra = sorted({r.name for r in failed if r.name not in declared})\n        if False:  # HM7: V6 check removed\n            return "BLUNT", f"unexpected failures outside expect+also: {extra}"',
        "test_row7_blunt",
        "V6 check removed",
    ),
    (
        "HM8",
        # Also ignored: collateral tests not declared
        '        declared = set(expected) | {_full(t) for t in m.also}',
        '        declared = set(expected)  # HM8: also ignored (collateral not declared)',
        "test_row8_also",
        "`also` ignored",
    ),
    (
        "HM9",
        # Kind check removed
        '        bad = [(t, by_name[t].error) for t in expected\n               if not _kind_matches(m.kind, by_name[t])]',
        '        bad = []  # HM9: kind check removed',
        "test_row9_wrong_reason",
        "`kind` check removed",
    ),
    (
        "HM10",
        # Assertion matched against the wrong struct name
        'def _assertion_error(error):\n    # HM10: `assertion` matched against the wrong struct name.\n    return error in ("Elixir.ExUnit.AssertionError", "ExUnit.AssertionError")',
        'def _assertion_error(error):\n    # HM10: `assertion` matched against the wrong struct name.\n    return error in ("Elixir.WrongAssertionError", "WrongAssertionError")',
        "test_row10_assertion_kind",
        "`assertion` matched against the wrong struct name",
    ),
    (
        "HM11a",
        # NOT-APPLICABLE counted as skipped: remove the pre-flight check for 0 occurrences
        '            if n == 0:\n                issues.append(f"{m.id}: `old` text not found in {m.file.name}")',
        '            if False:  # HM11a: NOT-APPLICABLE counted as skipped\n                pass',
        "test_row11_not_applicable_and_ambiguous",
        "NOT-APPLICABLE counted as skipped",
    ),
    (
        "HM11b",
        # The pre-flight `n > 1` (AMBIGUOUS) check is lost: an ambiguous anchor
        # (old occurs 2x) passes pre-flight and the first occurrence is used
        # silently. Row 11b asserts the AMBIGUOUS verdict path (a pre-flight
        # rejection, like 11a), which this break makes impossible -> red.
        "def _ambiguous_count(n):\n    # HM11b: the pre-flight `n > 1` (AMBIGUOUS) check is lost.\n    return n > 1",
        "def _ambiguous_count(n):\n    # HM11b: the pre-flight `n > 1` (AMBIGUOUS) check is lost.\n    return False",
        "test_row11_not_applicable_and_ambiguous",
        "pre-flight n > 1 check removed: ambiguous anchor used silently",
    ),
    (
        "HM12",
        # An absent test counted as "not passed" and therefore killed
        '        missing = [t for t in expected if by_name.get(t, _PASSED).state != "failed"]',
        '        missing = [t for t in expected if t in by_name and by_name[t].state != "failed"]  # HM12: absent = killed',
        "test_row12_absent_test",
        "an absent test counted as 'not passed' and therefore killed",
    ),
    (
        "HM13a",
        # Coverage check removed
        '        unclaimed = []\n        for path in self.acceptance_files:',
        '        unclaimed = []  # HM13a: coverage check removed\n        for path in []:',
        "test_row13_unclaimed_and_exempt",
        "coverage check removed",
    ),
    (
        "HM13b",
        # Exempt not printed
        'def _print_exempt(exempt):\n    # HM13b: `exempt` not printed.\n    if exempt:',
        'def _print_exempt(exempt):\n    # HM13b: `exempt` not printed.\n    if False:',
        "test_row13_unclaimed_and_exempt",
        "`exempt` not printed",
    ),
    (
        "HM15",
        # Base-green check skipped
        '    def base_run(self):\n        if not self.base_green:\n            return None',
        '    def base_run(self):\n        if True:  # HM15: base-green check skipped\n            return None',
        "test_row15_base_red",
        "base-green check skipped",
    ),
    (
        "HM16",
        # Pre-flight removed
        '    def preflight(self):\n        issues = []\n        for m in self.mutations:',
        '    def preflight(self):\n        return []  # HM16: pre-flight removed\n        for m in self.mutations:',
        "test_row16_debris",
        "pre-flight removed",
    ),
    (
        "HM17a",
        # SIGTERM handler line replaced by `pass`: the OS kills the process
        # (exit -15) instead of SystemExit, and the finally-restore never runs.
        '        signal.signal(signal.SIGTERM, on_signal)',
        '        pass  # HM17a: SIGTERM handler line replaced by pass',
        "test_sigterm",
        "SIGTERM `signal.signal` line replaced by `pass`",
    ),
    (
        "HM17b",
        # SIGHUP handler line replaced by `pass`: the OS kills the process
        # (exit -1) instead of SystemExit, and the finally-restore never runs.
        '        signal.signal(signal.SIGHUP, on_signal)',
        '        pass  # HM17b: SIGHUP handler line replaced by pass',
        "test_sigterm",
        "SIGHUP `signal.signal` line replaced by `pass`",
    ),
    (
        "HM18",
        # Restore moved out of finally: the single finally-block restore is
        # removed, so a SystemExit (SIGTERM/SIGHUP) leaves the tree mutated.
        '        finally:\n            # Single source of truth for the restore guarantee: no matter how\n            # run() exits (normal return, SystemExit, MutlibError, or any\n            # other exception) the source files are put back byte-for-byte.\n            # Removing this line (HM18) makes a signal/exception leave the\n            # tree mutated, which the row-18 self-test catches.\n            self.restore()',
        '        finally:\n            pass  # HM18: restore moved out of finally',
        "test_row18_exception_restores",
        "restore moved out of finally",
    ),
    (
        "HM19",
        # Post-run comparison removed: the after-success verify_restore() call
        # (the one that runs after all mutations and before the exception
        # handlers) is removed, so a silently-wrong restore is not caught.
        '            self.verify_restore()\n        except SystemExit as e:',
        '            pass  # HM19: post-run verify_restore removed\n        except SystemExit as e:',
        "test_row19_sabotaged_restore",
        "post-run comparison removed",
    ),
    (
        "HM20",
        # Exit 0 while an INVALID exists
        '            and all(vd.verdict == "KILLED" for vd in self.verdicts)',
        '            and all(vd.verdict in ("KILLED", "INVALID") for vd in self.verdicts)  # HM20: exit 0 while INVALID exists',
        "test_row20_reconciliation",
        "exit 0 while an INVALID exists",
    ),
    (
        "HM21",
        # Formatter added unconditionally: the G1 conditional line in the
        # selftest project's test/test_helper.exs becomes a plain `do` block,
        # so the formatter is added even when DSPY_MUT_REPORT is unset. Row 21
        # runs the selftest suite with the variable unset and asserts the
        # exact default output -> red (output doubled).
        # NOTE: this HM targets selftest/test/test_helper.exs, not mutlib.py.
        'if System.get_env("DSPY_MUT_REPORT") do\n  Code.require_file("#{Path.expand("../..", __DIR__)}/mut_formatter.exs", __DIR__)\n  ExUnit.configure(formatters: [ExUnit.CLIFormatter, MutFormatter])\nend',
        'do\n  Code.require_file("#{Path.expand("../..", __DIR__)}/mut_formatter.exs", __DIR__)\n  ExUnit.configure(formatters: [ExUnit.CLIFormatter, MutFormatter])\nend',
        "test_row21_formatter_off",
        "formatter added unconditionally (G1 line)",
    ),
]


def run_selftest(test_name, desc=""):
    """Run the named self-test and return (passed: bool, output: str).

    Most HMs are caught by a single test in test_mutlib.py; the row-17 HMs
    are caught by test_sigterm.py, which runs the signal round for the
    specific handler the HM removed.
    """
    if test_name == "test_sigterm":
        # Row 17 HMs: run the self-test round for the specific handler.
        round_name = "test_sigterm" if "SIGTERM" in desc else "test_sighup"
        cmd = [sys.executable, "-m", "unittest",
               f"test_sigterm.TestSigterm.{round_name}", "-v"]
    else:
        cmd = [sys.executable, "-m", "unittest", f"test_mutlib.TestVerdicts.{test_name}", "-v"]
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=str(HARNESS))
    output = result.stdout + result.stderr
    passed = result.returncode == 0
    return passed, output


def main():
    original = MUTLIB.read_text()
    original_helper = SELFTEST_HELPER.read_text()
    print(f"Meta-mutation harness: {len(HMUTATIONS)} HMs defined")
    print(f"Library: {MUTLIB}")
    print(f"Self-tests: {TEST_SIGTERM.name} (row 17), test_mutlib.py (rows 1-21)\n")

    results = []
    for entry in HMUTATIONS:
        hm_id, old, new, test_name, desc = entry

        # HM21 mutates the selftest project's test helper (the G1 line), not
        # the library; every other HM mutates mutlib.py.
        target = SELFTEST_HELPER if hm_id == "HM21" else MUTLIB
        original_text = original_helper if hm_id == "HM21" else original

        # Verify the old text exists
        if old not in original_text:
            print(f"SKIP: {hm_id} — old text not found in {target.name}")
            results.append((hm_id, "SKIP", desc))
            continue

        # Apply the HM
        target.write_text(original_text.replace(old, new, 1))
        print(f"APPLIED: {hm_id} ({desc}) [in {target.name}]")

        # Run the named self-test
        passed, output = run_selftest(test_name, desc)
        if not passed:
            results.append((hm_id, "RED", desc))
            print(f"  RED: {hm_id} — {test_name} is red as expected")
        else:
            results.append((hm_id, "GREEN", desc))
            print(f"  GREEN: {hm_id} — {test_name} still green (HM did NOT break it)")
            print(f"  Output: {output[-500:]}")

        # Restore
        target.write_text(original_text)

    # Verify both files are restored
    if MUTLIB.read_text() != original:
        print("\nHARD FAILURE: mutlib.py was not restored after the meta-run")
        sys.exit(1)
    if SELFTEST_HELPER.read_text() != original_helper:
        print("\nHARD FAILURE: selftest/test/test_helper.exs was not restored after the meta-run")
        sys.exit(1)

    print(f"\n{'=' * 64}\nMETA-MUTATION REPORT\n{'=' * 64}")
    red = sum(1 for _, status, _ in results if status == "RED")
    green = sum(1 for _, status, _ in results if status == "GREEN")
    skip = sum(1 for _, status, _ in results if status == "SKIP")
    print(f"HMs defined:    {len(HMUTATIONS)}")
    print(f"RED (broken):   {red}")
    print(f"GREEN (not):    {green}")
    print(f"SKIP (no text): {skip}")

    # Acceptance bar: EVERY contract HM must turn its named row red, and no
    # HM may be SKIPped. There is no uncatchable category (B2).
    if green > 0 or skip > 0:
        print("\nHARD FAILURE: an HM did not break its named self-test,")
        print("or an HM could not be applied (SKIP). This is a real gap.")
        sys.exit(1)

    print(f"\nALL CLEAR: {red}/{len(HMUTATIONS)} HMs turned their named row red.")
    sys.exit(0)


if __name__ == "__main__":
    main()
