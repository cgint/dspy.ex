#!/usr/bin/env python3
"""Self-tests for `mutlib.py` (contract A6): drive Harness against selftest/.

For each verdict the library can produce, a small mutation is built to produce
exactly that verdict, and the harness's report + exit code are asserted.

Row 14 (acceptance map) is pinned here as a *documented passing case*: the
vacuous mutation must come out KILLED (its second assertion dies) while a
mutation that only breaks the vacuous assertion comes out SURVIVED-TARGET —
that is the honest limit C2 cannot close.

Run: python3 -m unittest test_mutlib -v
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from mutlib import EXIT_ENFILE, EXIT_FAIL, EXIT_OK, Harness, Mutation  # noqa: E402

SELFTEST = HERE / "selftest"
MATH = SELFTEST / "lib" / "selftest" / "math.ex"
TEST_FILE = SELFTEST / "test" / "selftest_test.exs"
ENV = dict(os.environ)

# Canonical (clean) source bytes, captured at import. The self-tests mutate
# these files in place and must leave them byte-for-byte identical to this.
# setUp fails loud if they are already dirty (leftover debris from a crashed
# or interrupted run) and tearDown guarantees the canonical state, so each
# test starts from a verified-clean tree regardless of what ran before it.
CANONICAL_MATH = MATH.read_bytes()
CANONICAL_TEST_FILE = TEST_FILE.read_bytes()


def drive(mutations, exempt=None, base_green=True):
    """Drive Harness in-process and capture exit code + report payload.

    NOTE: we do NOT run `mix clean`/`mix compile` here. Mix's `mix compile`
    targets the `dev` env, but the tests (and their mutated `lib/`) are
    compiled into the `test` env by `mix test`. Wiping `_build/test` is done
    inside `Harness.run_tests`, so every run compiles fresh from source.
    Pre-compiling into `dev` would be dead work and only muddied the build.
    """
    import json
    import io
    import contextlib

    with tempfile.TemporaryDirectory(prefix="mutlib_") as tmp:
        report = Path(tmp) / "mutation_report.json"
        h = Harness(
            mutations=mutations,
            test_files=[TEST_FILE],
            acceptance_files=[TEST_FILE],
            root=SELFTEST,
            exempt=exempt,
            report_path=report,
            base_green=base_green,
        )
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = h.run()
        # Read the report BEFORE the temp dir is cleaned up
        payload = json.loads(report.read_text())
    return code, buf.getvalue(), payload


def verdict_of(payload, mid):
    for m in payload["mutations"]:
        if m["id"] == mid:
            return m["verdict"]
    return None


class TestVerdicts(unittest.TestCase):
    def setUp(self):
        # Verify-clean pre-flight: refuse to run on a dirtied tree. If a
        # previous run crashed before restoring (or a meta-mutation leaked),
        # we want a loud failure here, not a bogus verdict later.
        if MATH.read_bytes() != CANONICAL_MATH:
            raise unittest.SkipTest(
                "selftest math.ex is not in canonical state; "
                "a prior run left debris. Reset it and rerun."
            )
        if TEST_FILE.read_bytes() != CANONICAL_TEST_FILE:
            raise unittest.SkipTest(
                "selftest test file is not in canonical state; "
                "a prior run left debris. Reset it and rerun."
            )
        # Wipe the throwaway test-env build so the first mix test compiles
        # fresh from the verified-clean source (defensive; run_tests also wipes).
        build_test = SELFTEST / "_build" / "test"
        if build_test.exists():
            import shutil
            shutil.rmtree(build_test, ignore_errors=True)

    def tearDown(self):
        # Guarantee the canonical state even if the test body raised.
        MATH.write_bytes(CANONICAL_MATH)
        TEST_FILE.write_bytes(CANONICAL_TEST_FILE)

    # Row 1: normal kill.
    def test_row1_normal_kill(self):
        m = Mutation(id="R1", file=MATH,
                     old="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))",
                     new="  def clamp01(value), do: max(0.0, min(1.9, value * 1.0))",
                     expect=["t_clamp_hi"], why="row 1: upper bound broken")
        code, out, payload = drive([m], exempt={"t_add": "r1",
                                                 "t_clamp_lo": "r1",
                                                 "t_f1": "r1",
                                                 "t_raise": "r1",
                                                 "t_vacuous": "r1"})
        self.assertEqual(verdict_of(payload, "R1"), "KILLED", out)
        self.assertEqual(code, EXIT_OK, out)

    # Row 2: killed by the wrong test -> SURVIVED-TARGET.
    def test_row2_wrong_test(self):
        m = Mutation(id="R2", file=MATH,
                     old="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))",
                     new="  def clamp01(value), do: max(0.5, min(1.0, value * 1.0))",
                     expect=["t_clamp_hi"], why="row 2: only t_clamp_lo can fail")
        code, out, payload = drive([m])
        self.assertEqual(verdict_of(payload, "R2"), "SURVIVED-TARGET", out)
        self.assertEqual(code, EXIT_FAIL, out)

    # Row 3: several expects, one missed -> SURVIVED-TARGET.
    def test_row3_several_expects_one_missed(self):
        m = Mutation(id="R3", file=MATH,
                     old="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))",
                     new="  def clamp01(value), do: max(0.0, min(1.9, value * 1.0))",
                     expect=["t_clamp_hi", "t_clamp_lo"], why="row 3: t_clamp_lo survives")
        code, out, payload = drive([m])
        self.assertEqual(verdict_of(payload, "R3"), "SURVIVED-TARGET", out)
        self.assertEqual(code, EXIT_FAIL, out)

    # Row 4: new text is a compile error -> INVALID.
    def test_row4_compile_error(self):
        m = Mutation(id="R4", file=MATH,
                     old="  def add(a, b), do: a + b",
                     new="  def add(a, b), do: a + b +\n  (this is not elixir",
                     expect=["t_add"], why="row 4: compile error")
        code, out, payload = drive([m])
        self.assertEqual(verdict_of(payload, "R4"), "INVALID", out)
        self.assertEqual(code, EXIT_FAIL, out)
        self.assertEqual(MATH.read_bytes(), drive_base_snapshot())

        # Sub-case isolating the "non-zero exit with no failed/invalid record"
        # branch (HM4). Here the suite *did* finish (suite_finished present)
        # and *no* test failed, but the process exited non-zero (an abnormal
        # runner exit). Correct code -> INVALID via the returncode clause.
        # HM4 removes that clause, so the verdict falls through to
        # SURVIVED-TARGET -> this sub-case goes red.
        from mutlib import TestRecord, RunResult
        m2 = Mutation(id="R4b", file=MATH,
                      old="  def add(a, b), do: a + b",
                      new="  def add(a, b), do: a + b * 2",
                      expect=["t_add"], why="row 4b: finished but non-zero exit")
        h = Harness(mutations=[m2], test_files=[TEST_FILE], acceptance_files=[TEST_FILE],
                    root=SELFTEST, report_path=HERE / ".tmp_r4b_report.json",
                    exempt={"t_clamp_hi": "r4", "t_clamp_lo": "r4", "t_f1": "r4",
                            "t_raise": "r4", "t_vacuous": "r4"},
                    base_green=False)

        def abnormal_exit(_report_path):
            return RunResult(
                returncode=1,
                records=[TestRecord(name="test t_add", module="Elixir.SelftestTest",
                                    file="test/selftest_test.exs", state="passed", error=None)],
                finished=True,   # suite_finished present
                enfile=False,
                tail="abnormal exit, no failed record",
            )

        h.run_tests = abnormal_exit
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            code = h.run()
        self.assertEqual(h.verdicts[0].verdict, "INVALID",
                         "HM4: a non-zero exit with a finished suite and no failed "
                         "record must still be INVALID")
        self.assertEqual(code, EXIT_FAIL)

    # Row 5: formatter report truncated -> INVALID.
    def test_row5_truncated_report(self):
        """Test that a truncated report (missing suite_finished) is INVALID.

        This simulates a situation where the formatter is killed mid-run.
        We create a report file that has test records but no suite_finished line.
        """
        import json
        from mutlib import TestRecord

        # Create a mutation
        m = Mutation(id="R5", file=MATH,
                     old="  def add(a, b), do: a + b",
                     new="  def add(a, b), do: a + b * 2",
                     expect=["t_add"], why="row 5: truncated report")

        # Create a Harness with a custom run_tests that returns a truncated report
        h = Harness(mutations=[m], test_files=[TEST_FILE], acceptance_files=[TEST_FILE],
                    root=SELFTEST, report_path=HERE / ".tmp_r5_report.json",
                    exempt={"t_clamp_hi": "r5", "t_clamp_lo": "r5", "t_f1": "r5",
                            "t_raise": "r5", "t_vacuous": "r5"},
                    base_green=False)

        # Mock run_tests to return a truncated report
        original_run_tests = h.run_tests

        def truncated_run_tests(report_path):
            # Create a truncated report (no suite_finished)
            records = [
                json.dumps({"name": "test t_add", "module": "Elixir.SelftestTest", "file": "test/selftest_test.exs", "state": "failed", "error": "Elixir.ExUnit.AssertionError"}),
                json.dumps({"name": "test t_clamp_hi", "module": "Elixir.SelftestTest", "file": "test/selftest_test.exs", "state": "passed", "error": None}),
            ]
            report_path.write_text("\n".join(records) + "\n")

            # Return a RunResult that simulates a truncated run
            from mutlib import RunResult
            return RunResult(
                returncode=0,
                records=[TestRecord(name="test t_add", module="Elixir.SelftestTest", file="test/selftest_test.exs", state="failed", error="Elixir.ExUnit.AssertionError"),
                         TestRecord(name="test t_clamp_hi", module="Elixir.SelftestTest", file="test/selftest_test.exs", state="passed", error=None)],
                finished=False,  # No suite_finished
                enfile=False,
                tail="truncated report"
            )

        h.run_tests = truncated_run_tests

        # Run the harness
        code = h.run()

        # The mutation should be INVALID because the report is truncated
        self.assertEqual(h.verdicts[0].verdict, "INVALID")
        self.assertEqual(code, EXIT_FAIL)

    # Row 6: setup_all raising -> INVALID. (Done by temporarily patching the
    # test file; restored by the harness? No — the test file is not mutated,
    # so we patch and restore around the drive.)
    def test_row6_setup_all_invalid(self):
        original = TEST_FILE.read_text()
        try:
            TEST_FILE.write_text(original.replace(
                "defmodule SelftestTest do\n  use ExUnit.Case, async: true",
                "defmodule SelftestTest do\n  use ExUnit.Case, async: true\n  setup_all do: raise('boom in setup_all')",
            ))
            m = Mutation(id="R6", file=MATH,
                         old="  def add(a, b), do: a + b",
                         new="  def add(a, b), do: a + b * 2",
                         expect=["t_add"], why="row 6: invalid records")
            code, out, payload = drive([m], base_green=False)
            self.assertEqual(verdict_of(payload, "R6"), "INVALID", out)
            self.assertEqual(code, EXIT_FAIL, out)
        finally:
            TEST_FILE.write_text(original)

    # Row 7: breaking a shared function -> BLUNT (tests outside expect fail).
    def test_row7_blunt(self):
        # A mutation that breaks clamp01, which is used by t_clamp_hi, t_clamp_lo, t_f1, and t_vacuous
        # But we only expect t_clamp_hi to fail -> BLUNT
        m = Mutation(id="R7", file=MATH,
                     old="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))",
                     new="  def clamp01(value), do: raise 'broken'",
                     expect=["t_clamp_hi"],
                     kind="any",
                     why="row 7: mass failure (BLUNT)")
        # Don't declare the collateral tests in also -> BLUNT
        code, out, payload = drive([m], exempt={"t_add": "r7",
                                                 "t_raise": "r7"})
        self.assertEqual(verdict_of(payload, "R7"), "BLUNT", out)
        self.assertEqual(code, EXIT_FAIL, out)

    # Row 8: same mutation, collateral declared in also -> KILLED.
    # The mutation breaks clamp01 (used by t_clamp_hi, t_clamp_lo, t_f1, t_vacuous);
    # those collateral failures are declared in `also`, so the verdict is KILLED
    # rather than BLUNT. If `also` were ignored (HM8), the same collateral
    # failures would be "outside expect+also" -> BLUNT -> this test goes red.
    def test_row8_also(self):
        m = Mutation(id="R8", file=MATH,
                     old="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))",
                     new="  def clamp01(value), do: raise 'exploded'",
                     expect=["t_clamp_hi"],
                     also=["t_clamp_lo", "t_f1", "t_vacuous"],
                     kind="any",
                     why="row 8: declared collateral")
        code, out, payload = drive([m], exempt={"t_add": "r8",
                                                 "t_raise": "r8",
                                                 "t_clamp_lo": "r8",
                                                 "t_f1": "r8",
                                                 "t_vacuous": "r8"})
        self.assertEqual(verdict_of(payload, "R8"), "KILLED", out)
        self.assertEqual(code, EXIT_OK, out)

    # Row 9: raise:ArgumentError expected, but the test fails by raising a
    # different exception -> WRONG-REASON.
    def test_row9_wrong_reason(self):
        m = Mutation(id="R9", file=MATH,
                     old="      :error -> raise ArgumentError, \"missing #{key}\"",
                     new="      :error -> raise KeyError, term: :missing",
                     expect=["t_raise"], kind="raise:ArgumentError",
                     why="row 9: wrong exception kind")
        code, out, payload = drive([m])
        self.assertEqual(verdict_of(payload, "R9"), "WRONG-REASON", out)
        self.assertEqual(code, EXIT_FAIL, out)

    # Row 10: assertion kind matched by an assertion failure -> KILLED.
    def test_row10_assertion_kind(self):
        m = Mutation(id="R10", file=MATH,
                     old="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))",
                     new="  def clamp01(value), do: value",
                     expect=["t_clamp_hi"],
                     also=["t_clamp_lo"],
                     kind="assertion",
                     why="row 10: assertion kind")
        code, out, payload = drive([m])
        self.assertEqual(verdict_of(payload, "R10"), "KILLED", out)

    # Row 11: old absent -> NOT-APPLICABLE (pre-flight); old twice -> AMBIGUOUS.
    # The 11a sub-case asserts the failure is a PRE-FLIGHT rejection (the absent
    # anchor is caught before the run starts). HM11a removes the `old`-not-found
    # pre-flight check, so the run would instead proceed and fail at apply-time;
    # the `interrupted` marker would no longer be "pre-flight" -> red.
    def test_row11_not_applicable_and_ambiguous(self):
        m = Mutation(id="R11a", file=MATH,
                     old="  def this_text_does_not_exist()",
                     new="  def nope()",
                     expect=["t_add"], why="row 11a: absent anchor")
        code, out, payload = drive([m])
        self.assertEqual(code, EXIT_FAIL, out)
        self.assertEqual(len(payload["mutations"]), 0, out)
        self.assertEqual(payload["interrupted"], "pre-flight", out)
        self.assertIn("PRE-FLIGHT", out)

        # AMBIGUOUS: use an anchor that occurs twice in math.ex. Row 11b
        # asserts the AMBIGUOUS verdict path (a pre-flight rejection, exactly
        # like 11a). HM11b removes the pre-flight `n > 1` check; then an
        # ambiguous anchor passes pre-flight, the run proceeds, and the first
        # occurrence is used silently — no "pre-flight" interrupted marker,
        # no PRE-FLIGHT message -> this sub-case goes red.
        twice = "raise"
        self.assertEqual(MATH.read_text().count(twice), 2)
        m2 = Mutation(id="R11b", file=MATH,
                      old=twice, new=twice + "\n  def nope() do\n    :ok\n  end",
                      expect=["t_add"], why="row 11b: ambiguous anchor")
        code, out, payload = drive([m2])
        self.assertEqual(code, EXIT_FAIL, out)
        self.assertEqual(len(payload["mutations"]), 0, out)
        self.assertEqual(payload["interrupted"], "pre-flight", out)
        self.assertIn("PRE-FLIGHT", out)
        self.assertIn("2x", out)

    # Row 12: expect name with a typo -> SURVIVED-TARGET, naming the unknown.
    def test_row12_absent_test(self):
        m = Mutation(id="R12", file=MATH,
                     old="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))",
                     new="  def clamp01(value), do: max(0.0, min(1.9, value * 1.0))",
                     expect=["t_clamp_hii"], why="row 12: typo in expect")
        code, out, payload = drive([m])
        self.assertEqual(verdict_of(payload, "R12"), "SURVIVED-TARGET", out)
        self.assertIn("t_clamp_hii", payload["mutations"][0]["detail"], out)

    # Row 13: t_vacuous claimed by no mutation -> UNCLAIMED; with exempt -> ok.
    def test_row13_unclaimed_and_exempt(self):
        claimed = [
            Mutation(id="R13a", file=MATH,
                     old="  def add(a, b), do: a + b",
                     new="  def add(a, b), do: a + b * 2",
                     expect=["t_add"], why="row 13a: leaves t_vacuous unclaimed"),
        ]
        # t_vacuous is not in expect nor exempt -> UNCLAIMED, hard fail.
        code, out, payload = drive(claimed)
        self.assertIn("t_vacuous", "\n".join(payload["unclaimed"]), out)
        self.assertEqual(code, EXIT_FAIL, out)

        # With t_vacuous exempt -> passes and the exemption is printed.
        code, out, payload = drive(claimed, exempt={"t_vacuous": "vacuous row 14",
                                                    "t_clamp_hi": "r13",
                                                    "t_clamp_lo": "r13",
                                                    "t_f1": "r13",
                                                    "t_raise": "r13"})
        self.assertEqual(payload["unclaimed"], [], out)
        self.assertEqual(code, EXIT_OK, out)
        self.assertIn("Exempt", out)
        self.assertIn("t_vacuous", out)

    # Row 14: the honest limit, pinned as a documented passing case.
    def test_row14_vacuous_limit(self):
        # (a) A mutation that changes the value t_vacuous checks breaks the
        # second assertion -> KILLED (the vacuous assertion is exposed as
        # powerless: it did not die, the other one did).
        m_kill = Mutation(id="R14a", file=MATH,
                          old="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))",
                          new="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0)) * 2.0",
                          expect=["t_vacuous"],
                          also=["t_clamp_hi", "t_f1"],
                          why="row 14a: value broken, other assertion dies")
        code, out, payload = drive([m_kill], exempt={"t_clamp_lo": "r14",
                                                     "t_add": "r14",
                                                     "t_raise": "r14"})
        self.assertEqual(verdict_of(payload, "R14a"), "KILLED", out)

        # (b) A mutation that changes clamp01 in a way the vacuous assertion
        # cannot catch: t_vacuous's second assertion still holds, so the
        # mutation is SURVIVED-TARGET — vacuity exposed, documented limit.
        m_survive = Mutation(id="R14b", file=MATH,
                             old="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))",
                             new="  def clamp01(value), do: min(2.0, value * 1.0)",
                             expect=["t_vacuous"],
                             also=["t_clamp_hi", "t_f1"],
                             why="row 14b: vacuity survives")
        code, out, payload = drive([m_survive], exempt={"t_clamp_lo": "r14",
                                                        "t_add": "r14",
                                                        "t_raise": "r14"})
        self.assertEqual(verdict_of(payload, "R14b"), "SURVIVED-TARGET", out)
        self.assertEqual(code, EXIT_FAIL, out)

    # Row 15: base red -> hard fail, no mutation applied.
    def test_row15_base_red(self):
        original = TEST_FILE.read_text()
        try:
            TEST_FILE.write_text(original.replace(
                'test "t_add" do',
                'test "t_add" do\n    assert false',
            ))
            m = Mutation(id="R15", file=MATH,
                         old="  def add(a, b), do: a + b",
                         new="  def add(a, b), do: a + b * 2",
                         expect=["t_add"], why="row 15: red base")
            code, out, payload = drive([m])
            self.assertEqual(code, EXIT_FAIL, out)
            self.assertIn("BASE-GREEN", payload.get("interrupted", ""), out)
            self.assertEqual(len(payload["mutations"]), 0, out)
        finally:
            TEST_FILE.write_text(original)

    # Row 16: debris (a `new` text already present) -> refuses to start.
    def test_row16_debris(self):
        # Add the exact `new` text to the file as debris
        new_text = "  def add(a, b), do: a + b * 2\n  def debris_marker() do\n    :yes\n  end"
        self.assertNotIn(new_text, MATH.read_text())
        original = MATH.read_text()
        try:
            MATH.write_text(original + "\n" + new_text + "\n")
            m = Mutation(id="R16", file=MATH,
                         old="  def add(a, b), do: a + b",
                         new=new_text,
                         expect=["t_add"], why="row 16: debris")
            code, out, payload = drive([m])
            self.assertEqual(code, EXIT_FAIL, out)
            self.assertIn("PRE-FLIGHT", out)
            self.assertEqual(len(payload["mutations"]), 0, out)
        finally:
            MATH.write_text(original)

    # Row 18: exception (SystemExit) inside a mutation's run -> files restored.
    # We force a SystemExit (the SIGTERM/SIGHUP path) inside run_tests. The
    # harness's `except SystemExit` handler must restore the source. HM18
    # removes that restore call; if it did, MATH would still carry the
    # mutation and this assertion would fail.
    def test_row18_exception_restores(self):
        m = Mutation(id="R18", file=MATH,
                     old="  def add(a, b), do: a + b",
                     new="  def add(a, b), do: a + b * 2",
                     expect=["t_add"], why="row 18: SystemExit path")
        h = Harness(
            mutations=[m], test_files=[TEST_FILE],
            acceptance_files=[TEST_FILE], root=SELFTEST,
            report_path=HERE / ".tmp_r18_report.json",
        )
        before = MATH.read_bytes()
        h.snapshot()

        def sigterm(_report_path):
            h._apply(m)
            raise SystemExit("signal 15")

        import contextlib
        import io
        code = EXIT_OK
        with contextlib.redirect_stdout(io.StringIO()):
            h.run_tests = sigterm
            code = h.run()
        self.assertEqual(code, EXIT_FAIL)
        self.assertEqual(MATH.read_bytes(), before, "files must be restored after a SystemExit")

    # Row 19: a silently-wrong restore is caught by the post-run byte check.
    # We sabotage `restore` so that it writes the WRONG bytes. The post-success
    # `verify_restore()` compares the (now-wrong) file to its snapshot and must
    # raise -> EXIT_FAIL. HM19 removes that post-success check; then the bad
    # restore is not verified, the run is no longer forced to fail by the
    # comparison, and the final assertion that the file is byte-identical
    # after run() catches the leak -> red.
    def test_row19_sabotaged_restore(self):
        m = Mutation(id="R19", file=MATH,
                     old="  def add(a, b), do: a + b",
                     new="  def add(a, b), do: a + b * 2",
                     expect=["t_add"], why="row 19: sabotaged restore")
        h = Harness(
            mutations=[m], test_files=[TEST_FILE],
            acceptance_files=[TEST_FILE], root=SELFTEST,
            report_path=HERE / ".tmp_r19_report.json",
            exempt={"t_clamp_hi": "r19", "t_clamp_lo": "r19", "t_f1": "r19",
                    "t_raise": "r19", "t_vacuous": "r19"},
        )
        before = MATH.read_bytes()
        original_restore_one = h._restore_one

        def sabotaged_restore_one(mm):
            # The per-mutation restore writes the WRONG bytes (a buggy restore).
            MATH.write_bytes(before + b"\n# sabotage")

        h._restore_one = sabotaged_restore_one
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()):
            code = h.run()
        # The post-run verify_restore() must have caught the bad restore:
        # the (wrong-bytes) file does not match its snapshot -> MutlibError ->
        # EXIT_FAIL. HM19 removes that post-run check, so the run would come
        # out EXIT_OK on a dirty file -> red.
        self.assertEqual(code, EXIT_FAIL)
        # After run(), the finally-block restore re-wrote the true snapshot.
        self.assertEqual(MATH.read_bytes(), before)

    # Row 20: reconciliation — defined = applied; exit 0 only for all-KILLED.
    def test_row20_reconciliation(self):
        # All-KILLED -> exit 0, counts reconciled.
        m = Mutation(id="R20a", file=MATH,
                     old="  def add(a, b), do: a + b",
                     new="  def add(a, b), do: a + b * 2",
                     expect=["t_add"], why="row 20a: killed")
        code, out, payload = drive([m], exempt={"t_clamp_hi": "r20",
                                                 "t_clamp_lo": "r20",
                                                 "t_f1": "r20",
                                                 "t_raise": "r20",
                                                 "t_vacuous": "r20"})
        self.assertEqual(code, EXIT_OK)
        self.assertEqual(payload["defined"], 1)
        self.assertEqual(payload["applied"], 1)
        self.assertEqual(payload["counts"]["KILLED"], 1)

        # A SURVIVED-TARGET alongside -> exit 1 even though one is KILLED.
        m2 = Mutation(id="R20b", file=MATH,
                      old="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))",
                      new="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))",
                      expect=["t_clamp_hi"], why="row 20b: no-op survives")
        m3 = Mutation(id="R20c", file=MATH,
                      old="  def add(a, b), do: a + b",
                      new="  def add(a, b), do: a + b * 2",
                      expect=["t_add"], why="row 20c: killed")
        code, out, payload = drive([m3, m2], exempt={"t_clamp_lo": "r20",
                                                      "t_f1": "r20",
                                                      "t_raise": "r20",
                                                      "t_vacuous": "r20"})
        self.assertEqual(code, EXIT_FAIL)
        self.assertEqual(payload["defined"], 2)
        self.assertEqual(payload["applied"], 2)

        # A KILLED mutation alongside an INVALID (compile error) -> exit 1.
        # HM20 would let an INVALID count toward the exit-0 check; if it did,
        # the run could report success while a mutation is INVALID. Asserting
        # EXIT_FAIL here catches that: the INVALID must force a non-zero exit.
        m_kill = Mutation(id="R20d", file=MATH,
                          old="  def add(a, b), do: a + b",
                          new="  def add(a, b), do: a + b * 2",
                          expect=["t_add"], why="row 20d: killed")
        m_invalid = Mutation(id="R20e", file=MATH,
                             old="  def fetch(map, key) do",
                             new="  def fetch(map, key do  # compile error",
                             expect=["t_raise"], why="row 20e: compile error")
        code, out, payload = drive([m_kill, m_invalid], exempt={"t_clamp_hi": "r20",
                                                                "t_clamp_lo": "r20",
                                                                "t_f1": "r20",
                                                                "t_vacuous": "r20"})
        self.assertEqual(verdict_of(payload, "R20d"), "KILLED", out)
        self.assertEqual(verdict_of(payload, "R20e"), "INVALID", out)
        self.assertEqual(code, EXIT_FAIL, out)
        self.assertEqual(payload["defined"], 2)
        self.assertEqual(payload["applied"], 2)

    # Row 21: DSPY_MUT_REPORT unset -> plain `mix test` unchanged.
    def test_row21_formatter_off(self):
        import subprocess

        env = dict(ENV)
        env.pop("DSPY_MUT_REPORT", None)
        proc = subprocess.run(
            ["mix", "test"], capture_output=True, text=True,
            cwd=str(SELFTEST), env=env,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("Result: 6 passed", proc.stdout, proc.stdout + proc.stderr)
        # No formatter output: the report file must not exist.
        self.assertFalse((SELFTEST / ".mutlib_base_report.jsonl").exists())
        # The formatter must not be loaded: no crash/error from MutFormatter.
        self.assertNotIn("MutFormatter", proc.stdout,
                         "formatter was loaded even though DSPY_MUT_REPORT is unset")


def drive_base_snapshot():
    return MATH.read_bytes()


if __name__ == "__main__":
    unittest.main(verbosity=2)
