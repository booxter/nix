{
  buildGoModule,
  ffmpeg,
  goModels,
  lib,
  radarr,
}:
buildGoModule {
  pname = "radarr-repair";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./cmd
      ./contract-tests
      ./contracts
      ./internal
      ./go.mod
      ./go.sum
    ];
  };

  vendorHash = "sha256-2RYdCyKWvNdrZZ4DxalltC+lIKq7kNkuIZ2N5DCF0ak=";

  RADARR_REPAIR_TEST_FFMPEG = lib.getExe ffmpeg;
  RADARR_REPAIR_TEST_FFPROBE = lib.getExe' ffmpeg "ffprobe";

  postPatch = ''
    cp ${goModels}/models.gen.go contracts/models.gen.go
  '';

  subPackages = [ "cmd/radarr-repair" ];

  preCheck = ''
    grep -Fq ${lib.escapeShellArg "File is suspected multi-part file, Radarr doesn't support this"} ${radarr.src}/src/NzbDrone.Core/MediaFiles/MovieImport/Specifications/NotMultiPartSpecification.cs
    unformatted="$(gofmt -l cmd contracts internal)"
    if test -n "$unformatted"; then
      gofmt -d cmd contracts internal >&2
      exit 1
    fi
    go vet ./...
  '';
  checkPhase = ''
    runHook preCheck
    go test ./... -cover
    runHook postCheck
  '';

  __darwinAllowLocalNetworking = true;

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/radarr-repair" validate-case contracts/v1/examples/repair-case-joinable.json
    "$out/bin/radarr-repair" validate-decision contracts/v1/examples/repair-decision-join.json
    runHook postInstallCheck
  '';

  meta = {
    description = "Deterministic controller for repairing failed Radarr imports";
    license = lib.licenses.mit;
    mainProgram = "radarr-repair";
    platforms = lib.platforms.unix;
  };
}
