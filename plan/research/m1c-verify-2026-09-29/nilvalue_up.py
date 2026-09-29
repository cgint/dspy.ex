from dspy.predict.aggregation import majority
# BC2: nil value vote, identity normaliser
print("py nil vs a (identity):", majority([{"answer":None},{"answer":"a"}], field="answer", normalize=lambda x: x).completions[0]["answer"])
# BC2: default normaliser on nil should raise (upstream normalize_text(None) -> TypeError)
try:
    r = majority([{"answer":None},{"answer":"a"}], field="answer")
    print("py nil default: NO RAISE", r.completions[0]["answer"])
except Exception as e:
    print("py nil default: RAISES", type(e).__name__)
