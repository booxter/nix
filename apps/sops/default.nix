{ pkgs }:
let
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };
  upsClientsByServer = import ../../lib/ups-clients.nix { lib = pkgs.lib; };
  upsClientsByServerFile = pkgs.writeText "ups-clients-by-server.json" (
    builtins.toJSON upsClientsByServer
  );
  commonRuntimeInputs = with pkgs; [
    age-plugin-se
    age-plugin-yubikey
    coreutils
    git
    sops
  ];
  jqRuntimeInputs = commonRuntimeInputs ++ [ pkgs.jq ];
  yqRuntimeInputs = jqRuntimeInputs ++ [ pkgs.yq-go ];

  # Decrypt and print a host secret (defaults to current short hostname).
  sops-cat = pkgs.writeShellApplication {
    name = "sops-cat";
    runtimeInputs = commonRuntimeInputs;
    text = ''
      exec ${./sops-cat.sh} "$@"
    '';
  };

  # Open a host secret in sops editor.
  sops-edit = pkgs.writeShellApplication {
    name = "sops-edit";
    runtimeInputs = commonRuntimeInputs;
    text = ''
      exec ${./sops-edit.sh} "$@"
    '';
  };

  # Update a host secret with missing keys from secrets/_template.yaml.
  sops-update = pkgs.writeShellApplication {
    name = "sops-update";
    runtimeInputs = yqRuntimeInputs;
    text = ''
      exec ${./sops-update.sh} "$@"
    '';
  };

  # Copy a key path from one host secret into another host secret.
  sops-copy = pkgs.writeShellApplication {
    name = "sops-copy";
    runtimeInputs = yqRuntimeInputs;
    text = ''
      exec ${./sops-copy.sh} "$@"
    '';
  };

  # Set a single key path in one host secret from stdin.
  sops-set = pkgs.writeShellApplication {
    name = "sops-set";
    runtimeInputs = jqRuntimeInputs;
    text = ''
      exec ${./sops-set.sh} "$@"
    '';
  };

  # Sync NUT secondary-user passwords from UPS servers into client secrets.
  sops-ups-sync = pkgs.writeShellApplication {
    name = "sops-ups-sync";
    runtimeInputs = yqRuntimeInputs;
    text = ''
      export UPS_CLIENTS_BY_SERVER_FILE=${upsClientsByServerFile}
      exec ${pkgs.bash}/bin/bash ${./sops-ups-sync.sh} "$@"
    '';
  };

  # Hash and store a NixOS login password in a host secret.
  sops-pass = pkgs.writeShellApplication {
    name = "sops-pass";
    runtimeInputs =
      jqRuntimeInputs
      ++ (with pkgs; [
        mkpasswd
        pass
      ]);
    text = ''
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
      exec ${./sops-bootstrap.sh} "$@"
    '';
  };
in
{
  "sops-bootstrap" =
    mkApp "${sops-bootstrap}/bin/sops-bootstrap" "Bootstrap host sops secrets and key recipients.";
  "sops-cat" = mkApp "${sops-cat}/bin/sops-cat" "Decrypt and print a host secret.";
  "sops-edit" = mkApp "${sops-edit}/bin/sops-edit" "Edit a host secret.";
  "sops-update" =
    mkApp "${sops-update}/bin/sops-update" "Merge missing template keys into a host secret.";
  "sops-copy" = mkApp "${sops-copy}/bin/sops-copy" "Copy a top-level key path between host secrets.";
  "sops-set" = mkApp "${sops-set}/bin/sops-set" "Set a single host secret key path from stdin.";
  "sops-ups-sync" =
    mkApp "${sops-ups-sync}/bin/sops-ups-sync" "Sync NUT UPS server passwords into client secrets.";
  "sops-pass" = mkApp "${sops-pass}/bin/sops-pass" "Hash and store a NixOS login password.";
}
