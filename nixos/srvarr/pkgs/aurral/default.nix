{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchNpmDeps,
  buildPackages,
  nodejs_24,
  python3,
  makeWrapper,
}:
let
  nodejs = nodejs_24;
  npmHooks = buildPackages.npmHooks.override { inherit nodejs; };
  pname = "aurral";
  version = "1.76.50";
  src = fetchFromGitHub {
    owner = "lklynet";
    repo = "aurral";
    tag = "v${version}";
    sha256 = "sha256-Yxw41o6pfuTSZaulN337j9+v+CSEptYaMdy5Bha1T9U=";
  };
  npmDeps = fetchNpmDeps {
    name = "${pname}-${version}-npm-deps";
    inherit src;
    fetcherVersion = 2;
    hash = "sha256-UShOfNPPebtq4VXlmOdMxnl+8CxPP2dVwiaG8LASY98=";
  };
  runtimeStateDir = "/data/.state/nixarr/aurral";
  runtimeFlowDir = "/data/media/library/flows";
in
stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [
    nodejs
    python3
    makeWrapper
  ];

  env = {
    APP_VERSION = version;
    SHARP_IGNORE_GLOBAL_LIBVIPS = "1";
    VITE_APP_VERSION = version;
    VITE_GITHUB_REPO = "lklynet/aurral";
    VITE_RELEASE_CHANNEL = "stable";
  };

  postPatch = ''
    # Install the npm workspace tree from the fixed offline cache.
    (
      local postPatchHooks=()
      source ${npmHooks.npmConfigHook}/nix-support/setup-hook

      npmDeps="${npmDeps}" npmConfigHook
      rm -rf "$TMPDIR/cache"
    )
  '';

  buildPhase = ''
    runHook preBuild

    npm run build --workspace frontend

    npm prune --omit=dev --ignore-scripts --workspaces --include-workspace-root

    rm -rf frontend/node_modules

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/lib/${pname}/backend" "$out/lib/${pname}/frontend" "$out/lib/${pname}/lib"

    cp package.json "$out/lib/${pname}/"
    cp -r lib "$out/lib/${pname}/"
    cp -r node_modules "$out/lib/${pname}/"
    cp backend/package.json "$out/lib/${pname}/backend/"
    cp -r backend/config \
      backend/loadEnv.js \
      backend/middleware \
      backend/routes \
      backend/scripts \
      backend/server.js \
      backend/services \
      "$out/lib/${pname}/backend/"
    if [[ -d backend/node_modules ]]; then
      cp -r backend/node_modules "$out/lib/${pname}/backend/"
    fi
    cp -r frontend/dist "$out/lib/${pname}/frontend/"

    cat > "$out/bin/${pname}" <<EOF
    #!${stdenv.shell}
    set -euo pipefail

    : "\''${AURRAL_DATA_DIR:=${runtimeStateDir}}"
    : "\''${DOWNLOAD_FOLDER:=${runtimeFlowDir}}"
    : "\''${WEEKLY_FLOW_FOLDER:=${runtimeFlowDir}}"

    mkdir -p "\$AURRAL_DATA_DIR" "\$DOWNLOAD_FOLDER" "\$WEEKLY_FLOW_FOLDER"

    export AURRAL_DATA_DIR DOWNLOAD_FOLDER WEEKLY_FLOW_FOLDER
    export NODE_ENV=production

    exec ${lib.getExe nodejs} "$out/lib/${pname}/backend/server.js" "\$@"
    EOF
    chmod 0755 "$out/bin/${pname}"

    runHook postInstall
  '';

  meta = {
    description = "Self-hosted music discovery, request management, and flow downloads for Lidarr";
    homepage = "https://github.com/lklynet/aurral";
    changelog = "https://github.com/lklynet/aurral/releases/tag/v${version}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = pname;
    platforms = lib.platforms.linux;
  };
}
