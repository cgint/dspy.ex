#!/usr/bin/env python3
# Greta: three mutations that each UNDO one B1 fix. Each must turn a test RED,
# otherwise B1 can regress with nothing failing. Run from the clone root.
import subprocess, re

P = "lib/dspy/metrics.ex"
ORIG = open(P).read()
M = [
    ("B1a: final sigma off (downcase without :greek)",
     "|> String.downcase(:greek)", "|> String.downcase()"),
    ("B1b: articles back to \\b (combining-mark fix undone)",
     r'String.replace(~r/(?<![\p{L}\p{N}_])(a|an|the)(?![\p{L}\p{N}_])/u, " ")',
     r'String.replace(~r/\b(a|an|the)\b/u, " ")'),
    ("B1c: \\x1c-\\x1f dropped from whitespace class",
     r'String.replace(~r/[\s\x{1c}-\x{1f}]+/u, " ")',
     r'String.replace(~r/\s+/u, " ")'),
]
T = ["test/metrics_upstream_test.exs", "test/metrics_evaluate_test.exs", "test/metrics_test.exs"]
passed_only = re.compile(r"\d+ passed.*")
try:
    for name, old, new in M:
        count = ORIG.count(old)
        if count != 1:
            print(f"{name:55} NOT APPLIED ({count}x)")
            continue
        open(P, "w").write(ORIG.replace(old, new))
        out = subprocess.run(["mix", "test", *T], capture_output=True, text=True).stdout
        m = re.search(r"Result: (.*)", out)
        line = m.group(1) if m else "?"
        verdict = "GREEN (SURVIVES)" if passed_only.fullmatch(line) else "RED"
        print(f"{name:55} {verdict} — {line}")
finally:
    open(P, "w").write(ORIG)
