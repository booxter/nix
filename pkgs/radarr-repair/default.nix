{
  buildGoModule,
  ffmpeg,
  goModels,
  lib,
  makeWrapper,
}:
let
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./cmd
      ./contract-tests
      ./contracts
      ./internal
      ./worker
      ./go.mod
      ./go.sum
    ];
  };
  common = {
    inherit src version;
    vendorHash = "sha256-k8ZD+en3FYpJ7tlPkmuLm7jtGMPH84IBEFaEi+F0Wv4=";
    postPatch = ''
      cp ${goModels}/models.gen.go contracts/models.gen.go
      cp ${goModels}/worker-models.gen.go worker/contracts/models.gen.go
    '';
    meta = {
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  };

  controller = buildGoModule (
    common
    // {
      pname = "radarr-repair";
      subPackages = [ "cmd/radarr-repair" ];

      RADARR_REPAIR_TEST_FFMPEG = lib.getExe ffmpeg;
      RADARR_REPAIR_TEST_FFPROBE = lib.getExe' ffmpeg "ffprobe";

      preCheck = ''
        unformatted="$(gofmt -l cmd contracts internal worker)"
        if test -n "$unformatted"; then
          gofmt -d cmd contracts internal worker >&2
          exit 1
        fi
        go vet ./...
      '';
      checkPhase = ''
        runHook preCheck
        go test ./... -cover
        runHook postCheck
      '';

      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        "$out/bin/radarr-repair" validate-case contracts/v1/examples/repair-case-joinable.json
        "$out/bin/radarr-repair" validate-decision contracts/v1/examples/repair-decision-join.json
        "$out/bin/radarr-repair" inspect -h >/dev/null
        "$out/bin/radarr-repair" shadow -h >/dev/null
        runHook postInstallCheck
      '';

      disallowedReferences = [ (lib.getBin ffmpeg) ];

      meta = common.meta // {
        description = "Deterministic controller for repairing failed Radarr imports";
        mainProgram = "radarr-repair";
      };
    }
  );

  worker = buildGoModule (
    common
    // {
      pname = "radarr-repair-worker";
      subPackages = [ "cmd/radarr-repair-worker" ];

      nativeBuildInputs = [ makeWrapper ];
      postInstall = ''
        wrapProgram "$out/bin/radarr-repair-worker" \
          --add-flags ${lib.escapeShellArg "--ffprobe ${lib.getExe' ffmpeg "ffprobe"}"} \
          --add-flags ${lib.escapeShellArg "--ffmpeg ${lib.getExe ffmpeg}"}
      '';

      doCheck = false;
      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        "$out/bin/radarr-repair-worker" -h >/dev/null
        runHook postInstallCheck
      '';

      meta = common.meta // {
        description = "Isolated media worker for Radarr repair";
        mainProgram = "radarr-repair-worker";
      };
    }
  );
in
{
  inherit controller worker;
}
