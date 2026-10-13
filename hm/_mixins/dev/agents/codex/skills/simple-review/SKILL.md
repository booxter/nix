---
name: simple-review
description: Find up to 20 logically small GitHub pull requests in the current project that are ready for an easy review, using gh to inspect changes and blockers.
---

# Simple review

Find up to 20 very simple, open pull requests worth reviewing in the current
project. This is a bounded heuristic search, not an exhaustive queue audit.
Use `gh` for GitHub access. This is a read-only shortlist: do not submit reviews,
comment, change labels, or modify pull requests or the local checkout.

## Find candidates

Resolve the current checkout's GitHub repository with
`gh repo view --json nameWithOwner,url`. Keep all queries scoped to that
repository, using explicit `--repo` or API owner/repository arguments. Honor an
explicit repository or count supplied by the user instead.

List open, non-draft PRs with `gh pr list`, requesting metadata such as title,
URL, creation timestamp, changed files, additions, deletions, review
decision, and head SHA. Use metadata to prioritize inspection, not to decide
logical complexity.

Sample across creation-age bands: under 7 days, 7–30 days, 31–90 days, and
over 90 days, measured at the readiness check. Query each band separately with
`created:` filters; recent updates must not make an old PR count as fresh.
Sample at most two metadata pages of up to 100 PRs per band. Vary the sampled
pages or creation-date windows so repeated runs need not inspect the same
newest candidates. Do not enumerate the queue or recursively split date ranges
to work around GitHub's result cap.

Shuffle each band's candidate pool using fresh runtime randomness on every
invocation, without a fixed seed. Inspect candidates in rotation across bands
and aim for roughly equal numbers of verified selections from each. Refill
from the sampled pools when candidates fail verification. Apply any specialized
skill's age preferences, but treat count and age balance as preferences, not
reasons to expand the search indefinitely.

Stop when the shortlist is filled, after inspecting 60 candidates, or after
10 minutes, whichever comes first. Honor an explicit user budget instead.
Return the verified subset when a limit is reached; do not exhaust the queue
to fill slots. Briefly disclose the sampling limits and underrepresented bands.
Avoid repeated retries when access failures or rate limits consume the budget.

## Verify readiness

Filter in stages to avoid fetching expensive evidence for obvious rejects:

1. Check state, labels, merge conflicts, review decision, and required checks
   on the current head. Skip obvious blockers before fetching full discussions
   or diffs. If required-check policy is shared, establish it once per base branch.
2. Read the description and full diff for survivors. Reject complex changes
   early; read surrounding code or referenced context only as needed to judge
   whether the change is easy to review.
3. For likely selections, read reviews, issue comments, and inline review
   threads. `gh pr view --json comments,reviews` does not expose thread resolution;
   use GraphQL `reviewThreads`, including `isResolved`, `isOutdated`, and comments.
   Paginate these discussions for candidates actually recommended. Skip a PR
   if resolving its discussion would take substantial investigation.

Keep fetched evidence for this run. Read relevant discussion in full, but avoid
dumping PR templates and long build logs into context; inspect log excerpts only
when they affect readiness. Do not persist recommendation history.

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

Aim for the age mix when selecting the shortlist, then rank verified candidates
by ease of review, simplest first. Perform one lightweight freshness check of
the shortlisted PRs' heads, state, checks, and discussion update timestamps.
Reuse existing evidence when unchanged; fetch changed evidence and reassess only
affected candidates. Drop a candidate if it cannot be reverified within budget.

Return a numbered list of up to 20 PRs, each with a linked PR number, title,
creation date, a brief explanation of why the change is logically small, and a readiness
note covering checks and blocking feedback. Keep it useful for choosing the
next review, without performing or claiming a full correctness review.

If fewer than 20 qualify, return only the verified candidates and briefly
explain the shortfall. Never pad the list with blocked, complex, or unverified
PRs. Include the repository and when readiness was checked; disclose material
coverage limits without claiming the entire queue was inspected.
