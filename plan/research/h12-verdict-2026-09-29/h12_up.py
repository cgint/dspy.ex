# /// script
# requires-python = ">=3.10"
# dependencies = ["dspy==3.4.0"]
# ///
import json, os
from dspy.adapters.utils import parse_value
out = {}
for t, ann in (("float", float), ("int", int)):
    r = []
    for s in json.load(open(os.environ["BAT"])):
        try: v = parse_value(s, ann); r.append(repr(float(v)) if t == "float" else repr(int(v)))
        except Exception as e: r.append("REJECT")
    out[t] = r
json.dump(out, open(os.environ["OUT"], "w"))
