{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchNpmDeps,
  buildPackages,
  nodejs_22,
  patchelf,
  python3,
  makeWrapper,
  sqlite,
}:
let
  nodejs = nodejs_22;
  npmHooks = buildPackages.npmHooks.override { inherit nodejs; };
  pname = "aurral";
  version = "2.0.3";
  npmDepsHash = "sha256-QQmXYQ+mFS4gfM2KNCssvN3QdzTG2jAtW710Qgcoc10=";
  src = fetchFromGitHub {
    owner = "lklynet";
    repo = "aurral";
    tag = "v${version}";
    sha256 = "sha256-pfDRixnBEk6+ZsAhRipccnNjmn4aiFjrffdnxQmInXg=";
  };
  npmDeps = fetchNpmDeps {
    name = "${pname}-${version}-npm-deps";
    inherit src;
    fetcherVersion = 2;
    hash = npmDepsHash;
  };
  runtimeStateDir = "/data/.state/nixarr/aurral";
  runtimeFlowDir = "/data/media/library/flows";
in
stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [
    nodejs
    patchelf
    python3
    makeWrapper
  ];

  buildInputs = [ sqlite ];

  env = {
    APP_VERSION = version;
    SHARP_IGNORE_GLOBAL_LIBVIPS = "1";
    VITE_APP_VERSION = version;
    VITE_GITHUB_REPO = "lklynet/aurral";
    VITE_RELEASE_CHANNEL = "stable";
  };

  patches = [
    ./disable-local-auth.patch
    # AURRAL_DATA_DIR lives below /data/.state, which sendFile rejects by default.
    ../../../../overlays/aurral-allow-hidden-image-cache-path.patch
  ];

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
      backend/db \
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

  preFixup = ''
    # Honker links to system SQLite but ships its native binding without an
    # RPATH. Patch only its glibc bindings; npm also carries unrelated musl
    # prebuilds that must remain untouched.
    find "$out/lib/${pname}/node_modules/@russellthehippo" \
      -name 'honker.linux-*-gnu.node' \
      -exec patchelf --add-rpath '${lib.makeLibraryPath [ sqlite ]}' {} +
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    test -d "$out/lib/${pname}/backend/db"
    test ! -e "$out/lib/${pname}/backend/loadEnv.js"

    export AURRAL_DATA_DIR="$TMPDIR/aurral-install-check"
    mkdir -p "$AURRAL_DATA_DIR"
    pushd "$out/lib/${pname}"
    ${lib.getExe nodejs} --input-type=module --eval '
      const { default: Database } = await import("better-sqlite3");
      const database = new Database(":memory:");
      database.close();
      await import("sharp");
      await import("@russellthehippo/honker-node");
      await import("./backend/db/helpers/index.js");
      const { isLocalAuthEnabled } = await import("./backend/middleware/auth.js");
      delete process.env.DISABLE_LOCAL_AUTH;
      if (!isLocalAuthEnabled()) {
        throw new Error("local authentication was not enabled by default");
      }
      process.env.DISABLE_LOCAL_AUTH = "true";
      if (isLocalAuthEnabled()) {
        throw new Error("local authentication was not disabled");
      }
    '
    popd

    runHook postInstallCheck
  '';

  passthru.updateScript = [ ./update.sh ];

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
