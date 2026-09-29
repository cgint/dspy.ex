# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "dspy==3.4.0",
# ]
# ///
"""Golden generator for H12 (2026-09-29).

Runs upstream dspy 3.4.0 `dspy.adapters.utils.parse_value(s, float)` /
`parse_value(s, int)` over the H12 case battery and writes
`test/fixtures/upstream_h12_parse_value_3_4_0.json`.

Python is a fixture-generation TOOL only — `mix test` and CI never execute
this script (the permanent no-wrapper ban is untouched: no Python runtime in
lib/ or tests/).

The battery is the union of:
- the H12 queue-row must-accept / must-reject lists;
- the controller probe edge cases (plan/research/pi_handoffs/h12/logs/h12_probe2.py);
- Horst's three ruled cases (NaN/inf variants, true/True/False -> REJECT declared
  deviation; 0x10 -> match upstream).

`declared_deviation: true` marks rows where we intentionally reject what upstream
accepts (Horst rulings 2026-09-29, corrupt-or-lose principle):
  - "NaN"/"nan"/"NAN"/"inf"/"-inf"/"INF"/"+inf" (BEAM floats cannot represent them;
    upstream's judge clamp would turn NaN into a perfect 1.0)
  - "true"/"True"/"False" (pydantic boolean-word coercion)
Everything else must match the upstream verdict exactly.

Re-run + diff against the committed fixture is a review gate (M1-b lesson:
a generated fixture once recorded a Python error message as an expected value).
"""

import datetime
import json

from dspy.adapters.utils import parse_value

