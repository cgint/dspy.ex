#!/usr/bin/env python3
# Greta H12 verdict: prove the shared-parser asymmetry.
#   shared: break NumberParser once       -> every path's tests should fail
#   per-site: put the OLD lenient parse back at ONE call site only -> only that path's tests fail
# Runs the FULL suite for each mutation and lists failing test files. Run from the clone root.
import subprocess, re, collections

LENIENT_NUM = ('(case Float.parse(String.trim(value)) do {n, _} -> {:ok, n}; '
               ':error -> {:error, :invalid_number} end)')
LENIENT_INT = ('(case Integer.parse(String.trim(value)) do {n, _} -> {:ok, n}; '
               ':error -> {:error, :invalid_integer} end)')

MUTATIONS = {
    "shared: strict_shape?/1 always true": [
        ("lib/dspy/signature/number_parser.ex",
         "  defp strict_shape?(value) do\n",
         "  defp strict_shape?(_value), do: true\n  defp __unused_strict_shape?(value) do\n")],
    "site: signature.ex back to lenient": [
        ("lib/dspy/signature.ex", "Dspy.Signature.NumberParser.parse_number(value)", LENIENT_NUM),
        ("lib/dspy/signature.ex", "Dspy.Signature.NumberParser.parse_integer(value)", LENIENT_INT)],
    "site: adapters/chat.ex back to lenient": [
        ("lib/dspy/signature/adapters/chat.ex", "Dspy.Signature.NumberParser.parse_number(value)", LENIENT_NUM),
        ("lib/dspy/signature/adapters/chat.ex", "Dspy.Signature.NumberParser.parse_integer(value)", LENIENT_INT)],
    "site: adapters/json.ex back to lenient": [
        ("lib/dspy/signature/adapters/json.ex", "Dspy.Signature.NumberParser.parse_number(value)", LENIENT_NUM),
        ("lib/dspy/signature/adapters/json.ex", "Dspy.Signature.NumberParser.parse_integer(value)", LENIENT_INT)],
}

originals = {}
try:
    for name, edits in MUTATIONS.items():
        files = {}
        ok = True
        for path, old, new in edits:
            src = files.get(path) or originals.setdefault(path, open(path).read())
            if src.count(old) != 1:
                print(f"{name}\n   NOT APPLIED: {old[:50]!r} found {src.count(old)}x in {path}")
                ok = False
                break
            files[path] = src.replace(old, new)
        if not ok:
            continue
        for path, src in files.items():
            open(path, "w").write(src)
        out = subprocess.run(["mix", "test"], capture_output=True, text=True).stdout
        for path in files:
            open(path, "w").write(originals[path])
        res = re.search(r"Result: (.*)", out)
        fails = re.findall(r"^\s+\d+\) test .+? \((\S+)\)\n\s+(\S+\.exs):\d+", out, re.M)
        by_file = collections.Counter(f for _, f in fails)
        print(f"{name}\n   {res.group(1) if res else '?'}")
        for f, c in sorted(by_file.items()):
            print(f"   {c:3} failing in {f}")
finally:
    for path, src in originals.items():
        open(path, "w").write(src)
