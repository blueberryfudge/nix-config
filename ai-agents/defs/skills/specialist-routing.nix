{
  description = "Routing guide for the personal specialist agents. Use when deciding whether to implement a change, scout the codebase, plan a change, review finished work, or analyze failure modes.";

  frontmatter = {
    "user-invocable" = false;
  };

  content = ''
    # Specialist Routing

    Use this skill when a task would benefit from one of the personal specialist agents.

    Pick the smallest useful specialist:
    - `bob-the-builder` when the work is clear enough to execute and you want focused implementation, validation, or follow-through
    - `truffle-pig` when you need to find files, trace execution, or understand unfamiliar code quickly
    - `architect` before large or ambiguous changes, especially when tradeoffs or sequencing matter
    - `four-eyes` after non-trivial edits to check correctness, regression risk, and missing tests
    - `mr-robot` when a change touches auth, data integrity, concurrency, external APIs, migrations, or operational risk

    Working rules:
    - stay in the main thread for trivial tasks
    - prefer one specialist at a time unless parallel work is clearly valuable
    - give clear handoffs: goal, relevant files, assumptions, constraints, and the exact output you want back
    - summarize the conclusion after specialist work before moving on
  '';
}
