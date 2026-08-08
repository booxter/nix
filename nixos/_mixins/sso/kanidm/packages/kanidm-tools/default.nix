{
  clippy,
  defaultTarget,
  lib,
  openssh,
  rustfmt,
  rustPlatform,
}:
assert lib.assertMsg (defaultTarget != "") "Kanidm tools require an SSO provider target";
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

  cargoHash = "sha256-wqe6mr0e2tLijyBULreIZ3CiP5+GiONYuzMWVbRB0J4=";

  RESET_OIDC_SSH = lib.getExe openssh;
  RESET_OIDC_DEFAULT_TARGET = defaultTarget;

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
    description = "Administrative tools for the realm Kanidm provider";
    license = lib.licenses.mit;
    mainProgram = "reset-oidc";
    platforms = lib.platforms.unix;
  };
}
