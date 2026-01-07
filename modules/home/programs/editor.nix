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
      nil
      marksman
      yaml-language-server
      prettier
      gopls
      gotools
      delve
      jdt-language-server
    ];

    programs.helix = {
      enable = true;

      settings = {
        theme = config.editor.theme;

        editor = {
          auto-info = true;
          line-number = "relative";
          bufferline = "multiple";
          color-modes = true;
          true-color = true;
          end-of-line-diagnostics = "hint";
          soft-wrap.enable = true;

          inline-diagnostics = {
            cursor-line = "warning";
          };

          statusline = {
            right = [ "workspace-diagnostics" ];
            center = [ "version-control" ];
            mode = {
              normal = "NOR";
              insert = "INS";
              select = "SEL";
            };
          };
        };

        keys.normal = {
          "C-y" =
            ":sh zellij run -n Yazi -c -f -x 10%% -y 10%% --width 80%% --height 80%% -- bash ~/.config/helix/yazi-picker.sh open %{buffer_name}";
        };
      };

      languages = {
        language-server.rust-analyzer.config = {
          check.command = "clippy";
          cargo.features = "all";
        };

        language-server.ruff.command = "ruff-lsp";

        language-server.mdpls = {
          command = "/Users/edb/.cargo/bin/mdpls";
          config.markdown.preview.auto = true;
        };

        language-server.metals = {
          config = {
            metals = {
              autoImportBuild = "all";
              scalafixConfigPath = ".scalafix.conf";
              compilerOptions = {
                isCompletionSnippetsEntabled = true;
              };
              showImplicitArguments = true;
              showImplicitConversions = true;
              showInferredType = true;
              superMethodLensesEnabled = true;
              java.format.enabled = false;
            };
          };
        };
        language = [
          {
            name = "scala";
            file-types = [
              "scala"
              "sbt"
              "sc"
              "mill"
            ];
            roots = [
              "build.mill"
              "build.sbt"
              "build.sc"
              ".scala-build"
              ".git"
            ];
            language-servers = [ "metals" ];
          }
          {
            name = "python";
            language-servers = [
              "pyright"
              "ruff"
            ];
            auto-format = true;
          }
          {
            name = "markdown";
            language-servers = [
              "marksman"
              "mdpls"
            ];
          }
          {
            name = "go";
            auto-format = true;
            formatter.command = "goimports";
            language-servers = [
              "gopls"
            ];
          }
          {
            name = "java";
            file-types = [
              "java"
              "jav"
              "pde"
            ];
            language-servers = [ "jdtls" ];
          }
          {
            name = "yaml";
            scope = "source.yaml";
            file-types = [
              "yml"
              "tmpl"
              "yaml"
              { glob = ".prettierrc"; }
              { glob = ".clangd"; }
              { glob = ".clang-format"; }
              { glob = ".clang-tidy"; }
              "sublime-syntax"
            ];
            comment-token = "#";
            indent = {
              tab-width = 2;
              unit = "  ";
            };
            language-servers = [ "yaml-language-server" ];
            injection-regex = "yml|yaml";
          }
          {
            name = "json";
            language-servers = [ "vscode-json-languageserver" ];
            formatter = {
              command = "prettier";
              args = [
                "--parser"
                "json"
              ];
            };
          }
          {
            name = "nix";
            language-servers = [ "nil" ];
          }
        ];

        grammar = [
          {
            name = "yaml";
            source = {
              git = "https://github.com/ikatyang/tree-sitter-yaml";
              rev = "0e36bed171768908f331ff7dff9d956bae016efb";
            };
          }
        ];
      };
    };
  };
}
