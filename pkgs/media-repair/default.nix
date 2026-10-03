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
  common = {
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
    vendorHash = "sha256-mY6wLOXTENSzN0hUhiS+D3iIJXfhKP2ptY2VP+GWlIA=";
    postPatch = ''
      cp ${goModels}/models.gen.go contracts/models.gen.go
      cp ${goModels}/worker-models.gen.go worker/contracts/models.gen.go
    '';
    meta = {
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  };
in
{
  daemon = buildGoModule (
    common
    // {
      pname = "repairr";
      subPackages = [
        "cmd/repairr"
        "cmd/repairr-migrate"
      ];

      nativeCheckInputs = [
        ffmpeg-full
        cuetools
        mkvtoolnixCli
        wavpack
      ];

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
        go test -race ./... -cover
        runHook postCheck
      '';
      meta = common.meta // {
        description = "Media repair controller and operator inbox";
        mainProgram = "repairr";
      };
    }
  );

  helper = buildGoModule (
    common
    // {
      pname = "media-repair-helper";
      subPackages = [ "cmd/media-repair-helper" ];
      nativeBuildInputs = [ makeWrapper ];
      postInstall = ''
        wrapProgram "$out/bin/media-repair-helper" \
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
      # The daemon derivation runs the complete suite, including real-media
      # helper tests, with the media executables available.
      doCheck = false;
      meta = common.meta // {
        description = "Stateless media repair operations";
        mainProgram = "media-repair-helper";
      };
    }
  );
}