# (input_string, annotation)
CASES = [
    # ---- queue-row must-accept (:number)
    ("0.8", float),
    (" 0.8 ", float),
    ("0.8\n", float),
    ("1", float),
    ("-0.2", float),
    (".5", float),
    ("5.", float),
    ("1e-1", float),
    ("1E3", float),
    ("+0.5", float),
    ('"0.8"', float),
    ("1_000", float),
    # ---- queue-row must-accept (:integer)
    ("1", int),
    (" 1 ", int),
    ("1\n", int),
    # ---- controller probe edge battery (both annotations)
    ("10", float),
    ("10", int),
    ("\t-2.5e+3 ", float),
    ("\t-2.5e+3 ", int),
    ("3.", float),
    ("3.", int),
    ("+1e2", float),
    ("+1e2", int),
    ("1_0", float),
    ("1_0", int),
    ("010", float),
    ("010", int),
    ("007", float),
    ("007", int),
    ("12345.6", float),
    ("12345.6", int),
    ("1,000", float),
    ("1,000", int),
    ("80%", float),
    ("80%", int),
    ("1/2", float),
    ("1/2", int),
    ("0.8/1.0", float),
    ("0.8/1.0", int),
    ("0.8 (high)", float),
    ("0.8 (high)", int),
    ("about 0.8", float),
    ("about 0.8", int),
    ("0,8", float),
    ("0,8", int),
    ("12,345.6", float),
    ("12,345.6", int),
    ("N/A", float),
    ("N/A", int),
    ("", float),
    ("", int),
    (" ", float),
    (" ", int),
    ("[0.8]", float),
    ("[0.8]", int),
    ("(0.8)", float),
    ("(0.8)", int),
    ("0.8.1", float),
    ("0.8.1", int),
    ("null", float),
    ("null", int),
    ("None", float),
    ("None", int),
    # ---- Horst ruling 1: NaN/inf (upstream ACCEPTS; we REJECT — declared deviation)
    ("NaN", float),
    ("nan", float),
    ("NAN", float),
    ("inf", float),
    ("-inf", float),
    ("INF", float),
    ("+inf", float),
    ("NaN", int),
    ("nan", int),
    ("NAN", int),
    ("inf", int),
    ("-inf", int),
    ("INF", int),
    ("+inf", int),
    # ---- Horst ruling 2: boolean words (upstream coerces; we REJECT — declared deviation)
    ("true", float),
    ("True", float),
    ("False", float),
    ("true", int),
    ("True", int),
    ("False", int),
    # ---- Horst ruling 3: 0x literals (MATCH upstream — parity, no deviation)
    ("0x10", float),
    ("0x10_0", float),
    ("0b101", float),
    ("0x10", int),
    ("0x10_0", int),
    ("0b101", int),
    ("0x", float),
    ("0x", int),
    ("0b", float),
    ("0b", int),
    # ---- Ruling 2 follow-ups (same literals for both annotations; int quirks)
    (".", float),
    (".", int),
    ("+", float),
    ("+", int),
    ("-", float),
    ("-", int),
    ("+.", float),
    ("+.", int),
    ("-.", float),
    ("-.", int),
    ("1.0", float),
    ("1.0", int),
    ("2.0", float),
    ("2.0", int),
    ("1.5", float),
    ("1.5", int),
    ("0.0", float),
    ("0.0", int),
    ("-0.0", float),
    ("-0.0", int),
    ("1_000_000", float),
    ("1_000_000", int),
    ("_1", float),
    ("_1", int),
    ("1_", float),
    ("1_", int),
    ("0xG", float),
    ("0xG", int),
    ("0x10G", float),
    ("0x10G", int),
    ("1e", float),
    ("1e", int),
    ("1e-", float),
    ("1e-", int),
    ("1e+", float),
    ("1e+", int),
    ("1.2.3.4", float),
    ("1.2.3.4", int),
    ("1 000", float),
    ("1 000", int),
    ("1,000.5", float),
    ("1,000.5", int),
    ("2e2", float),
    ("2e2", int),
    ("1d3", float),
    ("1d3", int),
    ("1f", float),
    ("1f", int),
    ("'", float),
    ("'", int),
    ("+2", int),
    ("-3", int),
    ("0.8", int),
    (" 0.8 ", int),
    ("0.8\n", int),
    ("-0.2", int),
    (".5", int),
    ("1e-1", int),
    ("+0.5", int),
    ("1E3", int),
    # ---- HB2 (2026-09-29, Greta review): one-sign, quote-parity, 5.e3/.5e3,
    #      underscore exponents, signed hex/binary, quoted forms. All verdicts
    #      from the upstream probe (hb2_probe.py), NOT hand-written.
    ("+-1", float),
    ("+-1", int),
    ("+-1.5", float),
    ("+-1.5", int),
    ("-+1", float),
    ("-+1", int),
    ("++1", float),
    ("++1", int),
    ("--1", float),
    ("--1", int),
    ("++0.5", float),
    ("\"5\"", int),
    ("\"5\"", float),
    ("\"0.8\"", int),
    ("\" 5 \"", int),
    ("\" 5 \"", float),
    ("\"5 \"", float),
    ("\" 5\"", float),
    ("\" -3 \"", int),
    ("\" -3 \"", float),
    ("\"(5)\"", float),
    ("\"(5)\"", int),
    ("  \"5\"  ", float),
    ("  \"5\"  ", int),
    ("5.e3", float),
    ("5.e3", int),
    (".5e3", float),
    (".5e3", int),
    ("5.e-3", float),
    ("5.e", float),
    ("1e1_0", float),
    ("1e1_0", int),
    ("1e_1", float),
    ("1E_1", float),
    ("-0x10", float),
    ("-0x10", int),
    ("-0b1", float),
    ("-0b1", int),
    ("+0x10", float),
    ("+0x10", int),
    ("-0X10", float),
    ("-0X10", int),
    ("0x-10", float),
    ("\"010\"", int),
    ("\"010\"", float),
    ("\"1E3\"", int),
    ("\"1E3\"", float),
    ("\"2.0\"", int),
    ("\"2.0\"", float),
    ("\"1_000\"", int),
    ("\"1_000\"", float),
    ("\"0x10\"", int),
    ("\"0x10\"", float),
    # ---- HB3 (2026-09-29): comma cases that ARE killable (upstream rejects),
    #      so the M9a/M9b mutations are real, not "unkillable by construction".
    (",1", float),
    (",1", int),
    ("1,", float),
    ("1,", int),
    # ---- HB7 (2026-09-29): claims in COMPATIBILITY.md checked against the
    #      fixture. (a) +1e+10 (sign before the exponent) — accepted by upstream.
    #      (b) bare parens (5)/(-2) on :integer — UPSTREAM ACCEPTS these
    #          (integer-valued, not fractional); only (0.8) rejects, and only
    #          because it is fractional, NOT because of the parens.
    #      (d) the quoted-hex cases already above; this block is the evidence
    #          the COMPATIBILITY text is written from.
    ("+1e+10", float),
    ("+1e+10", int),
    ("(5)", float),
    ("(5)", int),
    ("(-2)", float),
    ("(-2)", int),
    # ---- HB8 (2026-09-29): octal (0o17 / 0O17) and parenthesised integers
    #      ((5), (-2)) MATCH upstream (accept). Parity is the rule; a Python
    #      literal accident that harms nobody gets matched, not "improved".
    #      Same reasoning as the 0x10 ruling. These were REJECTIONS of valid
    #      input that fail loudly (never corrupt), but parity means both ways.
    ("0o17", float),
    ("0o17", int),
    ("0O17", float),
    ("0O17", int),
    ("-0o17", float),
    ("-0o17", int),
    ("-0O17", float),
    ("-0O17", int),
    # Quoted radix forms (HB7/HB8): upstream rejects a radix literal that
    # arrived IN QUOTE MARKS on BOTH :number and :integer — "0x10" (above),
    # "0b101", and "0o17" all reject. The quote is part of the answer text;
    # the value inside is not treated as a bare literal.
    ("\"0x10\"", int),
    ("\"0x10\"", float),
    ("\"0b101\"", int),
    ("\"0b101\"", float),
    ("\"0o17\"", int),
    ("\"0o17\"", float),
]

