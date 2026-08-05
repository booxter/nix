{
  clippy,
  lib,
  openssh,
  rustfmt,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "kanidm-tools";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.lock
      ./Cargo.toml
      ./src
    ];
  };

  cargoHash = "sha256-thra/ca7rmCK/yGJO9umuyQk4/x8UjU+GiqRYgmVKGM=";

  RESET_OIDC_SSH = lib.getExe openssh;

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
    description = "Administrative Kanidm tools for the PKI host";
    license = lib.licenses.mit;
    mainProgram = "reset-oidc";
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.unix;
  };
}
