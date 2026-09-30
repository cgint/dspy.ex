# /// script
# requires-python = ">=3.10"
# dependencies = ["dspy==3.4.0", "datasets", "pandas"]
# ///
# Greta probe (M1-e contract, first run 2026-09-28, re-run 2026-09-30): how does upstream DSPy 3.4.0
# DataLoader.from_csv / from_json treat edge cases? Prints raw observations only. Seed for the committed
# generator plan/research/upstream_golden/gen_m1e_golden.py (to be written by the M1-e team).
import os, tempfile, json, warnings
warnings.filterwarnings("ignore")
import dspy
from dspy.datasets.dataloader import DataLoader

dl = DataLoader()
d = tempfile.mkdtemp()


def w(name, text):
    p = os.path.join(d, name)
    with open(p, "w", newline="") as f:
        f.write(text)
    return p


def show(label, fn):
    try:
        out = fn()
        print(f"{label}: OK {[dict(e.items(include_dspy=True)) for e in out]}")
    except Exception as e:
        print(f"{label}: RAISE {type(e).__name__}: {str(e)[:200]}")


show("csv numbers", lambda: dl.from_csv(w("a.csv", "q,n,f,b\nx,2,1.5,True\ny,3,2.0,False\n")))
show("csv empty cell + quoted empty", lambda: dl.from_csv(w("b.csv", 'q,a\nx,\ny,""\n')))
show("csv short row", lambda: dl.from_csv(w("c.csv", "q,a\nx\ny,2\n")))
show("csv long row", lambda: dl.from_csv(w("d.csv", "q,a\nx,1,EXTRA\n")))
show("csv blank line", lambda: dl.from_csv(w("e.csv", "q,a\nx,1\n\ny,2\n")))
show("csv dup header", lambda: dl.from_csv(w("f.csv", "a,a\n1,2\n")))
show("csv BOM", lambda: dl.from_csv(w("g.csv", "﻿q,a\nx,1\n")))
show("csv CRLF + embedded newline", lambda: dl.from_csv(w("h.csv", 'q,a\r\n"l1\nl2","say ""hi"""\r\n')))
show("csv fields subset", lambda: dl.from_csv(w("i.csv", "q,a,z\nx,1,9\n"), fields=["a", "q"]))
show("csv unknown field", lambda: dl.from_csv(w("j.csv", "q,a\nx,1\n"), fields=["nope"]))
show("csv whitespace", lambda: dl.from_csv(w("k.csv", "q,a\n x , y \n")))
show("json array", lambda: dl.from_json(w("a.json", json.dumps([{"q": "x", "a": 1}, {"q": "y", "a": 2}]))))
show("jsonl", lambda: dl.from_json(w("b.jsonl", '{"q":"x","a":1}\n{"q":"y","a":2}\n')))
show("jsonl union keys", lambda: dl.from_json(w("c.jsonl", '{"q":"x","a":1}\n{"q":"y","b":true}\n')))
show("jsonl nested", lambda: dl.from_json(w("d.jsonl", '{"q":"x","m":{"k":[1,2]}}\n')))
show("jsonl non-object line", lambda: dl.from_json(w("e.jsonl", '{"q":"x"}\n[1,2]\n')))
show("json null", lambda: dl.from_json(w("f.jsonl", '{"q":"x","a":null}\n')))
ex = [dspy.Example(i=i) for i in range(10)]
print("train_test_split seed 0:", {k: [e.i for e in v] for k, v in dl.train_test_split(ex, train_size=0.7, random_state=0).items()})
