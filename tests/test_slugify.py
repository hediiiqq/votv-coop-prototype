"""Unit tests for slugify function."""

import sys
from pathlib import Path
import unittest

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.slugify import slugify


class TestSlugify(unittest.TestCase):

    def test_normal_text(self):
        self.assertEqual(slugify("hello world"), "hello-world")
        self.assertEqual(slugify("Hello World"), "hello-world")
        self.assertEqual(slugify("Antigravity Smoke Test"), "antigravity-smoke-test")
        self.assertEqual(slugify("slugify 101"), "slugify-101")
        self.assertEqual(slugify("simple"), "simple")

    def test_repeated_separators(self):
        self.assertEqual(slugify("hello   world"), "hello-world")
        self.assertEqual(slugify("hello---world"), "hello-world")
        self.assertEqual(slugify("hello___world"), "hello-world")
        self.assertEqual(slugify("hello - _ - world"), "hello-world")
        self.assertEqual(slugify("a---b___c"), "a-b-c")

    def test_surrounding_punctuation_and_whitespace(self):
        self.assertEqual(slugify("  hello world  "), "hello-world")
        self.assertEqual(slugify("--hello world--"), "hello-world")
        self.assertEqual(slugify("...hello world..."), "hello-world")
        self.assertEqual(slugify("!Hello, World!"), "hello-world")
        self.assertEqual(slugify("  --__ Hello World __--  "), "hello-world")
        self.assertEqual(slugify("-slug-"), "slug")

    def test_fallback_behavior(self):
        self.assertEqual(slugify(""), "item")
        self.assertEqual(slugify("   "), "item")
        self.assertEqual(slugify("---"), "item")
        self.assertEqual(slugify("___"), "item")
        self.assertEqual(slugify("!@#$%^&*()"), "item")
        self.assertEqual(slugify("   ---   "), "item")
        self.assertEqual(slugify(None), "item")

    def test_alphanumeric_and_casing(self):
        self.assertEqual(slugify("ABC"), "abc")
        self.assertEqual(slugify("123"), "123")
        self.assertEqual(slugify("v1 2 3"), "v1-2-3")
        self.assertEqual(slugify("Upper and LOWER"), "upper-and-lower")


if __name__ == "__main__":
    unittest.main()
