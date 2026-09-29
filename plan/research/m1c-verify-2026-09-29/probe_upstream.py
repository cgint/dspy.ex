import dspy
from dspy.predict.aggregation import majority
print("field-test:", majority([{"answer":"2","other":"1"},{"answer":"2","other":"1"},{"answer":"3","other":"2"}], field="other").completions[0])
print("tie:", majority([{"answer":"b"},{"answer":"a"}], field="answer").completions[0])
print("interleaved:", majority([{"answer":"x"},{"answer":"y"},{"answer":"y"},{"answer":"x"}], field="answer").completions[0])
from dspy.evaluate import normalize_text
print("norm-orig:", majority([{"answer":"3"},{"answer":" 2"},{"answer":"2"}], normalize=normalize_text).completions[0])
print("py 1 vs 1.0:", majority([{"answer":"2"},{"answer":"1"},{"answer":"1.0"}], field="answer", normalize=lambda x: x).completions[0])
print("py true vs 1:", majority([{"answer":"2"},{"answer":True},{"answer":1}], field="answer", normalize=lambda x: x).completions[0])
print("py true vs 1 (swapped):", majority([{"answer":1},{"answer":True},{"answer":"2"}], field="answer", normalize=lambda x: x).completions[0])
print("py 1.0 vs 1 (order):", majority([{"answer":"1.0"},{"answer":1},{"answer":"x"}], field="answer", normalize=lambda x: x).completions[0])
