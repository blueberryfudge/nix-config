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

      # Pi coding agent (https://pi.dev) — distributed only via npm, so build it
      # from the published tarball. `src` hash is npm's own SRI integrity.
      # npmDepsHash must be filled after the first build (see the note below):
      # run the build once, copy the "got: sha256-..." value from the error.
      pi-coding-agent = up.buildNpmPackage rec {
        pname = "pi-coding-agent";
        version = "0.80.6";
        src = up.fetchurl {
          url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${version}.tgz";
          hash = "sha512-vcfD6tOk402isLl3Cm/qbn2O10TvgroMp1+/fEGM24ZdvETFCdOYv5VZ7m59EI5fPsjfSJh+CpQ5bhBrhfOg7g==";
        };
        # pi's shrinkwrap omits `integrity` for its own sibling packages, which
        # makes prefetch-npm-deps panic ("non-git dependencies should have
        # associated integrity"). The deps-fetcher sandbox has no node, so inject
        # the registry SRI hashes with sed, then mirror the shrinkwrap to
        # package-lock.json (which prefetch-npm-deps expects).
        postPatch = ''
          addIntegrity() {
            sed -i "s|\(\"resolved\": \"https://registry.npmjs.org/@earendil-works/$1/-/$1-${version}.tgz\",\)|\1\n          \"integrity\": \"$2\",|" npm-shrinkwrap.json
          }
          addIntegrity pi-agent-core "sha512-Lvn89ko42h5ETUb6Z0Ku6ldskEqXaTdQBYvSa0+7bdG9V6rUEpXptv5e0OVZ1HDcvi8s6/2lGCQWsxKX+DFHNw=="
          addIntegrity pi-ai "sha512-7xfLk8sANBp+bpPEbjoOZTbPxsa+++b1JXAoSJsNa3vbs9AHHEclmvg54XLQcxH+fuwaeti/g2jeIfJ+mVYLpA=="
          addIntegrity pi-tui "sha512-bSuzS4EVSqEPj/Qr/p9eqCESfKsGuDNbl77EGci8Iaqqt/C/XCBZL1MjXaxSWW1NsT5afjp/Cb0NTPzOLv/aPA=="
          cp npm-shrinkwrap.json package-lock.json

          # Upstream ships a production-only shrinkwrap (no dev deps), but
          # package.json still lists devDependencies. That mismatch makes
          # `npm ci` try to fetch dev-only packages (e.g. @types/cross-spawn),
          # which fails offline (ENOTCACHED). Drop devDependencies so the
          # manifest matches the lockfile; dist/ is prebuilt so we never need
          # them. package.json is tab-indented.
          sed -i '/^\t"devDependencies": {/,/^\t},/d' package.json
        '';
        npmDepsHash = "sha256-/2e8KD74cIKr1R6sLPoPevHByxIJFAfVuVgbf18b8WA=";
        dontNpmBuild = true;           # dist/ is prebuilt in the tarball
        npmFlags = [ "--ignore-scripts" ];
        nodejs = up.nodejs_22;         # pi requires node >= 22.19
      };

      # Herdr agent multiplexer, from its official flake.
      herdr = herdr.packages.${prev.stdenv.hostPlatform.system}.default;
    };
  in
  {
    darwinConfigurations.work-mac = mkSystem {
      user = "edb";
      homeModule = ../hosts/work/home.nix;
      hostModule = ../hosts/work;
      enableHomeBrew = true;
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
