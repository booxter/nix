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
  version = "2.5.1";
  npmDepsHash = "sha256-lE4SCYRZuR2oh0VW+4KwUc/Jx2t6facHZGxkmbDWU5E=";
  src = fetchFromGitHub {
    owner = "lklynet";
    repo = "aurral";
    tag = "v${version}";
    sha256 = "sha256-TUSww/he02qzcqJEMEljpOEFyfjWngyMfqopUHzU0uk=";
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

    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck

    export LD_LIBRARY_PATH=${lib.makeLibraryPath [ sqlite ]}
    node --test \
      .tests/auth/local-auth.test.js \
      .tests/settings/managed-slskd.test.js

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    npm prune --omit=dev --ignore-scripts --workspaces --include-workspace-root
    rm -rf frontend/node_modules

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
