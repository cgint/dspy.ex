# /// script
# requires-python = ">=3.10"
# dependencies = ["dspy==3.4.0"]
# ///
import json, os
from dspy.evaluate.metrics import EM, F1
for pred, gold in json.load(open(os.environ["PAIRS"])):
    print(f"UPSTREAM\t{json.dumps(pred, ensure_ascii=False)}\t{json.dumps(gold, ensure_ascii=False)}\tEM={1.0 if EM(pred,[gold]) else 0.0}\tF1={round(float(F1(pred,[gold])),3)}")
