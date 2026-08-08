{
  clippy,
  lib,
  rustfmt,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "kanidm-mail-sender-tools";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = ../.;
  };

  cargoHash = "sha256-+m5KPvtL9epFiLwAc7BINoHn7WzXnEe4hzar2SmNqs4=";
  cargoBuildFlags = [
    "--package"
    "kanidm-mail-sender-tools"
  ];

  nativeCheckInputs = [
    clippy
    rustfmt
  ];

  preCheck = ''
    cargo fmt --check
    cargo clippy --package kanidm-mail-sender-tools --all-targets -- -D warnings
  '';
  cargoTestFlags = [
    "--package"
    "kanidm-mail-sender-tools"
    "--package"
    "kanidm-tool-common"
    "--all-targets"
  ];

  meta = {
    description = "Bootstrap and configure the Kanidm mail sender";
    license = lib.licenses.mit;
    mainProgram = "kanidm-mail-sender-bootstrap";
    platforms = lib.platforms.linux;
  };
}
