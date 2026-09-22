{
  description = "Work machine nix-darwin configuration";

  inputs = {
    personal-config.url = "path:..";
    # Tracks upstream closely so kubelogin-oidc can stay >= 1.36 (see overlay
    # below); the pinned nixpkgs-25.11 only ships 1.34.x.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    # Herdr agent multiplexer (https://herdr.dev) — official flake, built from
    # source. Pin to a release tag; bump this to upgrade. Uses its own pinned
    # inputs (do not override nixpkgs: it pins Zig 0.15.2 via zig-overlay for
    # its vendored libghostty-vt, which newer Zig fails to compile).
    herdr.url = "github:ogulcancelik/herdr/v0.7.3";
    lunar-tools = {
      url = "git+ssh://git@github.com/lunarway/lw-nix";
    };
  };

  outputs = { personal-config, nixpkgs-unstable, herdr, lunar-tools, ... }:
  let
    inherit (personal-config.lib) mkSystem;

    # Work-only package overrides, layered on top of the shared config.
    workOverlay = final: prev:
    let
      up = nixpkgs-unstable.legacyPackages.${prev.stdenv.hostPlatform.system};
    in
    {
      # kubelogin 1.36.0 changed the oidc-login token-cache key (added
      # AuthRequestExtraParams to the gob-encoded tokencache.Key), which changes
      # every cache filename. The lunarctl port-forward-cli plugin embeds
      # kubelogin >= 1.36, so a 1.34 minting binary writes tokens under
      # filenames the plugin never reads -> "no auth token found". Pin to
      # unstable's 1.36.x so the minting binary matches the plugin.
      kubelogin-oidc = up.kubelogin-oidc;

      # Pi coding agent — now a first-class package in this repo built from a
      # committed lockfile (packages/pi). Bump it with `nix run .#update-packages`.
      # Aliased to the name the work home config already expects.
      pi-coding-agent = personal-config.packages.${prev.stdenv.hostPlatform.system}.pi;

      # Herdr agent multiplexer, from its official flake.
      herdr = herdr.packages.${prev.stdenv.hostPlatform.system}.default;
    };
  in
  {
    darwinConfigurations.work-mac = mkSystem {
      user = "edb";
      homeModule = ../hosts/work/home.nix;
      hostModule = ../hosts/work;
      extraOverlays = [ lunar-tools.overlays.default workOverlay ];
      gitConfig = {
        userName = "Edvard Boguslavskij";
        userEmail = "edb@lunar.app";
        signingKey = "/Users/edb/.ssh/github.pub";
        workSSHKey = "/Users/edb/.ssh/github";
        personalSSHKey = "/Users/edb/.ssh/id_ed25519";
        enableLunarUrls = true;
        enablePersonalAlias = true;
        user = "edb";
      };
    };
  };
}
