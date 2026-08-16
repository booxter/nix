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
  version = "2.4.0";
  npmDepsHash = "sha256-Gk14mWB40JFhCpiZfFQ47CVu8gtLqJNonqr8kR3+XKQ=";
  src = fetchFromGitHub {
    owner = "lklynet";
    repo = "aurral";
    tag = "v${version}";
    sha256 = "sha256-zHzj/OSVvgd8v5B7IW2eQm+4+nU7/eIrIkILvG2gZ2w=";
  };
  npmDeps = fetchNpmDeps {
    name = "${pname}-${version}-npm-deps";
    inherit src;
    fetcherVersion = 2;
    hash = npmDepsHash;
  };
  runtimeStateDir = "/var/lib/aurral";
  runtimeFlowDir = "${runtimeStateDir}/flows";
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
    # Discovery artwork may live below a hidden AURRAL_DATA_DIR, which sendFile
    # rejects by default. The image proxy handles this upstream.
    ./aurral-allow-hidden-image-cache-path.patch
    # TODO: Submit managed slskd settings as an upstream feature request.
    ./managed-slskd-settings.patch
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

    export APP_VERSION=${lib.escapeShellArg version}
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
      const { default: sharp } = await import("sharp");
      const image = await sharp({
        create: {
          width: 1,
          height: 1,
          channels: 4,
          background: "#00000000",
        },
      }).png().toBuffer();
      if (image.length === 0) {
        throw new Error("sharp produced an empty image");
      }
      const { default: honker } = await import("@russellthehippo/honker-node");
      const honkerDatabase = honker.open(`''${process.env.AURRAL_DATA_DIR}/honker-smoke.db`);
      honkerDatabase.query("SELECT 1");
      honkerDatabase.close();
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
      const {
        applyManagedSlskdSettings,
        preserveStoredSlskdSettings,
      } = await import("./backend/config/managedSlskd.js");
      const managedEnvironment = {
        AURRAL_SLSKD_MANAGED: "true",
        AURRAL_SLSKD_URL: "http://127.0.0.2:5030",
        AURRAL_SLSKD_API_KEY: "test-api-key",
        AURRAL_SLSKD_PRIORITY: "20",
        AURRAL_SLSKD_CLEANUP_AFTER_RUNS: "true",
      };
      const managed = applyManagedSlskdSettings(
        { slskd: { apiKey: "stored-api-key" }, ytdlp: { enabled: true } },
        managedEnvironment,
      );
      if (
        managed.slskd.apiKey !== "test-api-key" ||
        managed.slskd.priority !== 20 ||
        managed.slskd.cleanupAfterRuns !== true ||
        managed.ytdlp.enabled !== true
      ) {
        throw new Error("managed slskd settings were not applied");
      }
      const preserved = preserveStoredSlskdSettings(
        managed,
        { slskd: { apiKey: "stored-api-key" } },
        managedEnvironment,
      );
      if (preserved.slskd.apiKey !== "stored-api-key") {
        throw new Error("managed slskd settings would be persisted");
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
    mainProgram = pname;
    platforms = lib.platforms.linux;
  };
}
