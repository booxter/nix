{
  default,
  implementer,
  specialist,
}:
''

  ## Orchestration

  Use these model assignments when delegating:

  - Default: `${default}` for everyday design, investigation, and independent review.
  - Implementer: `${implementer}` for bounded changes with an agreed design and
    clear acceptance criteria. Follow the design; report problems instead of
    expanding scope.
  - Specialist: `${specialist}` for difficult root-cause investigations, conflicting
    evidence, or consequential architecture decisions. State the unresolved
    question that warrants escalation; do not escalate routinely.

  Set reasoning effort explicitly for each worker:

  - Low: mechanical searches, inventories, and simple edits with an obvious check.
  - Medium: bounded implementation with clear acceptance criteria and verification.
  - High: substantive implementation, design, investigation, independent review,
    and specialist work.
  - Extra high (`xhigh` where supported): difficult architecture, security,
    concurrency, or open-ended problems with conflicting evidence.

  Use medium as the fallback. Judge the reasoning needed and how reliably errors
  can be caught; a narrow assignment can still require high effort. Escalate the
  model or effort when evidence shows the current approach is not making progress.

  You may delegate when independent work benefits from a separate context or
  parallel execution. Keep small tasks and tightly coupled steps with the lead.
  Use at most two concurrent workers. Workers must not delegate further.

  Select the assigned model and effort through runtime parameters or a configured
  agent; naming them in the task prompt does not select them. If either cannot be
  selected, report that limitation and keep the task with the lead rather than
  silently substituting another model or effort.

  Give each worker the objective, relevant context and repository rules, permitted
  files, constraints, acceptance criteria, and expected verification. Pass a
  focused brief; do not assume workers inherit the conversation or instructions.
  Workers must return evidence, changed files, checks run, and remaining uncertainty.

  Assign one writer per file and serialize overlapping edits. Reviewers inspect
  without editing. Workers must not stage or commit changes; the lead owns
  integration, reviews the actual diff and evidence, runs appropriate checks,
  and commits completed logical changes. As a worker, finish only your assignment
  and report back to the lead.
''
