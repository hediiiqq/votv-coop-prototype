import importlib.util
import pathlib
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "research.py"
SPEC = importlib.util.spec_from_file_location("research", MODULE_PATH)
research = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(research)


VALID_RESPONSE = """RESEARCH RESULT

Question:
What changed?

Sources:
1. https://example.com/primary

Summary:
Confirmed fact.

Important changes:
One change.

Recommendation:
Verify independently.
"""


class ResearchTests(unittest.TestCase):
    def test_empty_question_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "empty"):
            research.build_prompt("   ")

    def test_prompt_requires_primary_sources_and_fact_boundaries(self):
        prompt = research.build_prompt("Current API behavior?")
        for literal in (
            "RESEARCH RESULT",
            "Question:",
            "Sources:",
            "Summary:",
            "Important changes:",
            "Recommendation:",
            "official primary sources",
            "direct HTTP/HTTPS URLs",
            "confirmed facts",
            "inferences",
            "uncertainty",
        ):
            self.assertIn(literal, prompt)

    def test_safe_slug_contains_only_bounded_safe_characters(self):
        slug = research.safe_slug('  Привет / CON: "API" ??? ')
        self.assertRegex(slug, r"^[a-z0-9-]{1,60}$")
        self.assertNotIn("con", slug)

    def test_create_artifact_is_offline_and_timestamped(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            research.webbrowser, "open"
        ) as opener:
            path = research.create_artifact("Current docs?", pathlib.Path(directory))
            self.assertTrue(path.exists())
            self.assertRegex(path.name, r"^\d{8}-\d{6}-current-docs\.md$")
            self.assertIn("Current docs?", path.read_text(encoding="utf-8"))
            opener.assert_not_called()

    def test_create_artifact_never_overwrites_same_second_result(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            research.dt, "datetime"
        ) as clock:
            clock.now.return_value.strftime.return_value = "20260826-120000"
            first = research.create_artifact("Same question?", pathlib.Path(directory))
            first.write_text("preserve me", encoding="utf-8")
            second = research.create_artifact("Same question?", pathlib.Path(directory))
            self.assertNotEqual(first, second)
            self.assertEqual("preserve me", first.read_text(encoding="utf-8"))

    def test_valid_response_passes_with_truth_warning(self):
        errors = research.validate_response(VALID_RESPONSE)
        self.assertEqual([], errors)

    def test_missing_sources_section_fails(self):
        errors = research.validate_response(VALID_RESPONSE.replace("Sources:", "References:"))
        self.assertTrue(any("Sources" in error for error in errors))

    def test_missing_url_fails(self):
        errors = research.validate_response(VALID_RESPONSE.replace("https://example.com/primary", "none"))
        self.assertTrue(any("HTTP/HTTPS" in error for error in errors))

    def test_default_cli_does_not_open_browser(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            research, "default_research_dir", return_value=pathlib.Path(directory)
        ), mock.patch.object(research.webbrowser, "open") as opener, mock.patch.object(
            research, "copy_to_clipboard", return_value=False
        ):
            self.assertEqual(0, research.main(["Offline question?"]))
            opener.assert_not_called()

    def test_source_has_no_api_or_cookie_access(self):
        source = MODULE_PATH.read_text(encoding="utf-8").lower()
        for forbidden in ("api.x.ai", "xai_api_key", "requests", "urllib.request", "cookie"):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
