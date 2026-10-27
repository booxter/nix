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

  You may delegate when independent work benefits from a separate context or
  parallel execution. Keep small tasks and tightly coupled steps with the lead.
  Use at most two concurrent workers. Workers must not delegate further.

  Select the assigned model through the runtime's model parameter or a configured
  agent with that model; naming a model in the task prompt does not select it.
  If the model cannot be selected, report that limitation and keep the task with
  the lead rather than silently substituting another model.

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
