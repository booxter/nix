{ inputs, helpers }:
helpers.forAllSystems (
  system:
  let
    pkgs = import inputs.nixpkgs { inherit system; };
    customPackages = import ./pkgs pkgs;
    mkCheck =
      {
        name,
        nativeBuildInputs,
        buildPhase,
      }:
      pkgs.stdenv.mkDerivation {
        inherit name nativeBuildInputs buildPhase;
        src = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            ./scripts
            ./tests
          ];
        };
        installPhase = ''
          touch "$out"
        '';
      };
  in
  {
    bats-tests = mkCheck {
      name = "bats-tests";
      nativeBuildInputs = with pkgs; [
        bats
        git
        jq
        yq
      ];
      buildPhase = ''
        bats tests/get-local-builders.bats
        bats tests/test-prox-deploy.bats
        bats tests/test-sops-config.bats
        bats tests/test-sops-copy.bats
        bats tests/test-vm.bats
        bats tests/update-machines.bats
      '';
    };
    box-py = mkCheck {
      name = "box-py-tests";
      nativeBuildInputs = with pkgs; [
        python3
        python3Packages.pytest
      ];
      buildPhase = ''
        pytest -q tests/test_box.py
      '';
    };
    join-media-parts = mkCheck {
      name = "join-media-parts-tests";
      nativeBuildInputs = with pkgs; [
        ffmpeg
        customPackages."join-media-parts"
      ];
      buildPhase = ''
        mkdir -p work
        cd work

        mkdir 'ts case'
        ffmpeg -hide_banner -loglevel error -y \
          -f lavfi -i color=c=black:s=64x64:r=25:d=1 \
          -f lavfi -i sine=frequency=440:sample_rate=48000:d=1 \
          -c:v libx264 -pix_fmt yuv420p -f mpegts \
          -c:a mp2 -shortest \
          'ts case/01_part.ts'
        ffmpeg -hide_banner -loglevel error -y \
          -f lavfi -i color=c=blue:s=64x64:r=25:d=1 \
          -f lavfi -i sine=frequency=880:sample_rate=48000:d=1 \
          -c:v libx264 -pix_fmt yuv420p -f mpegts \
          -c:a mp2 -shortest \
          'ts case/02_part.ts'
        join-media-parts 'ts case'
        test -f 'ts case/ts case.mkv'
        ffprobe -hide_banner -loglevel error 'ts case/ts case.mkv' >/dev/null
        ffprobe -hide_banner -loglevel error \
          -show_entries stream=codec_type \
          -of csv=p=0 \
          'ts case/ts case.mkv' \
          | awk 'BEGIN { video = 0; audio = 0 } $0 == "video" { video++ } $0 == "audio" { audio++ } END { exit !(video == 1 && audio == 1) }'

        mkdir 'mp4 case (sample)'
        ffmpeg -hide_banner -loglevel error -y \
          -f lavfi -i color=c=red:s=64x64:r=25:d=1 \
          -c:v libx264 -pix_fmt yuv420p \
          'mp4 case (sample)/Part 01 (sample).mp4'
        ffmpeg -hide_banner -loglevel error -y \
          -f lavfi -i color=c=green:s=64x64:r=25:d=1 \
          -c:v libx264 -pix_fmt yuv420p \
          'mp4 case (sample)/Part 02 (sample).mp4'
        join-media-parts 'mp4 case (sample)'
        test -f 'mp4 case (sample)/mp4 case (sample).mp4'
        ffprobe -hide_banner -loglevel error 'mp4 case (sample)/mp4 case (sample).mp4' >/dev/null
      '';
    };
  }
)
