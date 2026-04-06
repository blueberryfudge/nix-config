{
  description = "Shared AI agent defaults and specialist routing guidance.";
  frontmatter = {
    alwaysApply = true;
  };
  content = builtins.readFile ../../CLAUDE.md;
}
