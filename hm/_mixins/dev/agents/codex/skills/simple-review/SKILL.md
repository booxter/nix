---
name: simple-review
description: Find up to 20 logically small GitHub pull requests in the current project that are ready for an easy review, using gh to inspect changes and blockers.
---

# Simple review

Find 20 very simple, open pull requests worth reviewing in the current project.
Use `gh` for GitHub access. This is a read-only shortlist: do not submit reviews,
comment, change labels, or modify pull requests or the local checkout.

## Find candidates

Resolve the current checkout's GitHub repository with
`gh repo view --json nameWithOwner,url`. Keep all queries scoped to that
repository, using explicit `--repo` or API owner/repository arguments. Honor an
explicit repository or count supplied by the user instead.

List open, non-draft PRs with `gh pr list`, requesting metadata such as title,
URL, body, changed files, additions, deletions, review decision, and head SHA.
Use metadata to prioritize inspection, not to decide logical complexity.
Paginate through candidates rather than treating the default first page or
the first 20 results as the shortlist. Continue until there are enough verified
candidates or the available PRs are exhausted. Disclose any search limit or
access failure that makes coverage incomplete.

## Verify readiness

For each promising candidate, inspect its current description, full diff,
checks, reviews, issue comments, and review threads with `gh pr view`,
`gh pr diff`, and `gh api` as needed. `gh pr view --json comments,reviews` does
not expose all inline thread resolution state; use the GraphQL API to retrieve
`reviewThreads`, including `isResolved`, `isOutdated`, and their comments.
Paginate thread, review, and comment connections as well as the PR list.

Exclude PRs with any of the following:

- Draft or closed state, merge conflicts, or an explicit hold, WIP, or
  do-not-merge instruction in labels, description, or discussion.
- An active changes-requested review or unresolved substantive requests,
  questions, or objections that require author action. Read replies and later
  changes before deciding whether a concern remains blocking; an outdated
  thread alone does not prove resolution. Nonblocking nits and praise are fine.
- Failing or pending required checks. Inspect checks on the current head;
  distinguish optional checks from required checks. If required-check status
  cannot be established, omit the candidate rather than claim it is ready.
- Explicit dependencies on unfinished work or missing information needed to
  review the change.

Lack of approval is expected for a review candidate. A PR with no configured
checks can qualify; say that no checks are configured. Do not equate GitHub's
`BLOCKED` merge state with author work remaining without checking the reason:
it can simply mean the PR needs a review.

## Judge logical size

Read the actual change and enough surrounding code or referenced context to
understand its effect. Prefer one obvious purpose, few independent decisions,
local effects, and a short path to verifying correctness. Favor changes that
need little architectural or domain investigation.

Line counts are hints, never eligibility cutoffs. Removing a 1,000-line unused
file can be small if its removal and remaining references are easy to verify.
Generated output, lockfile churn, or mechanical renames can also be simple,
but verify the source change and scope. Conversely, a one-line change to
security, concurrency, data migration, or shared semantics can be difficult.
Exclude changes whose apparent simplicity depends on unverified assumptions.

## Return the shortlist

Rank verified candidates by ease of review, simplest first. Recheck shortlisted
PRs for current head, draft state, checks, and discussion before returning;
reassess any whose head or readiness evidence changed during inspection.

Return a numbered list of 20 PRs, each with a linked PR number and title, a
brief explanation of why the change is logically small, and a concise readiness
note covering checks and blocking feedback. Keep it useful for choosing the
next review, without performing or claiming a full correctness review.

If fewer than 20 qualify, return only the verified candidates and briefly
explain the shortfall. Never pad the list with blocked, complex, or unverified
PRs. Include the repository and when readiness was checked; disclose material
coverage limits without claiming the entire queue was inspected.
