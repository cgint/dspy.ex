# /// script
# requires-python = ">=3.10"
# dependencies = ["dspy==3.4.0"]
# ///
# Probe upstream DSPy 3.4.0 Evaluate behaviour for Q2/Q3/Q-OUT. Run: uv run tmp/pyck/ck.py
import dspy, tempfile
print("dspy", dspy.__version__)
class P(dspy.Module):
    def forward(self, q): return dspy.Prediction(a=q)
ex = [dspy.Example(q=str(i), a=str(i)).with_inputs("q") for i in range(3)]
def run(name, devset, metric, prog=None, **kw):
    try:
        r = dspy.Evaluate(devset=devset, metric=metric, num_threads=1, display_progress=False, **kw)(prog or P())
        print(name, "-> OK score", r.score, [x[2] for x in r.results])
    except Exception as e:
        print(name, "-> RAISE", type(e).__name__, str(e)[:120])
for v in [None, "text", {"k": 1}, True]:
    run(f"Q2 metric returns {v!r}", ex, lambda e, p, t=None, v=v: v)
run("Q2 metric raises", ex, lambda e, p, t=None: 1 / 0)
run("Q3 empty devset", [], lambda e, p, t=None: 1.0)
d = tempfile.mkdtemp(dir=".")
class R(dspy.Module):
    def __init__(s): super().__init__(); s.i = 0
    def forward(s, q):
        s.i += 1
        return dspy.Prediction(a=q, extra=1) if s.i == 2 else dspy.Prediction(a=q)
run("OUT ragged csv", ex, lambda e, p, t=None: 1.0, prog=R(), save_as_csv=f"{d}/r.csv")
class O(dspy.Module):
    def forward(s, q): return dspy.Prediction(a=q, obj=object())
run("OUT non-json", ex, lambda e, p, t=None: 1.0, prog=O(), save_as_json=f"{d}/r.json")
