# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "dspy==3.4.0",
# ]
# ///
#
# Golden fixture for M1-c (Dspy.majority). Runs dspy.majority from DSPy 3.4.0
# over the upstream oracle cases (tests/predict/test_aggregation.py) and the
# tie/normalisation vectors named by the acceptance map, and writes
# test/fixtures/upstream_majority_3_4_0.json.
#
# Python is a fixture-generation tool only: `mix test` and CI never run it.
# Re-run and diff against the committed fixture as part of review (M1-b rule:
# a generated fixture can silently record an error as an expected value).

import json
import datetime
import dspy
from dspy.predict.aggregation import majority
from dspy.evaluate import normalize_text


def winning_answer(completions, **kwargs):
    """Run upstream majority and return the winner's answer field.

    Upstream returns Prediction.from_completions([completion], ...); we read
    the winner back through the same .completions[0] access the upstream
    oracle tests use.
    """
    return majority(completions, **kwargs).completions[0]["answer"]


def run():
    data = {
        "_meta": {
            "source": "dspy==3.4.0",
            "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "description": "Golden fixtures for upstream dspy.majority",
            "note": "Every expected value is the winner's answer field from "
                    "dspy.majority(...).completions[0]['answer']. A string "
                    "value starting with 'ERROR:' would be a generator "
                    "artefact, not an expected value — the consumer test "
                    "asserts no such entry exists.",
        },
        "oracle": {},
        "tie": {},
        "normalise": {},
    }

    # [T] ports of tests/predict/test_aggregation.py (the Prediction/Completions
    # forms are their LIST form, per the C1 ruling — same data, same assertion).
    data["oracle"][
        "[{'answer': '2'}, {'answer': '2'}, {'answer': '3'}] default"
    ] = winning_answer([{"answer": "2"}, {"answer": "2"}, {"answer": "3"}])
    data["oracle"][
        "[{'answer': '2'}, {'answer': ' 2'}, {'answer': '3'}] normalize_text"
    ] = winning_answer(
        [{"answer": "2"}, {"answer": " 2"}, {"answer": "3"}], normalize=normalize_text
    )
    data["oracle"][
        "[{'answer': '2', 'other': '1'}, {'answer': '2', 'other': '1'}, "
        "{'answer': '3', 'other': '2'}] field='other'"
    ] = winning_answer(
        [
            {"answer": "2", "other": "1"},
            {"answer": "2", "other": "1"},
            {"answer": "3", "other": "2"},
        ],
        field="other",
    )
    data["oracle"][
        "[{'answer': '2'}, {'answer': '3'}, {'answer': '4'}] default"
    ] = winning_answer([{"answer": "2"}, {"answer": "3"}, {"answer": "4"}])

    # [G] tie vectors (acceptance rows 5, 5b).
    data["tie"][
        "[{'answer': 'b'}, {'answer': 'a'}] default"
    ] = winning_answer([{"answer": "b"}, {"answer": "a"}])
    data["tie"][
        "[{'answer': 'x'}, {'answer': 'y'}, {'answer': 'y'}, {'answer': 'x'}] default"
    ] = winning_answer(
        [{"answer": "x"}, {"answer": "y"}, {"answer": "y"}, {"answer": "x"}]
    )
    data["tie"][
        "[{'answer': '9'}, {'answer': 'a'}] default"
    ] = winning_answer([{"answer": "9"}, {"answer": "a"}])

    # [G] normalisation vectors (rows 6, 10).
    data["normalise"][
        "[{'answer': '3'}, {'answer': ' 2'}, {'answer': '2'}] normalize_text"
    ] = winning_answer(
        [{"answer": "3"}, {"answer": " 2"}, {"answer": "2"}], normalize=normalize_text
    )
    data["normalise"][
        "[{'answer': '!!'}, {'answer': '!!'}, {'answer': '3'}] default"
    ] = winning_answer([{"answer": "!!"}, {"answer": "!!"}, {"answer": "3"}])

    # [G] vote-equality vectors (BC3, 2026-09-29 BLOCK): numbers compare as
    # numbers (1 and 1.0 are one vote, as in Python); True and 1 are the SAME
    # vote in Python (the declared deviation: Elixir == does not fold them).
    # Nil-value vector (BC2): a present nil vote is ignored under an identity
    # normaliser; with the DEFAULT normaliser upstream raises (TypeError), so
    # it is NOT a fixture row — the Elixir side pins the raise in a test.
    data["vote_equality"] = {}
    data["vote_equality"][
        "[{'answer': '2'}, {'answer': 1}, {'answer': 1.0}] identity"
    ] = winning_answer(
        [{"answer": "2"}, {"answer": 1}, {"answer": 1.0}], normalize=lambda x: x
    )
    data["vote_equality"][
        "[{'answer': '2'}, {'answer': True}, {'answer': 1}] identity"
    ] = winning_answer(
        [{"answer": "2"}, {"answer": True}, {"answer": 1}], normalize=lambda x: x
    )
    data["vote_equality"][
        "[{'answer': 1}, {'answer': True}, {'answer': '2'}] identity"
    ] = winning_answer(
        [{"answer": 1}, {"answer": True}, {"answer": "2"}], normalize=lambda x: x
    )
    data["vote_equality"][
        "[{'answer': '1.0'}, {'answer': 1}, {'answer': 'x'}] identity"
    ] = winning_answer(
        [{"answer": "1.0"}, {"answer": 1}, {"answer": "x"}], normalize=lambda x: x
    )
    data["vote_equality"][
        "[{'answer': None}, {'answer': 'a'}] identity"
    ] = winning_answer(
        [{"answer": None}, {"answer": "a"}], normalize=lambda x: x
    )

    print(json.dumps(data, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    run()
