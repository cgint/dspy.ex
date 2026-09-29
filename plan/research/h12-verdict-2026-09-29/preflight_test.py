#!/usr/bin/env python3
# Greta: exercise the H12 harness pre-flight with each debris shape, a behavioural
# wrong-base edit, and a clean tree. Prints which guard fired. Run from the clone root.
import subprocess, re

H = "plan/research/upstream_golden/mutate_h12.py"
NP = "lib/dspy/signature/number_parser.ex"
FILES = [NP, "lib/dspy/signature.ex", "lib/dspy/signature/adapters/chat.ex", "lib/dspy/signature/adapters/json.ex"]
ORIG = {f: open(f).read() for f in FILES}
LEN_NUM = '(case Float.parse(String.trim(value)) do {n, _} -> {:ok, n}; :error -> {:error, :invalid_number} end)'

def debris_null_revert(path):
    def apply():
        s = ORIG[path]
        assert s.count("Dspy.Signature.NumberParser.parse_number(value)") == 1, path
        open(path, "w").write(s.replace("Dspy.Signature.NumberParser.parse_number(value)", LEN_NUM))
    return apply

def debris_accept_branch():
    s = ORIG[NP]; a = "  defp do_parse(raw, :float) do\n"
    assert s.count(a) == 1
    inj = a + '    t = String.trim(raw)\n    if t == "80%" do\n      {:ok, 80.0}\n    else\n'
    rest = s.split(a, 1)[1]; body, tail = rest.split("\n  end\n", 1)
    open(NP, "w").write(s.split(a, 1)[0] + inj + body + "\n    end\n  end\n" + tail)

def debris_shared_true():
    s = ORIG[NP]
    m = re.search(r"  defp strict_shape\?\(value\) do\n.*?\n  end\n", s, re.S)
    open(NP, "w").write(s.replace(m.group(0), "  defp strict_shape?(value) do\n    true\n  end\n", 1))

def wrong_base_behaviour():
    # a plain behaviour bug, not harness debris: the float path now accepts a trailing '%'
    s = ORIG[NP]; old = "  defp do_parse(raw, :float) do\n"
    open(NP, "w").write(s.replace(old, old + '    raw = String.trim_trailing(raw, "%")\n', 1))

CASES = [
    ("clean tree (must NOT be refused)", None),
    ("debris: null-revert in signature.ex", debris_null_revert("lib/dspy/signature.ex")),
    ("debris: null-revert in chat.ex", debris_null_revert("lib/dspy/signature/adapters/chat.ex")),
    ("debris: null-revert in json.ex", debris_null_revert("lib/dspy/signature/adapters/json.ex")),
    ("debris: injected accept-branch", debris_accept_branch),
    ("debris: shared strict_shape? -> true", debris_shared_true),
    ("behavioural wrong base (not debris)", wrong_base_behaviour),
]
try:
    for name, apply in CASES:
        for f in FILES: open(f, "w").write(ORIG[f])
        if apply: apply()
        p = subprocess.Popen(["python3", H], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        verdict = "?"
        for line in p.stdout:
            if "refusing to start" in line: verdict = "REFUSED by pre-flight"; break
            if "base tree is RED" in line: verdict = "stopped by base-green"; break
            if line.startswith("BASE GREEN"): verdict = "PROCEEDED past both guards"; break
        p.kill(); p.wait()
        subprocess.run(["pkill", "-f", "mix test test/signature_number_integer_strict_test.exs"])
        print(f"{name:45} -> {verdict}")
finally:
    for f in FILES: open(f, "w").write(ORIG[f])
