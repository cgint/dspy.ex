import inspect
from dspy.predict import aggregation
print(inspect.getsource(aggregation.majority)[:600])
