{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchNpmDeps,
  buildPackages,
  nodejs_25,
  python3,
  makeWrapper,
}:
let
  nodejs = nodejs_25;
  npmHooks = buildPackages.npmHooks.override { inherit nodejs; };
  pname = "aurral";
  version = "1.60.3";
  src = fetchFromGitHub {
    owner = "lklynet";
    repo = "aurral";
    tag = "v${version}";
    sha256 = "1v4bgyq9ys3mwcml73534f3ch5l5299spi8rvip7vsn8qcpaqr1b";
  };
  npmDeps = fetchNpmDeps {
    name = "${pname}-${version}-npm-deps";
    inherit src;
    hash = "sha256-HmW/B3FpwtCzbhHf3u6hdgdhRBKj5Rynk8LeLypY/Q0=";
  };
  frontendNpmDeps = fetchNpmDeps {
    name = "${pname}-${version}-frontend-npm-deps";
    src = "${src}/frontend";
    hash = "sha256-rwy8A0dE4gycZu995bhS9RjciuVv0/Vu1Nde3MDZyRY=";
  };
  backendNpmDeps = fetchNpmDeps {
    name = "${pname}-${version}-backend-npm-deps";
    src = "${src}/backend";
    hash = "sha256-IiANiFuDbGQJEUVQaVOEgfxSQxL13jMVqpt0TFCzNik=";
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
    # Install all three npm dependency trees from fixed offline caches.
    (
      local postPatchHooks=()
      source ${npmHooks.npmConfigHook}/nix-support/setup-hook

      npmDeps="${npmDeps}" npmConfigHook
      rm -rf "$TMPDIR/cache"

      npmRoot=backend npmDeps="${backendNpmDeps}" npmConfigHook
      rm -rf "$TMPDIR/cache"

      npmRoot=frontend npmDeps="${frontendNpmDeps}" npmConfigHook
      rm -rf "$TMPDIR/cache"
    )
  '';

  buildPhase = ''
    runHook preBuild

    npm --prefix frontend run build

    npm prune --omit=dev --ignore-scripts
    npm --prefix backend prune --omit=dev --ignore-scripts

    rm -rf frontend/node_modules

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/lib/${pname}/backend" "$out/lib/${pname}/frontend"

    cp package.json loadEnv.js server.js "$out/lib/${pname}/"
    cp -r node_modules "$out/lib/${pname}/"
    cp backend/package.json "$out/lib/${pname}/backend/"
    cp -r backend/config \
      backend/middleware \
      backend/routes \
      backend/scripts \
      backend/services \
      backend/node_modules \
      "$out/lib/${pname}/backend/"
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

    exec ${lib.getExe nodejs} "$out/lib/${pname}/server.js" "\$@"
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
