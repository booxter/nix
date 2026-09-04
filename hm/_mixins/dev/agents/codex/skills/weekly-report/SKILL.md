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

## Output

Return Markdown suitable for review and later pasting into a status report.
Start with the exact core interval and safety-overlap interval. Organize the
work into short, descriptive topic sections named for the project, product,
workstream, or technical area. Do not organize sections by state or activity
type, such as delivered, in progress, helped, or reviewed.

Omit empty sections. Within each topic, write a flat bullet list of brief,
outcome-first items. Prefer one short sentence or phrase per bullet and omit
implementation detail that is not needed to distinguish the result. A bullet
may contain canonical Markdown links to relevant Jira issues, GitLab
artifacts, and `ovn-kubernetes` organization GitHub artifacts. Combine related
work and links in the same bullet rather than creating source-by-source or
status-by-status duplicates.

Keep carry-over activity in its relevant topic and mark the item `Overlap
only` when its supporting evidence falls entirely within the safety-overlap
interval. Do not create a separate carry-over section.

After the list, add a short coverage note only if a source was unavailable,
identity was ambiguous, pagination or permissions made results incomplete, or
the time filtering was necessarily approximate.

After producing the report, use the connected Google Docs tools to update the
document named `Private weekly notes` with the latest report. Do not post,
send, comment, or otherwise publish the report anywhere else.
