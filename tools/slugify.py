"""Small deterministic slugify utility."""

import re
import sys


def slugify(text: str) -> str:
    """Convert ASCII text to a lowercase hyphen-separated slug.

    Collapses repeated separators, trims surrounding separators,
    and returns 'item' when no ASCII alphanumeric characters remain.
    """
    if not isinstance(text, str):
        text = str(text) if text is not None else ""
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", text).strip("-").lower()
    return slug if slug else "item"


if __name__ == "__main__":
    input_text = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else ""
    print(slugify(input_text))
