{ hostInventory, pkgs }:
let
  upsClientsByServer = import ../../lib/ups-clients.nix { lib = pkgs.lib; };
  upsClientsByServerFile = pkgs.writeText "ups-clients-by-server.json" (
    builtins.toJSON upsClientsByServer
  );
  secretDomainsByHostFile = pkgs.writeText "secret-domains-by-host.json" (
    builtins.toJSON hostInventory.secretDomainsByHost
  );
  domainEnvironment = ''
    export SOPS_SECRET_DOMAINS_FILE=${secretDomainsByHostFile}
  '';
  commonRuntimeInputs = with pkgs; [
    age-plugin-se
    age-plugin-yubikey
    coreutils
    git
    jq
    sops
  ];
  yqRuntimeInputs = commonRuntimeInputs ++ [ pkgs.yq-go ];
  testSource = pkgs.lib.fileset.toSource {
    root = ../..;
    fileset = pkgs.lib.fileset.unions [
      ./.
      ../_helpers/host-aliases.sh
      ../_helpers/secret-domains.sh
    ];
  };

  # Decrypt and print a host secret (defaults to current short hostname).
  sops-cat = pkgs.writeShellApplication {
    name = "sops-cat";
    runtimeInputs = commonRuntimeInputs;
    text = ''
      ${domainEnvironment}
      exec ${./sops-cat.sh} "$@"
    '';
  };

  # Open a host secret in sops editor.
  sops-edit = pkgs.writeShellApplication {
    name = "sops-edit";
    runtimeInputs = commonRuntimeInputs;
    text = ''
      ${domainEnvironment}
      exec ${./sops-edit.sh} "$@"
    '';
  };

  # Update a host secret with missing keys from its domain templates.
  sops-update = pkgs.writeShellApplication {
    name = "sops-update";
    runtimeInputs = yqRuntimeInputs;
    text = ''
      ${domainEnvironment}
      exec ${./sops-update.sh} "$@"
    '';
  };

  # Copy a key path from one host secret into another host secret.
  sops-copy = pkgs.writeShellApplication {
    name = "sops-copy";
    runtimeInputs = yqRuntimeInputs;
    text = ''
      ${domainEnvironment}
      exec ${./sops-copy.sh} "$@"
    '';
  };

  # Set a single key path in one host secret from stdin.
  sops-set = pkgs.writeShellApplication {
    name = "sops-set";
    runtimeInputs = commonRuntimeInputs;
    text = ''
      ${domainEnvironment}
      exec ${./sops-set.sh} "$@"
    '';
  };

  # Sync NUT secondary-user passwords from UPS servers into client secrets.
  sops-ups-sync = pkgs.writeShellApplication {
    name = "sops-ups-sync";
    runtimeInputs = yqRuntimeInputs;
    text = ''
      ${domainEnvironment}
      export UPS_CLIENTS_BY_SERVER_FILE=${upsClientsByServerFile}
      exec ${pkgs.bash}/bin/bash ${./sops-ups-sync.sh} "$@"
    '';
  };

  # Hash and store a NixOS login password in a host secret.
  sops-pass = pkgs.writeShellApplication {
    name = "sops-pass";
    runtimeInputs =
      commonRuntimeInputs
      ++ (with pkgs; [
        mkpasswd
        pass
      ]);
    text = ''
      ${domainEnvironment}
      exec ${pkgs.bash}/bin/bash ${./sops-pass.sh} "$@"
    '';
  };

  # Bootstrap a remote host over SSH and initialize its encrypted secret file.
  sops-bootstrap = pkgs.writeShellApplication {
    name = "sops-bootstrap";
    runtimeInputs =
      yqRuntimeInputs
      ++ (with pkgs; [
        age
        gnugrep
        openssh
        ripgrep
      ]);
    text = ''
      ${domainEnvironment}
      export SOPS_AGE_RECIPIENT_HELPER=${./age-recipient.sh}
      exec ${./sops-bootstrap.sh} "$@"
    '';
  };
  commandPackages = [
    sops-bootstrap
    sops-cat
    sops-copy
    sops-edit
    sops-pass
    sops-set
    sops-update
    sops-ups-sync
  ];
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "sops-tools";
  version = "1";
  src = testSource;

  doCheck = true;
  nativeCheckInputs = with pkgs; [
    age
    git
    jq
    mkpasswd
    sops
    yq-go
  ];

  checkPhase = ''
    runHook preCheck
    ${pkgs.lib.getExe pkgs.bash} -n apps/sops/*.sh apps/sops/tests/*.sh
    ${pkgs.lib.getExe pkgs.shellcheck} apps/sops/*.sh apps/sops/tests/*.sh
    ${pkgs.lib.getExe pkgs.bash} apps/sops/tests/check-sops-helpers.sh
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    ${pkgs.lib.concatMapStringsSep "\n" (package: ''
      ln -s ${package}/bin/* "$out/bin/"
    '') commandPackages}
    runHook postInstall
  '';
}
