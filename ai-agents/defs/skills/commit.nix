{
  description = "Create a well-formed git commit. Invoke with /commit when you want Claude to stage, write, and commit changes following project conventions.";
  frontmatter = {
    "disable-model-invocation" = true;
  };
  content = ''
    # Commit

    Create a git commit for the current changes.

    ## Process

    1. **Inspect changes**: Run `git status` and `git diff` (staged and unstaged) to understand what changed.
    2. **Stage selectively**: Add only the relevant files. Never stage `.env`, secrets, or large binaries unless the user explicitly named them.
    3. **Write the message**: Follow the existing commit style in `git log --oneline -10`. If no clear style, use a short imperative subject line (≤72 chars). Add a body paragraph when the *why* isn't obvious from the diff.
    4. **Add co-author line**: Always append to the commit body:
       ```
       Co-Authored-By: Claude <noreply@anthropic.com>
       ```
    5. **Commit**: Use a heredoc to pass the message — avoids shell escaping issues:
       ```bash
       git commit -m "$(cat <<'EOF'
       Subject line here

       Optional body paragraph.

       Co-Authored-By: Claude <noreply@anthropic.com>
       EOF
       )"
       ```
    6. **Verify**: Run `git log -1 --stat` to confirm the commit looks right.

    ## Rules

    - Never use `git add -A` or `git add .` — stage files by name.
    - Never skip pre-commit hooks (`--no-verify`). If a hook fails, fix the issue and retry.
    - Never amend a commit unless the user explicitly asked for it.
    - If nothing is staged and nothing is unstaged, report that there is nothing to commit.
  '';
}
