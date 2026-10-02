# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "dspy==3.4.0",
# ]
# ///
"""M1-d SS2: golden for the four upstream auto-evaluation judge signatures.

Extracts, from dspy 3.4.0 `dspy.evaluate.auto_evaluation`, for each of the
four signature classes: the instruction text (the class `__doc__`) and the
field list (name, type, desc, is_input) in declaration order.

Output: `test/fixtures/upstream_m1d_auto_eval_3_4_0.json` — one key per
signature name, each holding `instruction` and `fields`.

The Elixir side maps upstream `float` -> `:number` and `str` -> `:string`
(mapped at test time, not here: the fixture records what upstream declares).
"""

import datetime
import json
import re

from dspy.evaluate.auto_evaluation import (
    AnswerCompleteness,
    AnswerGroundedness,
    DecompositionalSemanticRecallPrecision,
    SemanticRecallPrecision,
)
SIGS = [
    SemanticRecallPrecision,
    DecompositionalSemanticRecallPrecision,
    AnswerCompleteness,
    AnswerGroundedness,
]


def field_entry(cls, name: str) -> dict:
    import typing

    info = cls.model_fields[name]
    # dspy 3.4.0 stores `desc` and `__dspy_field_type` in `json_schema_extra`
    # (set by InputField/OutputField via pydantic's Field()).
    extra = info.json_schema_extra or {}
    annotation = typing.get_type_hints(cls)[name]
    is_input = extra.get("__dspy_field_type") == "input"
    return {
        "name": name,
        "type": annotation.__name__,
        "desc": extra.get("desc") or "",
        "is_input": is_input,
    }


def run() -> None:
    data = {
        "_meta": {
            "source": "dspy==3.4.0",
            "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "module": "dspy.evaluate.auto_evaluation",
            "description": "M1-d golden: the four auto-evaluation judge signatures "
            "(instruction = class __doc__, fields in declaration order). "
            "Upstream float -> :number and str -> :string on the Elixir side.",
        }
    }

    for cls in SIGS:
        # The instruction is the class docstring with the Python indentation
        # stripped (dspy itself does this when rendering the prompt; our
        # Signature DSL stores the text verbatim after String.trim, so the
        # golden records the de-indented, whitespace-collapsed text).
        doc = re.sub(r"\s+", " ", (cls.__doc__ or "").strip()).strip()
        fields = []
        for name in cls.model_fields:
            fields.append(field_entry(cls, name))

        data[cls.__name__] = {"instruction": doc, "fields": fields}
        print(
            f"{cls.__name__}: instruction {len(doc)} chars, "
            f"{len(fields)} fields "
            f"({sum(1 for f in fields if f['is_input'])} in / "
            f"{sum(1 for f in fields if not f['is_input'])} out)"
        )

    with open("test/fixtures/upstream_m1d_auto_eval_3_4_0.json", "w") as f:
        json.dump(data, f, indent=2)

    print(
        f"Wrote test/fixtures/upstream_m1d_auto_eval_3_4_0.json "
        f"({len(SIGS)} signatures)"
    )


if __name__ == "__main__":
    run()
