{
  lib,
  buildNpmPackage,
  fetchurl,
  runCommand,
  writeShellScript,
  curl,
  jq,
  nix,
  nodejs_22,
  gnugrep,
  fd,
  ripgrep,
}:

let
  versions = lib.importJSON ./versions.json;
  inherit (versions.pi) version sourceHash npmDepsHash;

  # Pi ships its own `npm-shrinkwrap.json`, which omits `integrity` for its
  # sibling @earendil-works/* packages (prefetch-npm-deps panics on that) and is
  # production-only (so `npm ci` later fails fetching dev deps offline). Instead
  # of patching the shrinkwrap in place, drop it and swap in a full lockfile we
  # regenerate ourselves via the updateScript (`npm install --package-lock-only`),
  # which records integrity + the dev tree for every dependency.
  srcWithLock = runCommand "pi-src-with-lock" { } ''
    mkdir -p "$out"
    tar -xzf ${
      fetchurl {
        url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${version}.tgz";
        hash = sourceHash;
      }
    } -C "$out" --strip-components=1
    rm -f "$out/npm-shrinkwrap.json"
    cp ${./package-lock.json} "$out/package-lock.json"
  '';
in
buildNpmPackage {
  pname = "pi";
  inherit version;

  src = srcWithLock;
  inherit npmDepsHash;
  makeCacheWritable = true;
  dontNpmBuild = true; # dist/ is prebuilt in the published tarball
  nodejs = nodejs_22; # pi requires node >= 22.19
  # The lockfile is regenerated with --legacy-peer-deps (see updateScript), so
  # `npm ci` must match or it tries to reify (and fetch) omitted peers offline.
  npmFlags = [
    "--legacy-peer-deps"
    "--ignore-scripts"
  ];

  postInstall = ''
    wrapProgram "$out/bin/pi" \
      --prefix PATH : ${
        lib.makeBinPath [
          fd
          ripgrep
        ]
      } \
      --set PI_SKIP_VERSION_CHECK 1 \
      --set PI_TELEMETRY 0
  '';

  # `nix run .#update-packages` invokes this; `repo_root` is exported by that
  # app. Queries npm for the latest version, regenerates the lockfile + hashes,
  # then builds once with a fake npmDepsHash to capture the real one.
  passthru.updateScript = writeShellScript "update-pi" ''
    set -euo pipefail
    version_json="$repo_root/packages/pi/versions.json"
    lock_file="$repo_root/packages/pi/package-lock.json"
    version="$(${nodejs_22}/bin/npm view @earendil-works/pi-coding-agent version --json | ${lib.getExe jq} -r .)"
    tarball="https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-$version.tgz"
    source_hash="$(${lib.getExe nix} hash convert --hash-algo sha256 --to sri \
      $(${nix}/bin/nix-prefetch-url --type sha256 "$tarball" 2>&1 | tail -1))"
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT
    ${lib.getExe curl} -fsSL "$tarball" -o "$tmp_dir/source.tgz"
    tar -xzf "$tmp_dir/source.tgz" -C "$tmp_dir" --strip-components=1
    rm -f "$tmp_dir/npm-shrinkwrap.json"
    (cd "$tmp_dir" && ${nodejs_22}/bin/npm install --package-lock-only --ignore-scripts --omit=dev --legacy-peer-deps)
    cp "$tmp_dir/package-lock.json" "$lock_file"
    ${lib.getExe jq} -n --arg version "$version" --arg sourceHash "$source_hash" --arg npmDepsHash "${lib.fakeHash}" \
      '{formatVersion: 1, pi: {version: $version, sourceHash: $sourceHash, npmDepsHash: $npmDepsHash}}' > "$version_json"
    set +e
    output="$(${nix}/bin/nix build ".#pi" --no-link --print-build-logs 2>&1)"
    status="$?"
    set -e
    if [ "$status" -eq 0 ]; then
      echo "pi npmDepsHash did not need updating"
      exit 0
    fi
    npm_deps_hash="$(printf '%s\n' "$output" | ${lib.getExe gnugrep} -Eo 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' | ${lib.getExe gnugrep} -Eo 'sha256-[A-Za-z0-9+/=]+' | tail -1)"
    if [ -z "$npm_deps_hash" ]; then
      printf '%s\n' "$output" >&2
      echo "Could not determine npmDepsHash from nix build output" >&2
      exit "$status"
    fi
    tmp_json="$(mktemp)"
    ${lib.getExe jq} --arg npmDepsHash "$npm_deps_hash" '.pi.npmDepsHash = $npmDepsHash' "$version_json" > "$tmp_json"
    mv "$tmp_json" "$version_json"
    echo "Updated pi to version $version"
  '';

  meta = {
    description = "Terminal-based coding agent with multi-model support";
    homepage = "https://github.com/earendil-works/pi";
    license = lib.licenses.mit;
    mainProgram = "pi";
    platforms = lib.platforms.all;
    sourceProvenance = with lib.sourceTypes; [ binaryBytecode ];
  };
}
