{
  clippy,
  diffutils,
  dix,
  fleetInventory,
  lib,
  nh,
  nix,
  openssh,
  rustfmt,
  rustPlatform,
  vmTargets,
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

  cargoHash = "sha256-jX9+4U/yP+jV5o5+YyeY5tk8CeBI7M1Fcfqw5Q0dFLo=";

  DIFF_DIX = lib.getExe dix;
  DIFF_GNU_DIFF = lib.getExe' diffutils "diff";
  DIFF_NH = lib.getExe nh;
  DIFF_NIX = lib.getExe nix;
  DIFF_TARGET_ALIASES_JSON = builtins.toJSON vmTargets;
  FLEET_HOSTS_JSON = builtins.toJSON fleetInventory;
  WG_HOME_CONFIG_JSON = builtins.toJSON wireguardHome;
  WG_HOME_HELP = ''
    Examples:
      wg-home-client-config --peer mair --private-key-file ./client.key --fetch-server-public-key --output ./client.conf
      wg-home-client-config --address 10.83.0.50/32 --private-key-file ./client.key --server-public-key KEY

    Inventory-backed peers: ${lib.concatStringsSep ", " (builtins.attrNames wireguardHome.peers)}
  '';
  WG_HOME_SSH = lib.getExe openssh;
  VM_NIX = lib.getExe nix;
  VM_REPO_ROOT = ../..;
  VM_RUNNER_NIX = ./vm-runner.nix;
  VM_TARGETS_JSON = builtins.toJSON vmTargets;
  VM_HELP = ''
    Examples:
      vm builder1
      vm --gui frame

    Available target hosts:
    ${lib.concatMapStringsSep "\n" (name: "  ${name}") (builtins.attrNames vmTargets)}
  '';

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
