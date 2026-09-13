{
  buildGoModule,
  ffmpeg,
  goModels,
  lib,
  makeWrapper,
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
      ./worker
      ./go.mod
      ./go.sum
    ];
  };

  vendorHash = "sha256-n5f+o0UTkD4Y+TVFeTNPEt02pTrAOd/kOfxlVHiew7A=";

  RADARR_REPAIR_TEST_FFMPEG = lib.getExe ffmpeg;
  RADARR_REPAIR_TEST_FFPROBE = lib.getExe' ffmpeg "ffprobe";

  postPatch = ''
    cp ${goModels}/models.gen.go contracts/models.gen.go
    cp ${goModels}/worker-models.gen.go worker/contracts/models.gen.go
  '';

  nativeBuildInputs = [ makeWrapper ];

  subPackages = [
    "cmd/radarr-repair"
    "cmd/radarr-repair-worker"
  ];

  postInstall = ''
    wrapProgram "$out/bin/radarr-repair-worker" \
      --add-flags ${lib.escapeShellArg "--ffprobe ${lib.getExe' ffmpeg "ffprobe"}"}
  '';

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
    "$out/bin/radarr-repair-worker" -h >/dev/null
    runHook postInstallCheck
  '';

  meta = {
    description = "Deterministic controller for repairing failed Radarr imports";
    license = lib.licenses.mit;
    mainProgram = "radarr-repair";
    platforms = lib.platforms.linux;
  };
}
