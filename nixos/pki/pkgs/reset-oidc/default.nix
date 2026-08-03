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
  pname = "reset-oidc";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.lock
      ./Cargo.toml
      ./src
    ];
  };

  cargoHash = "sha256-7xPnismw8AvcRPAXA9tVzMJZ9T2GOC8w3LbwqchvjZY=";

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
    description = "Send Kanidm credential reset email requests through the PKI host";
    license = lib.licenses.mit;
    mainProgram = "reset-oidc";
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.unix;
  };
}
