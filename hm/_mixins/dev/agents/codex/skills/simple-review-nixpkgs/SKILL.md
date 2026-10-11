---
name: simple-review-nixpkgs
description: Find logically small, ready-to-review PRs in NixOS/nixpkgs, prioritizing human contributions older than a week.
---

# Simple review for nixpkgs

Read and follow the available `simple-review` skill using its installed path.
Apply its workflow to `NixOS/nixpkgs` with these additional preferences:

- Prefer human-authored PRs over bot PRs. Give `r-ryantm` PRs lower priority.
- Prefer PRs created more than seven days before the readiness check. Use the
  creation timestamp, not the most recent update.

Use author and creation metadata to prioritize candidate inspection and rank
similarly easy candidates. These are preferences, not eligibility requirements;
keep the base skill's logical-size and readiness criteria. Include the author
and creation date in each shortlist entry so the priorities are visible.
