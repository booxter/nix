{
  clippy,
  fleetInventory,
  lib,
  rustfmt,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "fleet-tools";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.lock
      ./Cargo.toml
      ./src
    ];
  };

  cargoHash = "sha256-weiGc2us7SiZJbS4DqYdwDfxWaT80LupNNMqaod8uac=";

  FLEET_HOSTS_JSON = builtins.toJSON fleetInventory;

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
    description = "Typed command-line tools for this Nix fleet";
    license = lib.licenses.mit;
    mainProgram = "get-hosts";
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.unix;
  };
}