# Inputs whose upstream acceptance is a declared deviation (we reject).
DECLARED_DEVIATION_INPUTS = {
    "NaN", "nan", "NAN", "inf", "-inf", "INF", "+inf",
    "true", "True", "False",
}


def _float_from_hex_or_marker(hex_str: str):
    """Decode a Python float.hex() string; return nan/inf for the special markers."""
    if not hex_str:
        return None
    h = hex_str.lower()
    if h == "nan":
        return float("nan")
    if h == "inf":
        return float("inf")
    if h == "-inf":
        return float("-inf")
    return float.fromhex(hex_str)


def main() -> None:
    data = {
        "_meta": {
            "source": "dspy==3.4.0",
            "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "function": "dspy.adapters.utils.parse_value",
            "description": (
                "H12 golden: upstream parse_value(s, float|int) verdicts. "
                "declared_deviation rows are intentional rejections ruled by Horst "
                "2026-09-29 (corrupt-or-lose principle)."
            ),
        }
    }

    rows = []
    for value, annotation in CASES:
        ann_name = "float" if annotation is float else "int"
        try:
            parsed = parse_value(value, annotation)
            if annotation is float:
                # hex encoding is exact for every IEEE-754 double
                expected = {"type": "float", "value_hex": parsed.hex()}
            else:
                expected = {"type": "int", "value": parsed}
        except Exception as e:  # upstream rejects
            expected = {"raises": True, "type": ann_name, "error_type": type(e).__name__}
        else:
            expected["raises"] = False

        row = {
            "input": value,
            "annotation": ann_name,
            "upstream": expected,
        }
        # NaN/inf are not JSON-serializable; they can never be our expected value
        # (we reject them), so record the upstream verdict as a marker string.
        if not expected.get("raises") and expected["type"] == "float":
            v = _float_from_hex_or_marker(expected.get("value_hex"))
            if isinstance(v, float) and (v != v or v in (float("inf"), float("-inf"))):
                marker = "nan" if v != v else ("inf" if v > 0 else "-inf")
                expected["value_marker"] = marker
                expected.pop("value_hex", None)
        if value in DECLARED_DEVIATION_INPUTS and not expected.get("raises"):
            row["declared_deviation"] = True
        rows.append(row)

    data["cases"] = rows
    with open("test/fixtures/upstream_h12_parse_value_3_4_0.json", "w") as f:
        json.dump(data, f, indent=2)
    print(f"wrote {len(rows)} rows")


if __name__ == "__main__":
    main()
