---
name: weekly-report
description: Produce a personal weekly status report from connected Slack, Jira, email, GitLab, and OVN-Kubernetes GitHub activity.
---

# Weekly report

Create a concise, evidence-backed account of work the user completed, advanced,
reviewed, investigated, or helped with. Use the connected service MCP tools as
the sources of record. Do not substitute web search, local repository history,
or remembered context for a connected source.

## Time window

Capture the execution time once at the start of the run in America/New_York.
Unless the user specifies another period:

- The report's core interval is the seven 24-hour periods ending at the
  captured execution time.
- Search an additional 24 hours before the core interval as a safety overlap.
- Treat activity whose supporting evidence falls entirely in the overlap as a
  carry-over candidate. Do not silently mix it into the core interval.

Use exact timestamps for source queries when supported. Otherwise widen the
source query to whole dates and filter the returned records against the exact
interval. Paginate until the results are older than the safety-overlap start;
do not rely on a first page or an arbitrary small result limit.

An explicit user-supplied interval replaces the seven-day core interval but
retains the 24-hour safety overlap unless the user says otherwise.

## Destination document

At the start of the run, find and read the Google Doc named `Private weekly
notes`. Use its current report as the style and structure reference for the new
report. It is not a source of facts: never carry old accomplishments, links,
people, dates, statuses, or project details forward without current-period
evidence.

Infer and retain the document's stable report shape, including topic heading
order, bullet hierarchy, link placement, level of detail, terse phrasing, and
the convention used for tracked topics with no activity. Treat its existing
topic headings as the default taxonomy. Add a topic only when substantial
current work clearly fits none of them, and name it narrowly after the actual
workstream. Do not invent umbrella topics from source systems, activity types,
status, or loose thematic similarity.

## Sources

Use all of the following connected sources. Identify the current user through
the service when possible; do not attribute work based only on a display-name
match. If identity remains ambiguous for a source, say which source could not
be searched reliably instead of guessing.

- Slack: messages authored by the user and substantive replies they made in
  threads. Ignore reactions, automated messages, and passive mentions.
- Jira: issues the user materially changed, resolved, advanced, investigated,
  or commented on. Ignore mechanical field churn with no meaningful
  contribution.
- Email: messages sent by the user and substantive replies in threads. Ignore
  calendar traffic, automated notifications, and acknowledgements with no
  work content.
- GitLab: authored or merged changes, commits, reviews, substantive comments,
  issues, and investigations attributable to the user.
- GitHub: restrict every query and result to repositories owned by the
  `ovn-kubernetes` organization. Include authored changes, commits, reviews,
  substantive comments, issues, and investigations attributable to the user.
  Exclude repositories owned by every other GitHub organization or user, even
  when a cross-reference mentions OVN-Kubernetes.

Search the sources independently so that the absence or failure of one source
does not prevent reporting evidence from the others. Report any unavailable or
incomplete source after the work list.

## Synthesis

Normalize the source results into work items, then merge records that refer to
the same outcome. Jira keys, pull or merge request URLs, commit URLs, issue
URLs, and explicit cross-references are strong merge evidence. Similar wording
alone is not enough when it could combine separate work.

Use Slack and email to recover coordination, debugging, reviews, and help that
may not have produced a code artifact. Summarize their contribution without
quoting private messages or exposing correspondents unnecessarily. Never add
Slack or email links to the report. When the same item has a Jira, GitLab, or
GitHub artifact, link those artifacts instead.

Include only contributions supported by retrieved evidence. Prefer the
outcome and the user's contribution over a chronology of messages or commits.
Do not count passive participation, notifications received, assignments with
no activity, or duplicated mirrors as accomplishments.

Phrase each item as a concrete technical action or result. Preserve useful
technical nouns and distinctions from the evidence. Avoid generic substitutes
such as "worked on", "advanced", "supported", "helped with", or "made progress
on" when the evidence supports a more precise verb. Do not inflate exploratory,
partial, blocked, or coordination work into a completed outcome.

## Output

Return Markdown suitable for review and later pasting into a status report.
Start with the exact core interval and safety-overlap interval, then follow the
destination document's established heading order and hierarchy. Keep its
stable tracked topics even when a topic has no current activity, using the
document's existing terse no-progress convention. Do not organize sections by
state or activity type, such as delivered, in progress, helped, or reviewed.

Within each topic, use brief top-level bullets with one concrete contribution
per bullet. Combine records about the same contribution, but do not combine
distinct outcomes merely to reduce the bullet count. Use nested bullets only
for a directly subordinate follow-up or for supporting artifact URLs.

Keep links out of prose. Include only the most direct Jira, GitLab, or
`ovn-kubernetes` organization GitHub artifacts needed to locate the reported
work, and put each canonical URL in its own nested bullet immediately under
the contribution. Do not add Slack or email links, collect links in a separate
section, label links by source, or dump every cross-referenced artifact.

Before returning the report, remove vague summaries, duplicated work,
source-by-source narration, invented themes, unnecessary names, and detail
that does not distinguish the contribution.

Keep carry-over activity in its relevant topic and mark the item `Overlap
only` when its supporting evidence falls entirely within the safety-overlap
interval. Do not create a separate carry-over section.

After the list, add a short coverage note only if a source was unavailable,
identity was ambiguous, pagination or permissions made results incomplete, or
the time filtering was necessarily approximate.

After producing the report, use the connected Google Docs tools to replace the
current report in `Private weekly notes` with the latest report while
preserving the established document shape. Do not post, send, comment, or
otherwise publish the report anywhere else.
