{
  clippy,
  fleetInventory,
  lib,
  openssh,
  rustfmt,
  rustPlatform,
  wireguardHome,
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

  cargoHash = "sha256-NjXKYufPOV4MfmZIm5IKvQ2FU8hElsUhLu7iDL6hiS4=";

  FLEET_HOSTS_JSON = builtins.toJSON fleetInventory;
  WG_HOME_CONFIG_JSON = builtins.toJSON wireguardHome;
  WG_HOME_HELP = ''
    Examples:
      wg-home-client-config --peer mair --private-key-file ./client.key --fetch-server-public-key --output ./client.conf
      wg-home-client-config --address 10.83.0.50/32 --private-key-file ./client.key --server-public-key KEY

    Inventory-backed peers: ${lib.concatStringsSep ", " (builtins.attrNames wireguardHome.peers)}
  '';
  WG_HOME_SSH = lib.getExe openssh;

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
