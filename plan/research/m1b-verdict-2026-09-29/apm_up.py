# /// script
# requires-python = ">=3.10"
# dependencies = ["dspy==3.4.0"]
# ///
import json, os, dspy
from dspy.evaluate import answer_passage_match
cases = json.load(open(os.environ["BAT"]))
out = []
for ans, ctx in cases:
    try: out.append(bool(answer_passage_match(dspy.Example(answer=ans), dspy.Prediction(context=ctx))))
    except Exception as e: out.append("RAISE " + type(e).__name__)
json.dump(out, open(os.environ["OUT"], "w"))
