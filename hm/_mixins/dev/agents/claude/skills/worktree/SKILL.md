---
name: worktree
description: Move this session into a Git worktree on a branch with the given name.
argument-hint: <name>
disable-model-invocation: true
---

# Worktree

Call the EnterWorktree tool with `name` set to `$ARGUMENTS`. If no name was
given, ask the user for one instead.

The worktree is created on a branch with exactly that name, starting from the
current HEAD, or on the existing branch if one has that name. Reusing a name
reopens the same worktree. After entering, report the worktree path and branch.
