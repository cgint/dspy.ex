from dspy.predict.aggregation import majority
r = majority([
    {"answer":"1","other":"1"},
    {"answer":"2","other":"1"},
    {"answer":"3","other":"2"},
], field="other", normalize=lambda x: x)
print("row3 upstream:", dict(r.completions[0]))
