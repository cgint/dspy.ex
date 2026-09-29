# /// script
# requires-python = ">=3.10"
# dependencies = ["dspy==3.4.0"]
# ///
import json, os
from dspy.evaluate import normalize_text
xs = json.load(open(os.environ["BAT"]))
json.dump([normalize_text(x) for x in xs], open(os.environ["OUT"], "w"), ensure_ascii=True)
