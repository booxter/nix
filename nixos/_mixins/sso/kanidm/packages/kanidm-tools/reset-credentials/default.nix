{
  clippy,
  defaultTarget,
  lib,
  openssh,
  rustfmt,
  rustPlatform,
}:
assert lib.assertMsg (
  defaultTarget != ""
) "Kanidm credential reset requires an SSO provider target";
rustPlatform.buildRustPackage {
  pname = "kanidm-reset-credentials";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = ../.;
  };

  cargoHash = "sha256-+m5KPvtL9epFiLwAc7BINoHn7WzXnEe4hzar2SmNqs4=";
  cargoBuildFlags = [
    "--package"
    "kanidm-reset-credentials"
  ];

  RESET_OIDC_SSH = lib.getExe openssh;
  RESET_OIDC_DEFAULT_TARGET = defaultTarget;

  nativeCheckInputs = [
    clippy
    rustfmt
  ];

  preCheck = ''
    cargo fmt --check
    cargo clippy --package kanidm-reset-credentials --all-targets -- -D warnings
  '';
  cargoTestFlags = [
    "--package"
    "kanidm-reset-credentials"
    "--all-targets"
  ];

  meta = {
    description = "Request Kanidm credential resets through the realm provider";
    license = lib.licenses.mit;
    mainProgram = "reset-oidc";
    platforms = lib.platforms.unix;
  };
}
