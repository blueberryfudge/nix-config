{
  description = "Resume from the most recent compaction checkpoint. Invoke when a session starts after compaction to recover in-progress context from ~/.claude/compact-notes.md.";
  frontmatter = {
    "user-invocable" = false;
  };
  content = ''
    # Session Resume

    ## Most Recent Checkpoint

    !`tail -n +1 "$HOME/.claude/compact-notes.md" 2>/dev/null | awk '/^## /{found=1; buf=""} found{buf=buf $0 "\n"} END{printf "%s", buf}' || echo "No checkpoint found."`

    ## Instructions

    Present the checkpoint above to orient the session:
    - Summarize what was in progress based on the git state shown
    - Note which files were modified and what the recent commits accomplished
    - If no checkpoint exists, say so briefly and continue normally
  '';
}
