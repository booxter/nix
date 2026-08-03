import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from check_patch_context import find_contextless_hunks


class PatchContextTest(unittest.TestCase):
    def test_accepts_edit_with_unchanged_context(self):
        patch = """\
--- a/example.py
+++ b/example.py
@@ -1,3 +1,3 @@
 before
-old
+new
 after
"""

        self.assertEqual(find_contextless_hunks(patch), [])

    def test_rejects_contextless_insertion(self):
        patch = """\
--- a/example.py
+++ b/example.py
@@ -2,0 +3,1 @@
+inserted
"""

        violations = find_contextless_hunks(patch)

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].line, 3)

    def test_rejects_contextless_replacement(self):
        patch = """\
--- a/example.py
+++ b/example.py
@@ -2 +2 @@ section label is not context
-old
+new
"""

        self.assertEqual(len(find_contextless_hunks(patch)), 1)

    def test_accepts_new_file_hunk(self):
        patch = """\
--- /dev/null
+++ b/example.py
@@ -0,0 +1,2 @@
+first
+second
"""

        self.assertEqual(find_contextless_hunks(patch), [])

    def test_accepts_unprefixed_blank_context_tolerated_by_patch(self):
        patch = """\
--- a/example.py
+++ b/example.py
@@ -1,2 +1,2 @@

-old
+new
"""

        self.assertEqual(find_contextless_hunks(patch), [])

    def test_checks_each_hunk(self):
        patch = """\
--- a/example.py
+++ b/example.py
@@ -1,2 +1,2 @@
 context
-old
+new
@@ -5 +5 @@
-other old
+other new
"""

        violations = find_contextless_hunks(patch)

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].line, 7)

    def test_rejects_hunk_with_incorrect_line_count(self):
        patch = """\
--- a/example.py
+++ b/example.py
@@ -1,2 +1,2 @@
-old
+new
"""

        with self.assertRaisesRegex(ValueError, "declared line count"):
            find_contextless_hunks(patch)


if __name__ == "__main__":
    unittest.main()
