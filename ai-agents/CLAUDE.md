# Personal Defaults

- Use the specialist subagents when they clearly fit the task:
  - `bob-the-builder` for feature work, bug fixes, refactors, config changes, and tests once the path is clear enough to execute.
  - `truffle-pig` for codebase discovery and fast tracing.
  - `architect` before large or ambiguous changes.
  - `four-eyes` after non-trivial edits.
  - `mr-robot` for edge cases, resilience, and operational risk.
- Prefer one specialist at a time unless parallel work is clearly worth the extra context and cost.
- Keep handoffs compact: include the goal, relevant files, assumptions, and the exact output you want back.
- Stay in the main thread for trivial tasks that do not need isolation.
