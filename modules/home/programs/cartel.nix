{
  pkgs,
  lib,
  config,
  ...
}:

# cartel - talk to your patrón, run a crew of sicarios (Herdr + git worktrees).
# Packages the bash CLI (on PATH, with its runtime deps wrapped in) and the
# event-driven Go source (cartel-events, consumed by `cartel lookout`). Mutable
# state lives under $CARTEL_HOME (~/cartel); only the patrón instructions are
# managed here so the crew's runtime state stays out of the store.
let
  cfg = config.cartel;

  # Event-driven transport for `cartel lookout`. Stdlib-only, so vendorHash=null.
  cartel-events = pkgs.buildGoModule {
    pname = "cartel-events";
    version = "0.1.0";
    src = ./cartel/events;
    vendorHash = null;
  };

  # The CLI: modern bash (macOS system bash is 3.2, too old for `declare -A`)
  # plus its runtime tools + cartel-events prepended to PATH.
  cartel = pkgs.runCommandLocal "cartel" {
    nativeBuildInputs = [ pkgs.makeWrapper ];
  } ''
    install -Dm755 ${./cartel/cartel.sh} $out/bin/cartel
    substituteInPlace $out/bin/cartel \
      --replace-fail '#!/usr/bin/env bash' '#!${pkgs.bash}/bin/bash'
    wrapProgram $out/bin/cartel \
      --prefix PATH : ${lib.makeBinPath [
        pkgs.herdr
        pkgs.jq
        pkgs.git
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.gawk
        cartel-events
      ]}
  '';
in
{
  options.cartel.enable = lib.mkEnableOption "cartel agent orchestrator (patrón + sicarios over Herdr)";

  config = lib.mkIf cfg.enable {
    home.packages = [
      cartel
      cartel-events
    ];

    # Patrón (orchestrator) instructions, loaded as strong project memory when
    # `cartel patron` cd's into ~/cartel/patron. The dir stays writable so the
    # agent CLI can still create its own session files (e.g. .claude/) alongside.
    home.file = {
      "cartel/patron/AGENTS.md".source = ./cartel/patron/AGENTS.md;
      "cartel/patron/CLAUDE.md".text = "@AGENTS.md\n";
    };
  };
}
