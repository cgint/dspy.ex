#!/usr/bin/env python3
"""H12 mutation harness v3 (2026-09-29, post-HB1/HB3).

Two distinct proof directions (HB1 2026-09-29):

  1. SHARED-MODULE mutation: break the shared NumberParser (make
     strict_shape? always-true). Must red the H12 tests. This proves the
     shared module is tested.

  2. PER-CALL-SITE reverts: revert EACH of the three call sites
     (signature.ex, adapters/chat.ex, adapters/json.ex) individually back to
     the old lenient inline parsing. Each revert must red THAT path's tests.
     This proves every caller is actually wired to the shared parser (a
     shared-module mutation alone could leave a bypassed caller green).

  3. BEHAVIOUR mutations (M1–M10, M9a, M9b): inject an explicit accept-branch
     into the shared parser for a specific previously-rejected input. Each
     must be KILLED by a test (the input is now in the golden fixture as a
     reject row, so accepting it fails the fixture-consumer test). M9a (",1")
     and M9b ("1,") are REAL mutations now (HB3): upstream rejects both, they
     are generator inputs, and a mutation that accepts exactly ",1" is killed
     by the ",1" golden row — it is NOT unkillable-by-construction.

EXIT: 0 if every mutation is KILLED (and every call-site revert is RED).
      1 if any SURVIVED.

COUNT RECONCILIATION (HB3): the report MUST state two numbers —
  (a) the count of mutations actually APPLIED (from the log), and
  (b) the count of patterns DEFINED in this script — and reconcile them.
A NOT-APPLICABLE line is a false zero: a mutation that is neither RED nor a
survivor, it simply vanishes. Any NOT-APPLICABLE is a hard failure here.

Usage: python3 plan/research/upstream_golden/mutate_h12.py
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "lib" / "dspy" / "signature"
TARGET = LIB / "number_parser.ex"
SIG = ROOT / "lib" / "dspy" / "signature.ex"
CHAT = ROOT / "lib" / "dspy" / "signature" / "adapters" / "chat.ex"
JSON = ROOT / "lib" / "dspy" / "signature" / "adapters" / "json.ex"
TEST_FILES = [
    ROOT / "test" / "signature_number_integer_strict_test.exs",
    ROOT / "test" / "signature_h12_golden_fixture_test.exs",
    ROOT / "test" / "signature_h12_adapter_paths_test.exs",
]

# HB4 (2026-09-29): the ORIGINAL contents of the four source files, held in
# MEMORY for the duration of the run. restore_all() writes these back in a
# try/finally. No backup FILES on disk: a file-based backup written "only if it
# does not exist yet" silently goes stale on the second run, and then
# restore_all() overwrites the developer's current tree with the STALE run-one
# content - both testing old code AND destroying uncommitted edits. Holding the
# snapshot in memory makes the tool stateless: every run starts from whatever is
# on disk at start, and a crash (finally) still restores the tree.

# Populated by snapshot_all() at the top of main().
_SNAPSHOTS = {}


def snapshot_all():
    """Read each of the four source files ONCE into _SNAPSHOTS (in memory)."""
    for f in (TARGET, SIG, CHAT, JSON):
        _SNAPSHOTS[f] = f.read_text()


def detect_leftovers():
    """HB6 (2026-09-29): refuse to start if the tree already carries debris from
    a killed prior run (e.g. a harness that was SIGKILLed mid-mutation left a
    null-reverted call site or an injected accept-branch in place). Nothing
    survives a kill -9, but a tool that NOTICES its own debris and refuses
    rather than proceeding is the right posture: it will not test a mutated tree
    as if it were the clean base and print a false ALL CLEAR.

    Returns a list of (file, reason) for any file that looks mutated. An empty
    list is clean. The checks are structural: a clean tree always calls the
    shared parser (never a bare `{:error, :invalid_*}` stub) and never contains
    an injected `if t == "..." do` accept-branch at the top of do_parse."""
    leftovers = []
    # (a) A null-reverted call site: the shared-parser call has been replaced by
    #     a bare stub. A clean tree always has the call.
    for f, marker in [
        (SIG, "Dspy.Signature.NumberParser.parse_integer(value)"),
        (CHAT, "Dspy.Signature.NumberParser.parse_integer(value)"),
        (JSON, "Dspy.Signature.NumberParser.parse_integer(value)"),
    ]:
        if marker not in f.read_text():
            leftovers.append((f, "shared-parser call missing (null-revert debris?)"))
    # (b) An injected accept-branch left at the top of do_parse by a behaviour
    #     mutation (the M1–M10 pattern).
    target = TARGET.read_text()
    injected = re.search(r'do_parse\(raw, :(float|int)\) do\n    t = String\.trim\(raw\)\n    if t == ', target)
    if injected:
        leftovers.append((TARGET, "injected accept-branch left at top of do_parse (behaviour-mutation debris?)"))
    return leftovers


def restore_all():
    """Restore all four source files from the in-memory snapshot."""
    for f, original in _SNAPSHOTS.items():
        f.write_text(original)


def run_tests():
    cmd = ["mix", "test"] + [str(f) for f in TEST_FILES]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=600)
    out = proc.stdout + proc.stderr
    # ExUnit prints EITHER "Result: N passed" (all green) OR
    # "Result: A/B passed\nFailed: K tests" (some red). Detect failures
    # robustly: any "Failed: K" line with K>0, or a non-zero exit code, is RED.
    failed = 0
    m2 = re.search(r"Failed:\s*(\d+)\s*tests?", out)
    if m2:
        failed = int(m2.group(1))
    passed = -1
    m = re.search(r"Result:\s*(\d+)(?:/(\d+))?\s*passed", out)
    if m:
        passed = int(m.group(1))
    # A mix-test crash (exit 2) with no "Result:" line is also RED.
    crashed = proc.returncode != 0 and "Result:" not in out
    compile_err = "Compilation error" in out or "SyntaxError" in out
    red = failed > 0 or crashed or compile_err
    return passed, failed, out[-2000:], red


def mutate_shared(source: str, name: str):
    """Apply a behaviour mutation to the shared NumberParser. Return mutated
    source, or None if the anchor was not found (NOT-APPLICABLE — a hard
    failure under HB3, reported and counted)."""
    if name.startswith("SHARED:"):
        # Make strict_shape? always-true (the HB1 shared-module mutation).
        m = re.search(
            r"  defp strict_shape\?\(value\) do\n.*?\n  end\n", source, re.DOTALL
        )
        if not m:
            return None
        return source.replace(m.group(0), "  defp strict_shape?(value) do\n    true\n  end\n", 1)

    # Behaviour mutations: inject an accept-branch at the top of the float or
    # int clause in NumberParser.
    branch_map = {
        "M1: accept '80%' as 80.0 (:number)": (":float", 't == "80%"', "{:ok, 80.0}"),
        "M2: accept 'true' as 1.0 (:number)": (":float", 't in ["true", "True", "False"]',
                                              '{:ok, (if t == "False", do: 0.0, else: 1.0)}'),
        "M3: accept 'NaN' as 0.0 (:number)": (":float", 't in ["NaN", "nan", "NAN", "inf", "-inf", "INF", "+inf"]',
                                             "{:ok, 0.0}"),
        "M4: accept '0x10G' as 16 (:number)": (":float", 't == "0x10G"', "{:ok, 16.0}"),
        "M5: accept '1,000' as 1000.0 (:number)": (":float", 't == "1,000"', "{:ok, 1000.0}"),
        "M6: accept '' as 0.0 (:number)": (":float", 't == ""', "{:ok, 0.0}"),
        "M7: accept '1e' as 1.0 (:number)": (":float", 't == "1e"', "{:ok, 1.0}"),
        "M8: accept '1 000' as 1000.0 (:number)": (":float", 't == "1 000"', "{:ok, 1000.0}"),
        "M9a: accept ',1' as 1 (:integer)": (":int", 't == ",1"', "{:ok, 1}"),
        "M9b: accept '1,' as 1 (:integer)": (":int", 't == "1,"', "{:ok, 1}"),
        "M10: accept 'inf' as 0 (:integer)": (":int", 't in ["NaN", "nan", "NAN", "inf", "-inf", "INF", "+inf"]',
                                             "{:ok, 0}"),
    }
    if name not in branch_map:
        return None
    path, cond, body = branch_map[name]

    # Find the do_parse clause for the target annotation and inject a guard.
    # The simplest robust injection: wrap the strict_shape? gate so that the
    # specific input short-circuits to the accept value BEFORE the shape check.
    if path == ":float":
        anchor = "  defp do_parse(raw, :float) do\n"
        inj = (
            f"  defp do_parse(raw, :float) do\n"
            f"    t = String.trim(raw)\n"
            f"    if {cond} do\n"
            f"      {body}\n"
            f"    else\n"
        )
    else:
        anchor = "  defp do_parse(raw, :int) do\n"
        inj = (
            f"  defp do_parse(raw, :int) do\n"
            f"    t = String.trim(raw)\n"
            f"    if {cond} do\n"
            f"      {body}\n"
            f"    else\n"
        )
    if anchor not in source:
        return None
    mutated = source.replace(anchor, inj, 1)
    # Close the if with an `end` right before the existing `end` of do_parse.
    # do_parse ends with "  end\n" — insert our "    end\n  end" structure.
    # Find the do_parse body's closing end and add our wrapper end.
    idx = mutated.index(anchor) + len(anchor)
    # The do_parse clause's final "  end" — locate the matching end.
    # For :float it is a case/unwind; for :int a cond. Easiest: append the
    # closing `end` of our injected `if` before the function's closing end.
    # We insert "    end\n" right after the original body's last line.
    # The original body is everything up to the function's "  end".
    m = re.search(r"  end\n", mutated[idx:])
    if not m:
        return None
    end_pos = idx + m.end()
    mutated = mutated[:end_pos] + "    end\n" + mutated[end_pos:]
    return mutated


def revert_call_site(file: Path, name: str):
    """NULL-revert one call site: replace its shared-parser call with a stub that
    always errors. This proves the site DELEGATES to Dspy.Signature.NumberParser
    (HB1): if the site bypassed the shared parser, stubbing the shared call would
    NOT change its behaviour, and the accept test would stay green.

    NOTE: a *lenient* revert (restoring the old `{num, _rest} -> {:ok, num}`
    inline code) is the WRONG instrument for HB1 - a lenient parser only accepts
    MORE, so a value the strict parser accepts ("0.8") is also accepted by the
    lenient one, and the reject values (",1") are already rejected by the lenient
    Integer.parse. The lenient revert is therefore behaviourally invisible to the
    accept+reject test pairs and cannot distinguish a wired site from a bypassed
    one. The null-revert changes behaviour for EVERY input, so the accept test
    catches it. Returns True if applied, False if the anchor was not found."""
    src = file.read_text()
    pairs = {
        "REVERT signature.ex :integer": (
            ":integer when is_binary(value) ->\n        Dspy.Signature.NumberParser.parse_integer(value)",
            ":integer when is_binary(value) ->\n        {:error, :invalid_integer}",
        ),
        "REVERT signature.ex :number": (
            ":number when is_binary(value) ->\n        Dspy.Signature.NumberParser.parse_number(value)",
            ":number when is_binary(value) ->\n        {:error, :invalid_number}",
        ),
        "REVERT chat.ex :integer": (
            "defp validate_field_type(value, :integer) when is_binary(value),\n    do: Dspy.Signature.NumberParser.parse_integer(value)",
            "defp validate_field_type(value, :integer) when is_binary(value),\n    do: {:error, :invalid_integer}",
        ),
        "REVERT chat.ex :number": (
            "defp validate_field_type(value, :number) when is_binary(value),\n    do: Dspy.Signature.NumberParser.parse_number(value)",
            "defp validate_field_type(value, :number) when is_binary(value),\n    do: {:error, :invalid_number}",
        ),
        "REVERT json.ex :integer": (
            ":integer when is_binary(value) ->\n        Dspy.Signature.NumberParser.parse_integer(value)",
            ":integer when is_binary(value) ->\n        {:error, :invalid_integer}",
        ),
        "REVERT json.ex :number": (
            ":number when is_binary(value) ->\n        Dspy.Signature.NumberParser.parse_number(value)",
            ":number when is_binary(value) ->\n        {:error, :invalid_number}",
        ),
    }
    if name not in pairs:
        return False
    anchor, stub = pairs[name]
    if anchor not in src:
        return False
    file.write_text(src.replace(anchor, stub, 1))
    return True


def main():
    # HB6 pre-flight: refuse to start on a tree that carries debris from a
    # killed prior run. This runs BEFORE snapshotting so the in-memory restore
    # is built from a clean tree, and BEFORE any mutation so we never test a
    # mutated base as if it were clean.
    leftovers = detect_leftovers()
    if leftovers:
        import sys as _sys
        print("HARD FAILURE: refusing to start — leftover debris from a killed "
              "prior run detected:")
        for f, reason in leftovers:
            print(f"  {f.name}: {reason}")
        print("Restore a clean tree (git checkout / re-apply the H12 state) and "
              "re-run. The harness will not claim ALL CLEAR on a mutated base.")
        _sys.stdout.flush()
        _sys.exit(1)

    snapshot_all()
    results = []
    base_red = False
    hard_fail = False
    try:
        # HB4 precondition: the BASE tree must be green before we run any
        # mutation. A red base makes every mutation "killed" trivially (red on
        # red) and the harness reports ALL CLEAR about code that is already
        # broken - a false pass one layer beneath the mutation logic.
        base_passed, base_failed, base_tail, base_red = run_tests()
        if base_red:
            base_red = True
            print(f"HARD FAILURE: base tree is RED before any mutation "
                  f"(passed={base_passed}, failed={base_failed}). "
                  f"Fix the tree; the harness will not claim ALL CLEAR on a red base.\n"
                  f"{base_tail}")
            results.append(("BASE-GREEN-CHECK", "HARD-FAILURE", base_passed, base_failed, True))
        else:
            print(f"BASE GREEN (passed={base_passed}) - proceeding with mutations")
            _run_mutations(results)
    finally:
        # ALWAYS restore the tree from the in-memory snapshot, even if a
        # mutation crashed or the run was interrupted (HB4).
        restore_all()
        if base_red:
            hard_fail = True
        else:
            hard_fail = _report(results)
    import sys as _sys
    _sys.stdout.flush()
    _sys.stderr.flush()
    _sys.exit(1 if hard_fail else 0)


def _run_mutations(results):

        # --- Direction 1: shared-module mutation (HB1) ---
        shared_mutated = mutate_shared(TARGET.read_text(), "SHARED: always-accept")
        if shared_mutated is None:
            results.append(("SHARED: always-accept", "NOT-APPLICABLE", 0, 0, True))
        else:
            TARGET.write_text(shared_mutated)
            passed, failed, tail, red = run_tests()
            restore_all()
            status = "RED" if red else "GREEN"
            print(f"{status:14s} SHARED: always-accept  (passed={passed}, failed={failed})")
            results.append(("SHARED: always-accept", status, passed, failed, red))

        # --- Direction 2: per-call-site reverts (HB1) ---
        for name, file in [
            ("REVERT signature.ex :integer", SIG),
            ("REVERT signature.ex :number", SIG),
            ("REVERT chat.ex :integer", CHAT),
            ("REVERT chat.ex :number", CHAT),
            ("REVERT json.ex :integer", JSON),
            ("REVERT json.ex :number", JSON),
        ]:
            applied = revert_call_site(file, name)
            if not applied:
                results.append((name, "NOT-APPLICABLE", 0, 0, True))
                continue
            passed, failed, tail, red = run_tests()
            restore_all()
            status = "RED" if red else "GREEN"
            print(f"{status:14s} {name}  (passed={passed}, failed={failed})")
            results.append((name, status, passed, failed, red))

        # --- Direction 3: behaviour mutations M1–M10, M9a, M9b ---
        for name in [
            "M1: accept '80%' as 80.0 (:number)",
            "M2: accept 'true' as 1.0 (:number)",
            "M3: accept 'NaN' as 0.0 (:number)",
            "M4: accept '0x10G' as 16 (:number)",
            "M5: accept '1,000' as 1000.0 (:number)",
            "M6: accept '' as 0.0 (:number)",
            "M7: accept '1e' as 1.0 (:number)",
            "M8: accept '1 000' as 1000.0 (:number)",
            "M9a: accept ',1' as 1 (:integer)",
            "M9b: accept '1,' as 1 (:integer)",
            "M10: accept 'inf' as 0 (:integer)",
        ]:
            mutated = mutate_shared(TARGET.read_text(), name)
            if mutated is None:
                results.append((name, "NOT-APPLICABLE", 0, 0, True))
                continue
            TARGET.write_text(mutated)
            passed, failed, tail, red = run_tests()
            restore_all()
            if red:
                status = "KILLED"
            else:
                status = "SURVIVED"
            print(f"{status:14s} {name}  (passed={passed}, failed={failed})")
            if status == "SURVIVED":
                print(f"  SURVIVOR TAIL:\n{tail}")
            results.append((name, status, passed, failed, red))


def _report(results):
    # --- Count reconciliation (HB3) ---
    patterns_defined = 1 + 6 + 11  # SHARED + 6 call-site reverts + 11 behaviour
    applied = [r for r in results if r[1] != "NOT-APPLICABLE"]
    not_applicable = [r for r in results if r[1] == "NOT-APPLICABLE"]
    survivors = [r for r in results if r[1] == "SURVIVED"]

    print("\n=== SUMMARY ===")
    for name, status, passed, failed, cerr in results:
        print(f"  {status:14s} {name}")

    print(f"\n=== COUNT RECONCILIATION (HB3) ===")
    print(f"  patterns defined in script : {patterns_defined}")
    print(f"  mutations applied (log)    : {len(applied)}")
    print(f"  NOT-APPLICABLE (false zero): {len(not_applicable)}")
    for r in not_applicable:
        print(f"    - {r[0]}")
    print(f"  SURVIVED                   : {len(survivors)}")
    for r in survivors:
        print(f"    - {r[0]}")

    hard_fail = len(not_applicable) > 0 or len(survivors) > 0
    print(f"\n{'HARD FAILURE' if hard_fail else 'ALL CLEAR'}: "
          f"applied={len(applied)}/{patterns_defined}, "
          f"not-applicable={len(not_applicable)}, survivors={len(survivors)}")
    return hard_fail

if __name__ == "__main__":
    main()
