{
  clippy,
  lib,
  rustfmt,
  rustPlatform,
  zenity,
}:

rustPlatform.buildRustPackage {
  pname = "ssh-askpass-linux";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.lock
      ./Cargo.toml
      ./src
    ];
  };

  cargoHash = "sha256-IAk7H2QUtjly81FkbZo6p84WtZsX/haa4XXiRUUvfEg=";

  ZENITY = lib.getExe zenity;

  nativeCheckInputs = [
    clippy
    rustfmt
  ];

  preCheck = ''
    cargo fmt --check
    cargo clippy --all-targets -- -D warnings
  '';

  meta = {
    description = "Native Linux OpenSSH askpass frontend";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "ssh-askpass-linux";
    platforms = lib.platforms.linux;
  };
}
