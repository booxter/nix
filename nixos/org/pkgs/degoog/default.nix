{
  bun,
  cacert,
  curl,
  curl-impersonate,
  fetchFromGitHub,
  gitMinimal,
  lib,
  makeWrapper,
  stdenvNoCC,
  writableTmpDirAsHomeHook,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "degoog";
  version = "0.23.0";

  src = fetchFromGitHub {
    owner = "degoog-org";
    repo = "degoog";
    tag = finalAttrs.version;
    hash = "sha256-+ReSP9pMgt92E9Li9G36eQYoLuwd94ZZ9c4j/3eb068=";
  };

  # Backport the corrected test from upstream develop commit 6825b7d3. The
  # release test expected an empty index to advertise a web search type.
  patches = [ ./backport-indexer-engine-selection-test-fix.patch ];

  nativeBuildInputs = [
    bun
    makeWrapper
    writableTmpDirAsHomeHook
  ];

  buildPhase = ''
    runHook preBuild

    cp -R ${finalAttrs.passthru.nodeModules}/node_modules .
    chmod -R u+w node_modules
    NODE_ENV=production bun run build

    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck

    bun node_modules/typescript/bin/tsc --noEmit
    bun run test

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share/degoog
    cp -R src package.json bun.lock $out/share/degoog/
    ln -s ${finalAttrs.passthru.productionNodeModules}/node_modules \
      $out/share/degoog/node_modules

    makeWrapper ${lib.getExe bun} $out/bin/degoog \
      --add-flags "run --prefer-offline --no-install src/server/index.ts" \
      --chdir "$out/share/degoog" \
      --prefix PATH : ${
        lib.makeBinPath [
          curl
          curl-impersonate
          gitMinimal
        ]
      } \
      --set-default NODE_ENV production \
      --set-default SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt"

    runHook postInstall
  '';

  passthru = {
    nodeModules = finalAttrs.passthru.mkNodeModules {
      production = false;
      hash = "sha256-+Z/8Iwbay77QxszsufWqcXYaqXWX15BfMjkl8YPIGEg=";
    };
    productionNodeModules = finalAttrs.passthru.mkNodeModules {
      production = true;
      hash = "sha256-x1un55yNabTAWsLMfajCaZ6u0VDuP2YT29xkiN0gH80=";
    };
    mkNodeModules =
      {
        production,
        hash,
      }:
      stdenvNoCC.mkDerivation {
        pname = "degoog-${lib.optionalString production "production-"}node-modules";
        inherit (finalAttrs) version src;

        nativeBuildInputs = [
          bun
          writableTmpDirAsHomeHook
        ];

        dontConfigure = true;
        dontPatchShebangs = true;
        buildPhase = ''
          runHook preBuild

          bun install --frozen-lockfile --no-progress ${lib.optionalString production "--production"}

          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall

          mkdir -p $out
          rm -rf node_modules/.bin
          cp -R node_modules $out/

          runHook postInstall
        '';

        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = hash;
      };
  };

  meta = {
    description = "Search engine aggregator with a plugin and extension system";
    homepage = "https://github.com/degoog-org/degoog";
    changelog = "https://github.com/degoog-org/degoog/releases/tag/${finalAttrs.version}";
    license = lib.licenses.agpl3Only;
    mainProgram = "degoog";
    platforms = [ "x86_64-linux" ];
  };
})
