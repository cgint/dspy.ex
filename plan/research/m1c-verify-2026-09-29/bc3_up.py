from dspy.predict.aggregation import majority
print("py 1 vs 1.0:", majority([{"answer":"2"},{"answer":"1"},{"answer":"1.0"}], field="answer", normalize=lambda x: x).completions[0]["answer"])
print("py true vs 1:", majority([{"answer":"2"},{"answer":True},{"answer":1}], field="answer", normalize=lambda x: x).completions[0]["answer"])
print("py true vs 1 (swapped):", majority([{"answer":1},{"answer":True},{"answer":"2"}], field="answer", normalize=lambda x: x).completions[0]["answer"])
print("py 1.0 vs 1 (order):", majority([{"answer":"1.0"},{"answer":1},{"answer":"x"}], field="answer", normalize=lambda x: x).completions[0]["answer"])
