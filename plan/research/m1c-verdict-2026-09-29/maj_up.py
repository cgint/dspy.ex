# /// script
# requires-python = ">=3.10"
# dependencies = ["dspy==3.4.0"]
# ///
import json, os
from dspy.predict.aggregation import majority, default_normalize
N = {"identity": None, "default": default_normalize,
     "nil_for_x": lambda v: None if v == "x" else v, "false_for_x": lambda v: False if v == "x" else v,
     "num": lambda v: {"1": 1, "1.0": 1.0, "2": 2}[v], "bool_num": lambda v: {"t": True, "one": 1, "z": "z"}[v],
     "all_nil": lambda v: None}
out = []
for c in json.load(open(os.environ["BAT"])):
    comps = [{"answer": v} for v in c["vals"]]
    try:
        r = majority(comps, normalize=N[c["norm"]], field="answer")
        out.append(r.completions[0]["answer"])
    except Exception as e:
        out.append("RAISE " + type(e).__name__)
json.dump(out, open(os.environ["OUT"], "w"))
