{
  description = "How to add agents, skills, hooks, and rules to the ai-agents Nix module in this repository. Invoke with /nix-module-workflow when modifying the agent system.";
  frontmatter = {
    "disable-model-invocation" = true;
  };
  content = ''
    # Nix Module Workflow

    This documents how to add or modify entries in the ai-agents system at
    `modules/home/programs/ai-agents.nix`.

    ## Adding an Agent

    1. Create `ai-agents/defs/agents/<name>.nix` returning an attrset with:
       - `description` (string) — shown in agent frontmatter
       - `tier` OR `models` — tier resolves via `targetTierModels`; models is a `{ claude = "..."; cursor = "..."; }` override
       - `claude` attrset — merged into Claude frontmatter: `permissionMode`, `tools`, `maxTurns`, `effort`, `skills`, `color`, `memory`
       - `cursor` attrset — merged into Cursor frontmatter (optional)
       - `prompt` (multiline string) — the agent's system prompt body
    2. Import in `modules/home/programs/ai-agents.nix` under `agentDefs`:
       ```nix
       agentDefs = {
         # existing...
         my-agent = import (dataPath "defs/agents/my-agent.nix");
       };
       ```
    3. Run `nix flake check` to validate.

    ## Adding a Skill

    1. Create `ai-agents/defs/skills/<name>.nix` returning an attrset with:
       - `description` (string)
       - `frontmatter` (attrset, optional) — shared frontmatter fields e.g. `"user-invocable" = false`
       - `claude` / `cursor` (attrset, optional) — target-specific frontmatter overrides
       - `content` (multiline string) — the skill body markdown
    2. Import in `skillDefs` in the module.
    3. `git add` the file before running `nix flake check` (Nix requires tracked files).

    ## Adding a Hook

    1. Create `ai-agents/defs/hooks/<name>.nix` as a function `{ pkgs }: { ... }` returning:
       - `description` (string)
       - `fileName` (string) — output filename e.g. `"my-hook.sh"`
       - `script` (string) — bash script with `#!''${pkgs.bash}/bin/bash` shebang; use nix store paths for all binaries
       - `claude` (list of binding attrsets) — each has `event`, optional `matcher`, optional `timeout`, optional `statusMessage`
       - `cursor` (list of binding attrsets, optional)
    2. Import in `hookDefs` with `{ inherit pkgs; }` application.
    3. `git add` the file.

    ## Rendering Pipeline

    The module generates:
    - `.claude/agents/<name>.md` — YAML frontmatter + prompt
    - `.claude/skills/<name>/SKILL.md` — YAML frontmatter + content
    - `.claude/hooks/<name>.sh` — executable script
    - `.claude/settings.json` — permissions + hook bindings
    - Mirrored `.cursor/` equivalents

    YAML frontmatter fields are sorted alphabetically by `orderedAttrNames`.
    All values rendered via `builtins.toJSON` (strings get quotes, bools don't).

    ## Deploy

    ```bash
    darwin-rebuild switch --flake .#personal-mac
    # or for home-manager only:
    home-manager switch --flake .#edb@Mac
    ```
  '';
}
