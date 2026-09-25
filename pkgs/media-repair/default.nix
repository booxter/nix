{
  buildGoModule,
  cuetools,
  ffmpeg-full,
  goModels,
  lib,
  lsdvd,
  makeWrapper,
  mkvtoolnixCli,
  unar,
  wavpack,
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
      ./lidarrcontracts
      ./worker
      ./go.mod
      ./go.sum
    ];
  };
  common = {
    inherit src version;
    vendorHash = "sha256-d1IeUVUYDXIwqT+Wq8SYJGw02oR3d0YWv8gl4pN9Kec=";
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

      RADARR_REPAIR_TEST_FFMPEG = lib.getExe' ffmpeg-full "ffmpeg";
      RADARR_REPAIR_TEST_FFPROBE = lib.getExe' ffmpeg-full "ffprobe";
      RADARR_REPAIR_TEST_MKVMERGE = lib.getExe' mkvtoolnixCli "mkvmerge";
      RADARR_REPAIR_TEST_LSDVD = lib.getExe' lsdvd "lsdvd";
      RADARR_REPAIR_TEST_LSAR = lib.getExe' unar "lsar";
      RADARR_REPAIR_TEST_UNAR = lib.getExe unar;
      RADARR_REPAIR_TEST_CUECONVERT = lib.getExe' cuetools "cueconvert";
      RADARR_REPAIR_TEST_CUEBREAKPOINTS = lib.getExe' cuetools "cuebreakpoints";
      RADARR_REPAIR_TEST_WAVPACK = lib.getExe' wavpack "wavpack";
      RADARR_REPAIR_TEST_WVUNPACK = lib.getExe' wavpack "wvunpack";
      RADARR_REPAIR_TEST_WORKER = lib.getExe worker;

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
        "$out/bin/radarr-repair" validate-case contracts/v3/examples/repair-case-joinable.json
        "$out/bin/radarr-repair" validate-decision contracts/v3/examples/repair-decision-join.json
        "$out/bin/radarr-repair" inspect -h >/dev/null
        "$out/bin/radarr-repair" run -h >/dev/null
        "$out/bin/radarr-repair" shadow -h >/dev/null
        "$out/bin/radarr-repair" execute-case -h >/dev/null
        runHook postInstallCheck
      '';

      disallowedReferences = [ (lib.getBin ffmpeg-full) ];

      meta = common.meta // {
        description = "Deterministic controller for repairing failed Radarr imports";
        mainProgram = "radarr-repair";
      };
    }
  );

  lidarrController = buildGoModule (
    common
    // {
      pname = "lidarr-repair";
      subPackages = [ "cmd/lidarr-repair" ];

      preCheck = ''
        unformatted="$(gofmt -l cmd/lidarr-repair internal/fileidentity internal/lidarr internal/lidarrrepair internal/mediaroot internal/plannerclient internal/planning internal/planningstate internal/privatefile internal/servarr internal/workerclient lidarrcontracts)"
        if test -n "$unformatted"; then
          gofmt -d cmd/lidarr-repair internal/fileidentity internal/lidarr internal/lidarrrepair internal/mediaroot internal/plannerclient internal/planning internal/planningstate internal/privatefile internal/servarr internal/workerclient lidarrcontracts >&2
          exit 1
        fi
        go vet ./cmd/lidarr-repair ./internal/fileidentity ./internal/lidarr ./internal/lidarrrepair ./internal/mediaroot ./internal/plannerclient ./internal/planning ./internal/planningstate ./internal/privatefile ./internal/servarr ./internal/workerclient ./lidarrcontracts
      '';
      checkPhase = ''
        runHook preCheck
        go test ./cmd/lidarr-repair ./internal/fileidentity ./internal/lidarr ./internal/lidarrrepair ./internal/mediaroot ./internal/plannerclient ./internal/planning ./internal/planningstate ./internal/privatefile ./internal/servarr ./internal/workerclient ./lidarrcontracts -cover
        runHook postCheck
      '';

      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        "$out/bin/lidarr-repair" -h >/dev/null
        runHook postInstallCheck
      '';

      meta = common.meta // {
        description = "Shadow-mode controller for Lidarr import repair";
        mainProgram = "lidarr-repair";
      };
    }
  );

  worker = buildGoModule (
    common
    // {
      pname = "media-repair-worker";
      subPackages = [ "cmd/media-repair-worker" ];

      nativeBuildInputs = [ makeWrapper ];
      postInstall = ''
        wrapProgram "$out/bin/media-repair-worker" \
          --add-flags ${lib.escapeShellArg "--ffprobe ${lib.getExe' ffmpeg-full "ffprobe"}"} \
          --add-flags ${lib.escapeShellArg "--ffmpeg ${lib.getExe' ffmpeg-full "ffmpeg"}"} \
          --add-flags ${lib.escapeShellArg "--lsdvd ${lib.getExe' lsdvd "lsdvd"}"} \
          --add-flags ${lib.escapeShellArg "--mkvmerge ${lib.getExe' mkvtoolnixCli "mkvmerge"}"} \
          --add-flags ${lib.escapeShellArg "--lsar ${lib.getExe' unar "lsar"}"} \
          --add-flags ${lib.escapeShellArg "--unar ${lib.getExe unar}"} \
          --add-flags ${lib.escapeShellArg "--cueconvert ${lib.getExe' cuetools "cueconvert"}"} \
          --add-flags ${lib.escapeShellArg "--cuebreakpoints ${lib.getExe' cuetools "cuebreakpoints"}"} \
          --add-flags ${lib.escapeShellArg "--wvunpack ${lib.getExe' wavpack "wvunpack"}"}
      '';

      doCheck = false;
      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        "$out/bin/media-repair-worker" -h >/dev/null
        runHook postInstallCheck
      '';

      meta = common.meta // {
        description = "Isolated worker for media repair";
        mainProgram = "media-repair-worker";
      };
    }
  );

  review = buildGoModule (
    common
    // {
      pname = "media-repair-review";
      subPackages = [ "cmd/media-repair-review" ];

      preCheck = ''
        unformatted="$(gofmt -l cmd/media-repair-review internal/review)"
        if test -n "$unformatted"; then
          gofmt -d cmd/media-repair-review internal/review >&2
          exit 1
        fi
        go vet ./cmd/media-repair-review ./internal/review
      '';
      checkPhase = ''
        runHook preCheck
        go test ./cmd/media-repair-review ./internal/review -cover
        runHook postCheck
      '';

      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        "$out/bin/media-repair-review" -h >/dev/null
        runHook postInstallCheck
      '';

      meta = common.meta // {
        description = "Read-only review inbox for Servarr repair decisions";
        mainProgram = "media-repair-review";
      };
    }
  );
in
{
  inherit
    controller
    lidarrController
    review
    worker
    ;
}
