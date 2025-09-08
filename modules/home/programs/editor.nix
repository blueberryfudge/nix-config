{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:
{
  options = {
    editor.enable = lib.mkEnableOption "enables Helix editor";
    editor.theme = lib.mkOption {
      type = lib.types.str;
      default = "catppuccin_mocha";
      description = "Helix theme";
    };
  };

  config = lib.mkIf config.editor.enable {
    home.packages = with pkgs; [
      metals
      helix
      nil
      rust-analyzer
      ruff-lsp
      marksman
      yaml-language-server
      goimports
      prettier
    ];

    home.file.".config/helix/config.toml".text = ''
      theme = "${config.editor.theme}"

      [editor]
      auto-info = true
      line-number = "relative"
      bufferline = "multiple"
      color-modes = true
      true-color = true
      end-of-line-diagnostics = "hint"

      [editor.inline-diagnostics]
      cursor-line = "warning"
      # other-lines = "warning"

      [editor.statusline]
      right = ["workspace-diagnostics"]
      center = ["version-control"]
      mode.normal = "NORMAL"
      mode.insert = "INSERT"
      mode.select = "SELECT"

      [keys.normal]
      C-y = ":sh zellij run -n Yazi -c -f -x 10%% -y 10%% --width 80%% --height 80%% -- bash ~/.config/helix/yazi-picker.sh open %{buffer_name}"
    '';

    home.file.".config/helix/languages.toml".text = ''
      [[language-server.rust-analyzer.config.check]]
      command = "clippy"

      [[language-server.rust-analyzer.config.cargo]]
      features = "all"

      [language-server.ruff]
      command = "ruff-lsp"

      [[language]]
      name = "python"
      language-servers = ["pyright", "ruff" ]
      auto-format = true

      [[language]]
      name = "markdown"
      language-servers = ["marksman", "mdpls"]

      [language-server.mdpls]
      command = "/Users/edb/.cargo/bin/mdpls"
      config = { markdown.preview.auto = true }

      [[language]]
      name = "go"
      auto-format = true
      formatter = {command = "goimports" }

      [language-server.metals.config.metals]
      autoImportBuild = "all"

      [[language]]
      name = "java"
      file-types = ["java", "jav", "pde"]
      # roots = ["pom.xml", "build.gradle", "build.gradle.kts"]

      # [language-server.jdtls]
      # command = "jdtls"
      # args = ["--jvm-arg=-javaagent:/Users/edb/Downloads/lombok.jar"]
      # environment = { "JAVA_HOME" = "/opt/homebrew/opt/openjdk@21" }

      [[language]]
      name = "scala"
      # file-types = ["scala", "sc", "sbt", "mill"]
      # language-servers = ["metals"]
      # indent = { tab-width = 2, unit = "  " }
      # comment-token = "//"
      # roots = ["build.sbt", "build.sc", "build.mill", ".mill-version", "project"]
      # formatter = { command = "scalafmt", args = ["--stdin", "--assume-filename", "dummy.scala"] }
      # auto-format = true

      [language-server.metals]
      command = "metals"

      [[language]]
      name = "yaml"
      scope = "source.yaml"
      file-types = [
        "yml",
        "tmpl",
        "yaml",
        { glob = ".prettierrc" },
        { glob = ".clangd" },
        { glob = ".clang-format" },
        { glob = ".clang-tidy" },
        "sublime-syntax"
      ]
      comment-token = "#"
      indent = { tab-width = 2, unit = "  " }
      language-servers = [ "yaml-language-server", "ansible-language-server" ]
      injection-regex = "yml|yaml"

      [[grammar]]
      name = "yaml"
      source = { git = "https://github.com/ikatyang/tree-sitter-yaml", rev = "0e36bed171768908f331ff7dff9d956bae016efb" }

      [[language]]
      name = "json"
      language-servers = ["vscode-json-languageserver"]
      formatter = { command = 'prettier', args = ["--parser", "json"] }

      [[language]]
      name = "nix"
      language-servers = ["nil"]
    '';
  };
}
