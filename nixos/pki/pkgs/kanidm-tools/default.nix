{
  clippy,
  kanidmWithSecretProvisioning_1_10,
  lib,
  openssh,
  rustfmt,
  rustPlatform,
}:
let
  kanidmClientVersion = "1.10.4";
in
assert lib.getVersion kanidmWithSecretProvisioning_1_10 == kanidmClientVersion;
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

  cargoHash = "sha256-M4erT2YxjeZG2bxx1qafiUMVr8fUrJaPnQZzP17dt9g=";

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

  passthru = { inherit kanidmClientVersion; };

  meta = {
    description = "Administrative Kanidm tools for the PKI host";
    license = lib.licenses.mit;
    mainProgram = "reset-oidc";
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.unix;
  };
}
