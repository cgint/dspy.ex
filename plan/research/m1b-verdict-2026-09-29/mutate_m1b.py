#!/usr/bin/env python3
# Greta M1-b mutation harness: apply one mutation to lib/dspy/metrics.ex, run the
# three metrics test files, record RED/GREEN, restore. Run from the clone root.
# SS8 (2026-09-29, Emil): the three normalize patterns were refreshed to the
# post-B1 lines (Greek downcase, Python-\b-style lookarounds, \x1c-\x1f class);
# each mutation's INTENT is unchanged (drop lookarounds / drop a|an / spaces only).
import subprocess, re, shutil, sys

P = "lib/dspy/metrics.ex"
ORIG = open(P).read()

M = [
    ("em: first answer only (not any)",
     "Enum.any?(answers, fn ans -> pairwise_em(pred, ans) end)", "pairwise_em(pred, hd(answers))"),
    ("f1: first answer only (not max)",
     "Enum.map(answers, fn ans -> pairwise_f1(pred, ans) end)\n    |> Enum.max()", "pairwise_f1(pred, hd(answers))"),
    ("f1: set overlap (not multiset)",
     "acc + min(Map.get(pred_freq, token), Map.get(ans_freq, token))", "acc + 1"),
    ("f1: both-empty -> 1.0",
     "if length(pred_tokens) == 0 and length(ans_tokens) == 0 do\n      0.0", "if length(pred_tokens) == 0 and length(ans_tokens) == 0 do\n      1.0"),
    ("frac: > instead of >=", "f1(pred_answer, answers) >= frac", "f1(pred_answer, answers) > frac"),
    ("frac: == 1.0 instead of >= 1.0", "if frac >= 1.0 do", "if frac == 1.0 do"),
    ("normalize: no NFD",
     "def normalize_text(text) when is_binary(text) do\n    :unicode.characters_to_nfd_binary(text)",
     "def normalize_text(text) when is_binary(text) do\n    text"),
    ("normalize: \\p{P} punctuation",
     "String.replace(~r/[!\"#$%&'()*+,\\-.\\/:;<=>?@\\[\\\\\\]^_`{|}~]/u, \"\")", "String.replace(~r/\\p{P}/u, \"\")"),
    ("normalize: articles without word boundaries",
     "String.replace(~r/(?<![\\p{L}\\p{N}_])(a|an|the)(?![\\p{L}\\p{N}_])/u, \" \")", "String.replace(~r/(a|an|the)/u, \" \")"),
    ("normalize: only 'the' removed",
     "String.replace(~r/(?<![\\p{L}\\p{N}_])(a|an|the)(?![\\p{L}\\p{N}_])/u, \" \")", "String.replace(~r/(?<![\\p{L}\\p{N}_])(the)(?![\\p{L}\\p{N}_])/u, \" \")"),
    ("normalize: only spaces collapse (not all whitespace)",
     "String.replace(~r/[\\s\\x{1c}-\\x{1f}]+/u, \" \")", "String.replace(~r/ +/u, \" \")"),
    ("dpr: whitespace split instead of DPR tokens",
     "Regex.scan(~r/[\\p{L}\\p{N}\\p{M}]+|[^\\p{Z}\\p{C}]/u, lower)\n    |> Enum.map(fn [match] -> String.downcase(match) end)", "String.split(lower)"),
    ("dpr: token class without \\p{M}",
     "[\\p{L}\\p{N}\\p{M}]+|[^\\p{Z}\\p{C}]", "[\\p{L}\\p{N}]+|[^\\p{Z}\\p{C}]"),
    ("dpr: empty answer run -> false",
     "# Mirrors upstream: an empty answer run matches at any position.\n    true",
     "# Mirrors upstream: an empty answer run matches at any position.\n    false"),
]

TESTS = ["test/metrics_upstream_test.exs", "test/metrics_evaluate_test.exs", "test/metrics_test.exs"]
results = []
try:
    for name, old, new in M:
        if ORIG.count(old) != 1:
            results.append((name, f"NOT APPLIED (pattern found {ORIG.count(old)}x)"))
            continue
        open(P, "w").write(ORIG.replace(old, new))
        out = subprocess.run(["mix", "test", *TESTS], capture_output=True, text=True).stdout
        m = re.search(r"Result: (.*)", out) or re.search(r"(\d+ tests?, \d+ failures?.*)", out)
        line = m.group(1) if m else ("COMPILE ERROR" if "error" in out.lower() else "?")
        verdict = "GREEN (mutation SURVIVES)" if re.fullmatch(r"\d+ passed.*", line) else "RED"
        results.append((name, f"{verdict} — {line}"))
finally:
    open(P, "w").write(ORIG)

for name, r in results:
    print(f"{name:55} {r}")
