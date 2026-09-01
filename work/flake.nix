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
        version = "0.84.4";
        src = up.fetchurl {
          url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${version}.tgz";
          hash = "sha512-jmOlrqUmvhh/siNWFRXjYLJzhKFIHNsAQaysRwzQPQFnPAaV/vhqHsLH/MBsIISA1Rjj7WTUFR3nJrpXoLx39w==";
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
          addIntegrity pi-agent-core "sha512-HyUnjaOXj6oN/6SNcr8A1J/ElRQA50FtIE0XUTSKAQVqmdlb9qdojOyUQwF/jULE5+yOEtGuVgi/N1RnBiNG+g=="
          addIntegrity pi-ai "sha512-AClAZxf5+c4RRu44NJPS6wyQy+Nmq+Mzyyrdvm4ZVMNuixelO02RZX4G4Aq1F145Yzp43wnM5S+hLlSI7ypfVw=="
          addIntegrity pi-client "sha512-q398WY/3ZQHTizk7IKxApzqFV0xt4yM9LkSkwyqeLK5Bj5RwRjOWxESt26z4LgNp4O+8hqhqFPf/8fj4H5rE4A=="
          addIntegrity pi-protocol "sha512-acyE9ozxkMiWiz/xyWpU0O9vwnYv0hyG889Vniv6Sg9c9zfsX+8MePnDNphBacY2Fvm1rxdsGmiVDSZl9yuDFA=="
          addIntegrity pi-telemetry "sha512-8e2CuxM+ht+hedQXTZmi5JVl6/xDK9RpSDL2+MbITevKYQhMZ/z6lJOTFgox3HQyGxO8mOZEtYGVeQNaD4OzqA=="
          addIntegrity pi-tui "sha512-nPUnwDkLtupPXnZQYrCwPFcuTydCDqTY6ZbFqhsL4S4kVq0AT418kPa/6uXwtaCD+MjBNBltb7ScTYX65yeE1w=="
          cp npm-shrinkwrap.json package-lock.json

          # Upstream ships a production-only shrinkwrap (no dev deps), but
          # package.json still lists devDependencies. That mismatch makes
          # `npm ci` try to fetch dev-only packages (e.g. @types/cross-spawn),
          # which fails offline (ENOTCACHED). Drop devDependencies so the
          # manifest matches the lockfile; dist/ is prebuilt so we never need
          # them. package.json is tab-indented.
          sed -i '/^\t"devDependencies": {/,/^\t},/d' package.json
        '';
        npmDepsHash = "sha256-TMCFuLn2EbzAPrTN0XGZoJj7sHNqMA77YNFCRcU0JWI=";
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
