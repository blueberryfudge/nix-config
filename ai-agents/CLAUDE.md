# Personal Defaults

- Use the specialist subagents when they clearly fit the task:
  - `code-engineer` for feature work, bug fixes, refactors, config changes, and tests once the path is clear enough to execute.
  - `code-searcher` for codebase discovery and fast tracing.
  - `code-architect` before large or ambiguous changes.
  - `code-reviewer` after non-trivial edits.
  - `code-security` for edge cases, resilience, and operational risk.
- Prefer one specialist at a time unless parallel work is clearly worth the extra context and cost.
- Keep handoffs compact: include the goal, relevant files, assumptions, and the exact output you want back.
- Stay in the main thread for trivial tasks that do not need isolation.
