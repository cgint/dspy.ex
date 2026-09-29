# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "dspy==3.4.0",
# ]
# ///

import json
import os
import string
import datetime
import unicodedata
import dspy
from dspy.evaluate.metrics import normalize_text, f1_score, answer_passage_match, answer_exact_match

def run():
    data = {
        "_meta": {
            "source": "dspy==3.4.0",
            "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "description": "Golden fixtures for upstream dspy metrics",
        },
        "normalize_text": {},
        "f1": {},
        "f1_list": {},
        "answer_passage_match": {},
        "answer_exact_match_tests": {},
    }

    # normalize_text
    nt_inputs = [
        "the banana theater",
        "the", "a", "an",
        "the cat",
        "  spaces  ",
        "\t\nnewlines\t",
        "café",
        unicodedata.normalize('NFD', "café"),
        "Straße",
        "—", "“ ”"
    ]
    for p in string.punctuation:
        nt_inputs.append(p)
        nt_inputs.append(f"word{p}word")

    # Greta's battery (plan/research/m1b-verdict-2026-09-29/nt_battery2.json) —
    # awkward inputs (combining marks, Greek, ligatures, unicode spaces, CJK,
    # emoji, symbols) that expose the difference between Python and PCRE
    # lowercasing / word-boundary / whitespace semantics. Inputs chosen by us;
    # answers computed BY UPSTREAM.
    battery_path = "plan/research/m1b-verdict-2026-09-29/nt_battery2.json"
    if os.path.exists(battery_path):
        nt_inputs.extend(json.load(open(battery_path)))

    for i in nt_inputs:
        data["normalize_text"][i] = normalize_text(i)

    # f1 (pairwise string->string)
    # Cases: repeated tokens, no-overlap, both-sides-empty, cat dog/cat bird, Eiffel Tower
    f1_cases = [
        ("the cat cat", "cat", "repeated tokens"),
        ("no overlap", "at all", "no overlap"),
        (" ", " ", "empty both sides"),
        ("cat dog", "cat bird", "cat dog vs cat bird"),
        ("Eiffel Tower is in Paris", "Paris", "Eiffel Tower"),
        # M1-b row 11 discriminator: both sides contain the same token at least
        # twice, so multiset overlap (min counts) differs from set overlap.
        ("cat cat dog", "cat cat bird", "repeated-token discriminator"),
        # B2: whitespace-collapse discriminator (tab/newline inputs, row 10).
        ("a\tb\nc", "a b c", "tab/newline collapse"),
        ("a b c", "a\tb\nc", "tab/newline collapse (other side)"),
    ]
    for pred, gt, label in f1_cases:
        try:
            val = f1_score(pred, gt)
        except Exception as e:
            val = str(e)
        key = f"{pred} | {gt}"
        data["f1"][key] = val

    # B2: the ORACLE for f1/2's list-taking API. Upstream's public metric is
    # `F1 = lambda pred, answers: max(f1_score(pred, a) for a in answers)` —
    # generate expected values via the LIST form so the fixture pins
    # "max over ALL answers" (not "first answer only"). The old fixture's
    # "answer | ['ans', 'answer']" entry is a generator artefact (pairwise
    # f1_score called with a list -> Python error message) and is removed.
    f1_list_cases = [
        ("answer", ["ans", "answer"]),          # max wins (0.5 > 0.25); first-only would give 0.25
        ("cat dog", ["cat bird", "cat dog"]),   # second answer is exact -> max 1.0; first-only 0.5
        ("cat dog", ["cat bird", "nope"]),      # first answer is the max -> 0.5; pins "not last only"
        ("", [""]),                            # both-empty via list -> 0.0
        ("Eiffel Tower is in Paris", ["Paris", "Louvre"]),  # docstring-style multi-answer
    ]
    for pred, answers in f1_list_cases:
        val = max(f1_score(pred, a) for a in answers) if answers else 0.0
        data["f1_list"][f"{pred} | {answers}"] = val

    # answer_passage_match
    apm_cases = [
        {"ans": "multi token", "ctx": ["some multi token passage"]},
        {"ans": "art", "ctx": ["we have a party"]},
        {"ans": "Paris.", "ctx": ["He lives in Paris."]},
        {"ans": "ans", "ctx": []},
        {"ans": ["first", "second", "third"], "ctx": ["this has a third answer"]},
        {"ans": "ans", "ctx": "bare string context"},
        # M1-b row 14 addition (controller Ruth 2026-09-29): the "multi token"
        # case above only distinguishes DPR tokenization from whitespace
        # splitting — a String.contains? (SUBSTRING) implementation passes it
        # too. case_6 does not:
        {"ans": "Eiffel Tower", "ctx": ["This is the eiffel a tower building."], "note": "non-contiguous as substring"},
        # Greta's battery (plan/research/m1b-verdict-2026-09-29/apm_battery.json)
        # — DPR-sensitive inputs (unicode punctuation as tokens, accents,
        # empty-answer quirk, Greek, CJK, unicode spaces, half/roman numerals).
    ]
    apm_battery_path = "plan/research/m1b-verdict-2026-09-29/apm_battery.json"
    if os.path.exists(apm_battery_path):
        for ans, ctx in json.load(open(apm_battery_path)):
            apm_cases.append({"ans": ans, "ctx": ctx})

    for i, case in enumerate(apm_cases):
        example = dspy.Example(answer=case["ans"])
        pred = dspy.Prediction(context=case["ctx"])
        try:
            val = answer_passage_match(example, pred)
        except Exception as e:
            val = f"ERROR: {e}"
        key = f"case_{i}"
        data["answer_passage_match"][key] = {
            "case": {"ans": case["ans"], "ctx": case["ctx"]},
            "expected": val,
        }

    # answer_exact_match_tests
    aem_cases = [
        {"ans": "2", "pred": "2"},
        {"ans": ["2", "two"], "pred": "2"},
        {"ans": "2", "pred": "3"}
    ]
    for i, case in enumerate(aem_cases):
        example = dspy.Example(answer=case["ans"])
        pred = dspy.Prediction(answer=case["pred"])
        val = answer_exact_match(example, pred)
        key = f"{case['ans']} | {case['pred']}"
        data["answer_exact_match_tests"][key] = val

    # M1-b row 4 (G): "any answer in the list matches" — ['2', 'two'] vs pred
    # "two" must be true (a first-answer-only implementation fails this).
    example = dspy.Example(answer=["2", "two"])
    pred = dspy.Prediction(answer="two")
    data["answer_exact_match_tests"]["['2', 'two'] | two"] = answer_exact_match(example, pred)

    with open("test/fixtures/upstream_metrics_3_4_0.json", "w") as f:
        json.dump(data, f, indent=2)

if __name__ == "__main__":
    run()
