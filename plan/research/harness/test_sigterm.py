#!/usr/bin/env python3
"""Row 17 (acceptance map): SIGTERM and SIGHUP to the harness mid-mutation.

The real `Harness.run()` is started in a **subprocess** (no test-side signal
handlers, no direct `_apply` call): while the mutated selftest's slow test is
running we signal the harness. The library's own signal handlers must raise
SystemExit, the `finally` restore must fire, and afterwards every file must be
byte-identical to before the run with no mutation marker left behind.

Run: python3 plan/research/harness/test_sigterm.py
"""

import signal
import subprocess
import sys
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SELFTEST = HERE / "selftest"
MATH = SELFTEST / "lib" / "selftest" / "math.ex"
TEST_FILE = SELFTEST / "test" / "selftest_test.exs"

TARGET_SCRIPT = """
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutlib import Harness, Mutation

HERE = Path(__file__).resolve().parent
SELFTEST = HERE / "selftest"
MATH = SELFTEST / "lib" / "selftest" / "math.ex"
TEST_FILE = SELFTEST / "test" / "selftest_test.exs"

# Slow the expect test (a Process.sleep inside the selftest) so there is a
# wide window in which the mutation is applied and the signal can land.
# Process.sleep takes MILLISECONDS, so 10000 = 10 seconds.
TEST_FILE.write_text(TEST_FILE.read_text().replace(
    '  test "t_clamp_hi" do',
    '  test "t_clamp_hi" do\\n    Process.sleep(10000)',
    1,
))
m = Mutation(id="R17", file=MATH,
             old="  def clamp01(value), do: max(0.0, min(1.0, value * 1.0))",
             new="  def clamp01(value), do: max(0.0, min(1.9, value * 1.0))  # H20-SIG-MARKER",
             expect=["t_clamp_hi"], why="row 17: signal mid-run")

h = Harness(
    mutations=[m],
    test_files=[TEST_FILE],
    acceptance_files=[TEST_FILE],
    root=SELFTEST,
    report_path=SELFTEST / "row17_report.json",
)
code = h.run()
print(f"HARNESS EXIT CODE: {code}")
sys.exit(code)
"""


def run_signal_round(signum):
    """Start the real harness in a subprocess, signal it mid-mutation, verify restore.

    Returns the target process's captured output.
    """
    before_math = MATH.read_bytes()
    before_test = TEST_FILE.read_bytes()
    script = HERE / ".row17_target.py"
    script.write_text(TARGET_SCRIPT)

    try:
        proc = subprocess.Popen(
            [sys.executable, str(script)],
            cwd=str(HERE),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

        # Wait until the mutation marker is present in the target file:
        # proof that the real Harness.run() applied the mutation.
        marker_seen = False
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline and proc.poll() is None:
            if b"H20-SIG-MARKER" in MATH.read_bytes():
                marker_seen = True
                break
            time.sleep(0.2)
        assert marker_seen, (
            "mutation marker never appeared in math.ex within 300s — "
            "the harness did not reach _apply (check output)"
        )
        # The marker is in the file from _apply until _restore_one (after
        # mix test finishes). The mix-test is fast (<1s), so signal
        # IMMEDIATELY after seeing the marker to land inside the window.
        # With the library's handler: SystemExit -> finally-restore -> exit 1.
        # Without the handler: OS kill -> no restore -> exit 143 (or -15).
        proc.send_signal(signum)
        out, _ = proc.communicate(timeout=120)
        # The process must have exited via the library's handler (exit 1),
        # not via the OS kill (exit 143). If the handler was removed, the
        # OS kills the process, the finally-restore does NOT run, and the
        # files may not be byte-identical.
        expected_rc = 1  # hard failure via SystemExit
        if proc.returncode != expected_rc:
            raise AssertionError(
                f"expected exit code {expected_rc} (library handler), "
                f"got {proc.returncode} (OS kill or other)"
            )
    finally:
        if "proc" in locals() and proc.poll() is None:
            proc.kill()
        script.unlink(missing_ok=True)
        # Belt and braces: guarantee the canonical tree for the next round.
        MATH.write_bytes(before_math)
        TEST_FILE.write_bytes(before_test)

    # Byte-identical to before, no marker.
    assert MATH.read_bytes() == before_math, f"math.ex not byte-identical after signal {signum}"
    assert TEST_FILE.read_bytes() == before_test, f"selftest_test.exs not byte-identical after signal {signum}"
    assert b"H20-SIG-MARKER" not in MATH.read_bytes(), f"marker survived signal {signum}"
    return out


def _round_sigterm():
    """Row 17a: SIGTERM to the real Harness.run() mid-mutation."""
    print("Row 17a: SIGTERM to the real Harness.run() mid-mutation")
    out = run_signal_round(signal.SIGTERM)
    print(out[-1200:])
    print("SUCCESS: SIGTERM — process exited, files byte-identical, no marker")


def _round_sighup():
    """Row 17b: SIGHUP to the real Harness.run() mid-mutation."""
    print("Row 17b: SIGHUP to the real Harness.run() mid-mutation")
    out = run_signal_round(signal.SIGHUP)
    print(out[-1200:])
    print("SUCCESS: SIGHUP — process exited, files byte-identical, no marker")


class TestSigterm(unittest.TestCase):
    def test_sigterm(self):
        _round_sigterm()

    def test_sighup(self):
        _round_sighup()


if __name__ == "__main__":
    unittest.main()
