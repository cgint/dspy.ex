"""Focused H12 preflight checks, run with Python's standard unittest runner."""

import re
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import mutate_h12


class PreflightTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        sources = {}
        for name in ("SIG", "CHAT", "JSON", "TARGET"):
            source = getattr(mutate_h12, name)
            self.assertTrue(source.is_file())
            copy = Path(directory.name) / source.name
            copy.write_bytes(source.read_bytes())
            sources[name] = copy
        self.sources = sources
        overrides = patch.multiple(mutate_h12, **sources)
        overrides.start()
        self.addCleanup(overrides.stop)

    def test_clean_sources(self):
        self.assertEqual([], mutate_h12.detect_leftovers())

    def test_missing_call_at_each_site_and_type(self):
        for site in ("SIG", "CHAT", "JSON"):
            for annotation in ("number", "integer"):
                with self.subTest(site=site, annotation=annotation):
                    path = self.sources[site]
                    original = path.read_text()
                    call = f"Dspy.Signature.NumberParser.parse_{annotation}(value)"
                    self.assertIn(call, original)
                    path.write_text(original.replace(call, "{:error, :invalid_numeric}"))
                    issues = mutate_h12.detect_leftovers()
                    path.write_text(original)
                    self.assertEqual([path], [file for file, _ in issues])

    def test_partial_injected_guard_at_each_type(self):
        path = self.sources["TARGET"]
        original = path.read_text()
        guards = {
            "float": ('t == "80%"', 't in ["true", "True", "False"]', 't in ["NaN", "inf"]'),
            "int": ('t == ",1"', 't in ["NaN", "inf"]'),
        }
        for annotation, branches in guards.items():
            for guard in branches:
                with self.subTest(annotation=annotation, guard=guard):
                    head = f"  defp do_parse(raw, :{annotation}) do\n"
                    self.assertIn(head, original)
                    fragment = f"{head}    t = String.trim(raw)\n    if {guard} do\n"
                    path.write_text(original.replace(head, fragment, 1))
                    self.assertEqual([path], [file for file, _ in mutate_h12.detect_leftovers()])
        path.write_text(original)

    def test_shared_shape_mutant_is_debris(self):
        path = self.sources["TARGET"]
        source, replacements = re.subn(
            r"^  defp strict_shape\?\(value\) do\n.*?^  end$",
            "  defp strict_shape?(value) do\n    true\n  end",
            path.read_text(),
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertEqual(1, replacements)
        path.write_text(source)
        self.assertEqual([path], [file for file, _ in mutate_h12.detect_leftovers()])


if __name__ == "__main__":
    unittest.main()
