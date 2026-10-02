#!/usr/bin/env python3
"""Shared mutation-testing library (H20-C2, contract LOCKED 2026-10-02).

Every mutation declares the tests it exists to pin (`expect`) and the kind of
failure that counts (`kind`). The verdict is decided against a JSON test report
written by `mut_formatter.exs` (path in the `DSPY_MUT_REPORT` env var), never
against console text.

`expect`/`also`/`exempt` names are **exact ExUnit test names (without the
"test " prefix)**; the library prefixes them when matching.

Verdict per mutation (first match wins):
  V1  old text not found (0x)            -> NOT-APPLICABLE   (hard fail)
      old text found more than once (2x) -> AMBIGUOUS        (hard fail)
  V2  no `suite_finished` record, or non-zero exit with no failed/invalid
      record (compile error, ENFILE, VM crash)               -> INVALID
  V3  any `invalid` record (a `setup_all` failed)            -> INVALID
  V4  some `expect` test is `passed`, or absent from the
      records                                               -> SURVIVED-TARGET
  V5  some `expect` test failed with an error that does not
      match `kind`                                          -> WRONG-REASON
  V6  some `failed` test outside `expect ∪ also`             -> BLUNT
  V7  otherwise                                             -> KILLED

Whole-run rules:
  * pre-flight: a `new` text already present in its file is debris -> refuse
  * base green: the unmutated run must have `suite_finished`, zero failed,
    zero invalid
  * in-memory originals restored in try/finally; SIGTERM/SIGHUP raise
    SystemExit so the finally runs; post-run byte comparison must be equal
  * coverage (C3a): every test in the acceptance files must appear in some
    mutation's `expect` or in `exempt`; UNCLAIMED is a hard fail, named
  * exit 0 only if every mutation is KILLED and nothing is UNCLAIMED

Python 3 standard library only. Developer tool: nothing in `lib/` or CI's
`mix test` depends on it.
"""

import json
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_ENFILE = 2

ENFILE_MARKERS = ("ENFILE", "too many open files", "file table overflow")

# Matches `test "name"` lines (or `test name do`) in test sources.
TEST_LINE_RE = re.compile(r"^\s*test\s+(\"([^\"]+)\"|\w+)\s+do", re.MULTILINE)


class MutlibError(Exception):
    """Raised for abort conditions (ENFILE, pre-flight debris, bad restore)."""


@dataclass
class Mutation:
    id: str
    file: Path
    old: str
    new: str
    expect: list
    also: list = field(default_factory=list)
    kind: str = "assertion"  # "assertion" | "raise:<Module>" | "any"
    why: str = ""

    def __post_init__(self):
        if not self.expect:
            raise ValueError(f"mutation {self.id}: `expect` must not be empty")
        if self.kind not in ("assertion", "any") and not self.kind.startswith("raise:"):
            raise ValueError(f"mutation {self.id}: bad kind {self.kind!r}")


@dataclass
class TestRecord:
    name: str
    module: str | None
    file: str | None
    state: str  # "passed" | "failed" | "skipped" | "excluded" | "invalid"
    error: str | None  # e.g. "Elixir.ExUnit.AssertionError", "Elixir.KeyError"


@dataclass
class RunResult:
    returncode: int
    records: list  # list[TestRecord]
    finished: bool
    enfile: bool
    tail: str


@dataclass
class Verdict:
    mutation: Mutation
    verdict: str
    detail: str
    failed_records: list  # list[TestRecord]


def _full(name):
    """ExUnit prefixes test names with 'test '; declared names must not."""
    return name if name.startswith("test ") else f"test {name}"


