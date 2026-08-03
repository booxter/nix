{
  clippy,
  ffmpeg,
  lib,
  rustfmt,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "join-media-parts";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.lock
      ./Cargo.toml
      ./src
      ./tests
    ];
  };

  cargoHash = "sha256-nLC85IfYKNEADvuMNShJrGwIOf4AWLdiCoZEyp7/0KE=";

  JOIN_MEDIA_PARTS_FFMPEG = lib.getExe ffmpeg;
  JOIN_MEDIA_PARTS_FFPROBE = lib.getExe' ffmpeg "ffprobe";

  nativeCheckInputs = [
    clippy
    rustfmt
  ];

  preCheck = ''
    cargo fmt --check
    cargo clippy --all-targets -- -D warnings
  '';
  cargoTestFlags = [ "--all-targets" ];

  meta = {
    description = "Join ordered TS/MP4/MKV media parts into one file";
    license = lib.licenses.mit;
    mainProgram = "join-media-parts";
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.unix;
  };
}
