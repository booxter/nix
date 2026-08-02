import unittest

import main as summary


def github_lock(revision, owner="example", repo="project"):
    return {
        "lastModified": 1,
        "narHash": f"sha256-{revision}",
        "owner": owner,
        "repo": repo,
        "rev": revision,
        "type": "github",
    }


def lock(inputs):
    nodes = {"root": {"inputs": {}}}
    for name, locked in inputs.items():
        node_name = f"node-{name}"
        nodes["root"]["inputs"][name] = node_name
        nodes[node_name] = {"locked": locked}
    return {"nodes": nodes, "root": "root", "version": 7}


class FlakeInputUpdateSummaryTests(unittest.TestCase):
    def test_renders_updated_inputs_with_compare_links(self):
        old_revision = "1111111111111111111111111111111111111111"
        new_revision = "2222222222222222222222222222222222222222"
        unchanged_revision = "3333333333333333333333333333333333333333"
        old_lock = lock(
            {
                "nixpkgs": github_lock(old_revision, "NixOS", "nixpkgs"),
                "unchanged": github_lock(unchanged_revision),
            }
        )
        new_lock = lock(
            {
                "nixpkgs": github_lock(new_revision, "NixOS", "nixpkgs"),
                "unchanged": github_lock(unchanged_revision),
            }
        )

        body = summary.render_body(old_lock, new_lock, "schedule")

        self.assertIn("| Input | Update | Diff |", body)
        self.assertIn("| `nixpkgs` | `1111111` → `2222222` |", body)
        self.assertIn(
            f"https://github.com/NixOS/nixpkgs/compare/{old_revision}...{new_revision}",
            body,
        )
        self.assertNotIn("unchanged", body)
        self.assertTrue(body.endswith("Trigger: schedule\n"))

    def test_renders_transitive_input_updates_by_path(self):
        old_lock = lock({"parent": github_lock("a" * 40)})
        new_lock = lock({"parent": github_lock("a" * 40)})
        old_lock["nodes"]["node-parent"]["inputs"] = {"child": "old-child"}
        new_lock["nodes"]["node-parent"]["inputs"] = {"child": "new-child"}
        old_lock["nodes"]["old-child"] = {"locked": github_lock("b" * 40)}
        new_lock["nodes"]["new-child"] = {"locked": github_lock("c" * 40)}

        body = summary.render_body(old_lock, new_lock, "workflow_dispatch")

        self.assertIn("| `parent/child` | `bbbbbbb` → `ccccccc` |", body)

    def test_ignores_follows_aliases(self):
        old_lock = lock({"parent": github_lock("a" * 40)})
        new_lock = lock({"parent": github_lock("a" * 40)})
        old_lock["nodes"]["node-parent"]["inputs"] = {"nixpkgs": ["nixpkgs"]}
        new_lock["nodes"]["node-parent"]["inputs"] = {"nixpkgs": ["nixpkgs"]}

        body = summary.render_body(old_lock, new_lock, "schedule")

        self.assertIn("No flake input revisions changed.", body)
        self.assertNotIn("parent/nixpkgs", body)

    def test_marks_cross_repository_updates_without_a_compare_link(self):
        old_lock = lock({"input": github_lock("a" * 40, repo="old")})
        new_lock = lock({"input": github_lock("b" * 40, repo="new")})

        body = summary.render_body(old_lock, new_lock, "schedule")

        self.assertIn("| `input` | `aaaaaaa` → `bbbbbbb` | Unavailable |", body)

    def test_supports_git_urls_for_github_inputs(self):
        old_revision = "a" * 40
        new_revision = "b" * 40
        old = {
            "rev": old_revision,
            "type": "git",
            "url": "https://github.com/example/project.git",
        }
        new = {**old, "rev": new_revision}

        self.assertEqual(
            summary.compare_url(old, new),
            "https://github.com/example/project/compare/"
            f"{old_revision}...{new_revision}",
        )


if __name__ == "__main__":
    unittest.main()
