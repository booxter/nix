---
name: simple-review-nixpkgs
description: Find logically small, ready-to-review PRs in NixOS/nixpkgs, prioritizing human contributions older than a week.
---

# Simple review for nixpkgs

Read and follow the available `simple-review` skill using its installed path.
Apply its workflow to `NixOS/nixpkgs` with these additional preferences:

- Prefer human-authored PRs over bot PRs. Give `r-ryantm` PRs lower priority.
- Allocate the shortlist roughly equally across the base skill's 7–30 day,
  31–90 day, and over 90 day bands. Use PRs under seven days old as fallback
  when the sampled older pools cannot fill the requested count. Shuffle and
  refill within the base skill's sampling and inspection budgets; do not expand
  discovery to force an exact age mix or a full 20 entries. Prefer a shorter
  verified list with visible age coverage to an exhaustive search.

Use author and creation metadata to prioritize candidate inspection and rank
similarly easy candidates. These are preferences, not eligibility requirements;
keep the base skill's logical-size and readiness criteria. Include the author
and creation date in each shortlist entry so the priorities are visible.