class Harness:
    def __init__(
        self,
        mutations,
        test_files,
        acceptance_files,
        root=None,
        exempt=None,
        report_path=None,
        base_green=True,
    ):
        self.mutations = list(mutations)
        self.test_files = [str(Path(p)) for p in test_files]
        self.acceptance_files = [Path(p) for p in acceptance_files]
        self.root = Path(root) if root is not None else Path.cwd()
        self.exempt = dict(exempt or {})
        self.report_path = Path(report_path) if report_path else self.root / "mutation_report.json"
        self.report_path.parent.mkdir(parents=True, exist_ok=True)
        self.base_green = base_green
        self.snapshots = {}
        self.verdicts = []

    # -- signals / restore ------------------------------------------------

    def _install_signal_handlers(self):
        def on_signal(signum, _frame):
            raise SystemExit(f"signal {signum}")

        signal.signal(signal.SIGTERM, on_signal)
        signal.signal(signal.SIGHUP, on_signal)

    def snapshot(self):
        for m in self.mutations:
            self.snapshots[m.file] = m.file.read_bytes()

    def restore(self):
        for f, content in self.snapshots.items():
            f.write_bytes(content)

    def verify_restore(self):
        for f, content in self.snapshots.items():
            if f.read_bytes() != content:
                raise MutlibError(f"POST-RUN CHECK: {f} does not match its snapshot")

    # -- pre-flight --------------------------------------------------------

    def preflight(self):
        issues = []
        for m in self.mutations:
            text = m.file.read_text()
            # Check if the `new` text is already present.
            # This catches debris from previous runs.
            # But skip this check if `new` is the same as `old` (no-op mutation).
            if m.new != m.old and m.new in text:
                issues.append(f"{m.id}: `new` text already present in {m.file.name}")
            n = text.count(m.old)
            if n == 0:
                issues.append(f"{m.id}: `old` text not found in {m.file.name}")
            elif _ambiguous_count(n):
                issues.append(f"{m.id}: `old` text found {n}x in {m.file.name}")
        return issues


    # -- test runner -------------------------------------------------------

    def run_tests(self, report_path):
        env = dict(os.environ)
        # Use an absolute path so the formatter can write to it regardless of cwd
        report_path = Path(report_path).resolve()
        env["DSPY_MUT_REPORT"] = str(report_path)
        # Mix's incremental compile keeps a `_build/test` beam and, based on
        # recorded mtimes, may decide an edited source file is "unchanged" and
        # skip recompiling it. That serves a STALE beam, so a mutation appears
        # to have no effect and its `expect` test passes -> a bogus
        # SURVIVED-TARGET. Wipe the test-env build so `mix test` always
        # compiles from the current source. Deterministic, and safe: it is a
        # throwaway dev cache, and we never touch the main project's _build.
        build_test_dir = self.root / "_build" / "test"
        if build_test_dir.exists():
            import shutil
            shutil.rmtree(build_test_dir, ignore_errors=True)
        start = time.monotonic()
        proc = subprocess.run(
            ["mix", "test", *[os.path.relpath(str(Path(p)), str(self.root)) for p in self.test_files]],
            capture_output=True,
            text=True,
            cwd=str(self.root),
            env=env,
        )
        wall_us = int((time.monotonic() - start) * 1_000_000)
        out = proc.stdout + proc.stderr
        records, finished = [], False
        if report_path.exists():
            for line in report_path.read_text().splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(rec, dict) and rec.get("suite_finished"):
                    finished = True
                    rec["run_us"] = wall_us
                else:
                    records.append(TestRecord(
                        name=rec.get("name") or "",
                        module=rec.get("module"),
                        file=rec.get("file"),
                        state=rec.get("state") or "",
                        error=rec.get("error"),
                    ))
        report_path.unlink(missing_ok=True)
        enfile = any(marker in out for marker in ENFILE_MARKERS)
        return RunResult(proc.returncode, records, finished, enfile, out[-2000:])

    def base_run(self):
        if not self.base_green:
            return None
        report = self.root / ".mutlib_base_report.jsonl"
        res = self.run_tests(report)
        if res.enfile:
            _abort_enfile(res)
        failed = [r for r in res.records if r.state in ("failed", "invalid")]
        if not res.finished or failed or res.returncode != 0:
            names = [r.name for r in failed]
            raise MutlibError(
                f"BASE-GREEN CHECK FAILED (exit {res.returncode}, finished={res.finished}): {names}"
            )
        passed = sum(1 for r in res.records if r.state == "passed")
        print(f"Base tests green: {passed} passed, 0 failures")
        return res

    # -- verdicts ----------------------------------------------------------

    def _verdict(self, m, res):
        by_name = {r.name: r for r in res.records if r.name}
        failed = [r for r in res.records if r.state == "failed"]
        invalid = [r for r in res.records if r.state == "invalid"]

        if res.enfile or not res.finished or (res.returncode != 0 and not (failed or invalid)):
            return "INVALID", (
                f"exit {res.returncode}, finished={res.finished}, enfile={res.enfile}; "
                f"tail: {res.tail[:400]!r}"
            )
        if invalid:
            return "INVALID", f"invalid records: {[r.name for r in invalid]}"

        expected = [_full(t) for t in m.expect]
        missing = [t for t in expected if by_name.get(t, _PASSED).state != "failed"]
        if missing:
            absent = [t for t in missing if t not in by_name]
            return "SURVIVED-TARGET", f"expected to fail but did not: {missing}" + (
                f" (absent from records: {absent})" if absent else ""
            )

        bad = [(t, by_name[t].error) for t in expected
               if not _kind_matches(m.kind, by_name[t])]
        if bad:
            return "WRONG-REASON", f"failed for the wrong kind: {bad}"

        declared = set(expected) | {_full(t) for t in m.also}
        extra = sorted({r.name for r in failed if r.name not in declared})
        if extra:
            return "BLUNT", f"unexpected failures outside expect+also: {extra}"

        return "KILLED", f"failed as declared: {m.expect}"

    # -- run ---------------------------------------------------------------

    def run(self):
        self._install_signal_handlers()
        self.snapshot()
        issues = self.preflight()
        if issues:
            for i in issues:
                print(f"PRE-FLIGHT: {i}")
            print("Refusing to start: the tree carries debris or the anchors do not match.")
            self.restore()
            self._report(interrupted="pre-flight")
            return EXIT_FAIL
        try:
            self.base_run()
            for m in self.mutations:
                self._apply(m)
                print(f"APPLIED: {m.id} ({m.why or m.new[:40]!r})")
                report = self.root / f".mutlib_report_{m.id}.jsonl"
                try:
                    res = self.run_tests(report)
                finally:
                    self._restore_one(m)
                if res.enfile:
                    _abort_enfile(res)
                verdict, detail = self._verdict(m, res)
                self.verdicts.append(Verdict(m, verdict, detail, res.records))
                print(f"  {verdict}: {m.id} — {detail}")
            self.verify_restore()
        except SystemExit as e:
            self._report(interrupted=str(e))
            return EXIT_ENFILE if e.code == EXIT_ENFILE else EXIT_FAIL
        except MutlibError as e:
            self._report(interrupted=str(e))
            return EXIT_FAIL
        except BaseException as e:  # noqa: BLE001 - restore is the point
            self._report(interrupted=f"exception: {e!r}")
            return EXIT_FAIL
        finally:
            # Single source of truth for the restore guarantee: no matter how
            # run() exits (normal return, SystemExit, MutlibError, or any
            # other exception) the source files are put back byte-for-byte.
            # Removing this line (HM18) makes a signal/exception leave the
            # tree mutated, which the row-18 self-test catches.
            self.restore()

        return self._report()

    def _apply(self, m):
        content = m.file.read_text()
        if content.count(m.old) != 1:
            raise MutlibError(f"{m.id}: pre-flight said unique but count={content.count(m.old)}")
        m.file.write_text(content.replace(m.old, m.new, 1))

    def _restore_one(self, m):
        m.file.write_bytes(self.snapshots[m.file])

    # -- coverage (C3a) ------------------------------------------------------

    def coverage(self):
        """Every test in the acceptance files must be expected or exempt."""
        claimed = {_full(n) for n in self.exempt}
        for m in self.mutations:
            claimed.update(_full(t) for t in m.expect)
        unclaimed = []
        for path in self.acceptance_files:
            text = path.read_text()
            for match in TEST_LINE_RE.finditer(text):
                name = match.group(2) or match.group(1)
                full = _full(name)
                if full not in claimed:
                    unclaimed.append(f"{path.name}: {name}")
        return unclaimed

    # -- report --------------------------------------------------------------

    def _report(self, interrupted=None):
        defined = len(self.mutations)
        counts = {v: 0 for v in (
            "KILLED", "SURVIVED-TARGET", "WRONG-REASON", "BLUNT", "INVALID",
            "NOT-APPLICABLE", "AMBIGUOUS")}
        for vd in self.verdicts:
            counts[vd.verdict] += 1
        unclaimed = self.coverage()
        any_kind = sum(1 for m in self.mutations if m.kind == "any")

        print(f"\n{'=' * 64}\nMUTATION LIBRARY REPORT{'=' * 57}")
        print(f"Patterns defined:  {defined}")
        print(f"Mutations applied: {len(self.verdicts)}")
        for v, n in counts.items():
            ids = [vd.mutation.id for vd in self.verdicts if vd.verdict == v]
            print(f"{v:<15} {n} {(' '.join(ids)) if ids else ''}")
        print(f"kind 'any' used:   {any_kind}")
        for m in self.mutations:
            if m.also:
                print(f"  also ({m.id}): {m.also}")
        _print_exempt(self.exempt)
        if unclaimed:
            print("Exempt (printed, not claimed):")
            for name, reason in self.exempt.items():
                print(f"  {name}: {reason}")
        if unclaimed:
            print(f"UNCLAIMED: {len(unclaimed)}")
            for u in unclaimed:
                print(f"  UNCLAIMED: {u}")

        payload = {
            "defined": defined,
            "applied": len(self.verdicts),
            "counts": counts,
            "kind_any": any_kind,
            "unclaimed": unclaimed,
            "exempt": self.exempt,
            "interrupted": interrupted,
            "mutations": [
                {
                    "id": vd.mutation.id,
                    "why": vd.mutation.why,
                    "kind": vd.mutation.kind,
                    "expect": vd.mutation.expect,
                    "also": vd.mutation.also,
                    "verdict": vd.verdict,
                    "detail": vd.detail,
                    "failed": [
                        {"name": r.name, "state": r.state, "error": r.error}
                        for r in vd.failed_records if r.state in ("failed", "invalid")
                    ],
                }
                for vd in self.verdicts
            ],
        }
        self.report_path.write_text(json.dumps(payload, indent=2) + "\n")
        print(f"Report: {self.report_path}")

        ok = (
            interrupted is None
            and defined == len(self.verdicts)
            and all(vd.verdict == "KILLED" for vd in self.verdicts)
            and not unclaimed
        )
        if ok:
            print(f"\nALL CLEAR: {len(self.verdicts)}/{defined} KILLED, 0 UNCLAIMED.")
            return EXIT_OK
        print("\nHARD FAILURE.")
        return EXIT_FAIL


_PASSED = TestRecord(name="", module=None, file=None, state="passed", error=None)


def _ambiguous_count(n):
    # HM11b: the pre-flight `n > 1` (AMBIGUOUS) check is lost.
    return n > 1


def _print_exempt(exempt):
    # HM13b: `exempt` not printed.
    if exempt:
        print("Exempt (printed, not claimed):")
        for name, reason in exempt.items():
            print(f"  {name}: {reason}")


def _kind_matches(kind, record):
    if kind == "any":
        return True
    if kind == "assertion":
        return _assertion_error(record.error)
    module = kind.split(":", 1)[1]
    # Error names from the formatter carry the Elixir. prefix.
    return record.error in (f"Elixir.{module}", module)


def _assertion_error(error):
    # HM10: `assertion` matched against the wrong struct name.
    return error in ("Elixir.ExUnit.AssertionError", "ExUnit.AssertionError")


def _abort_enfile(res):
    print("ABORT: ENFILE / too many open files seen in test output. Stop and escalate.")
    print(res.tail)
    raise SystemExit(EXIT_ENFILE)


if __name__ == "__main__":
    print("mutlib is a library; write a small harness script that uses it.")
    sys.exit(1)
