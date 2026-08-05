{
  bind,
  clippy,
  curl,
  diffutils,
  dix,
  fleetInventory,
  fzf,
  lib,
  makeWrapper,
  nh,
  nix,
  nix-output-monitor,
  openssh,
  pkg-config,
  rustfmt,
  rustPlatform,
  stdenv,
  vmTargets,
  wireguardHome,
  zlib,
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

  cargoHash = "sha256-Vdr61US/XgBBhcwOT9yxxn8NgJU/Dn50Fq8lz3GVClw=";

  DIFF_DIX = lib.getExe dix;
  DIFF_GNU_DIFF = lib.getExe' diffutils "diff";
  DIFF_NH = lib.getExe nh;
  DIFF_NIX = lib.getExe nix;
  DIFF_TARGET_ALIASES_JSON = builtins.toJSON vmTargets;
  DEPLOY_NH = lib.getExe nh;
  DEPLOY_DIG = lib.getExe' bind "dig";
  DEPLOY_FZF = lib.getExe fzf;
  DEPLOY_NIX = lib.getExe nix;
  DEPLOY_NIX_COLLECT_GARBAGE = lib.getExe' nix "nix-collect-garbage";
  DEPLOY_NIX_STORE = lib.getExe' nix "nix-store";
  DEPLOY_REPO_URL = "https://github.com/booxter/nix.git";
  DEPLOY_SSH = lib.getExe openssh;
  FLEET_HOSTS_JSON = builtins.toJSON fleetInventory;
  WG_HOME_CONFIG_JSON = builtins.toJSON wireguardHome;
  WG_HOME_HELP = ''
    Examples:
      wg-home-client-config --peer mair --private-key-file ./client.key --fetch-server-public-key --output ./client.conf
      wg-home-client-config --address 10.83.0.50/32 --private-key-file ./client.key --server-public-key KEY

    Inventory-backed peers: ${lib.concatStringsSep ", " (builtins.attrNames wireguardHome.peers)}
  '';
  WG_HOME_SSH = lib.getExe openssh;
  CHECK_NIX = lib.getExe nix;
  CHECK_NOM = lib.getExe nix-output-monitor;
  CHECK_SYSTEM = stdenv.hostPlatform.system;
  VM_NIX = lib.getExe nix;
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

  nativeBuildInputs = [
    makeWrapper
    pkg-config
  ];

  buildInputs = [
    curl
    zlib
  ];

  postFixup = ''
    wrapProgram "$out/bin/fleet-deploy-remote" \
      --prefix PATH : ${
        lib.makeBinPath [
          nix
          nix-output-monitor
        ]
      }
    wrapProgram "$out/bin/deploy" \
      --prefix PATH : ${lib.makeBinPath [ openssh ]}
  '';

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
