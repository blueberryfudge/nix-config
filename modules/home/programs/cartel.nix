{
  pkgs,
  lib,
  config,
  ...
}:

# cartel - talk to your patrón, run a crew of sicarios (Herdr + git worktrees).
# A single stdlib-only Go binary: the CLI, the herdr event transport, and an
# on-demand self-spawning daemon that owns composer-safe reporting to the patrón.
# Mutable state lives under $CARTEL_HOME (~/cartel); only the patrón instructions
# are managed here so the crew's runtime state stays out of the store.
let
  cfg = config.cartel;

  # One binary. herdr (mutations + event socket) and git (worktree teardown) are
  # the only runtime deps - the classifier/JSON/queue work is all native Go now,
  # so jq/awk/sed/grep/coreutils are no longer needed on PATH.
  cartel = pkgs.buildGoModule {
    pname = "cartel";
    version = "0.2.0";
    src = ./cartel/src;
    vendorHash = null; # stdlib-only

    nativeBuildInputs = [ pkgs.makeWrapper ];
    postInstall = ''
      wrapProgram $out/bin/cartel \
        --prefix PATH : ${lib.makeBinPath [
          pkgs.herdr
          pkgs.git
        ]}
    '';
  };
in
{
  options.cartel.enable = lib.mkEnableOption "cartel agent orchestrator (patrón + sicarios over Herdr)";

  config = lib.mkIf cfg.enable {
    home.packages = [ cartel ];

    # Patrón (orchestrator) instructions, loaded as strong project memory when
    # `cartel patron` cd's into ~/cartel/patron. The dir stays writable so the
    # agent CLI can still create its own session files (e.g. .claude/) alongside.
    home.file = {
      "cartel/patron/AGENTS.md".source = ./cartel/patron/AGENTS.md;
      "cartel/patron/CLAUDE.md".text = "@AGENTS.md\n";
    };
  };
}
