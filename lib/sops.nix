{ pkgs }:
let
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };

  # Decrypt and print a host secret (defaults to current short hostname).
  sops-cat = pkgs.writeShellApplication {
    name = "sops-cat";
    runtimeInputs = with pkgs; [
      coreutils
      git
      sops
    ];
    text = ''
      exec ${../scripts/sops-cat.sh} "$@"
    '';
  };

  # Merge default template keys into a host secret, then open it in sops editor.
  sops-edit = pkgs.writeShellApplication {
    name = "sops-edit";
    runtimeInputs = with pkgs; [
      coreutils
      git
      sops
      yq
    ];
    text = ''
      exec ${../scripts/sops-edit.sh} "$@"
    '';
  };

  # Update a host secret with missing keys from secrets/_template.yaml.
  sops-update = pkgs.writeShellApplication {
    name = "sops-update";
    runtimeInputs = with pkgs; [
      coreutils
      git
      sops
      yq
    ];
    text = ''
      exec ${../scripts/sops-update.sh} "$@"
    '';
  };

  # Copy a key path from one host secret into another host secret.
  sops-copy = pkgs.writeShellApplication {
    name = "sops-copy";
    runtimeInputs = with pkgs; [
      coreutils
      git
      sops
      yq
    ];
    text = ''
      exec ${../scripts/sops-copy.sh} "$@"
    '';
  };

  # Bootstrap a remote host over SSH and initialize its encrypted secret file.
  sops-bootstrap = pkgs.writeShellApplication {
    name = "sops-bootstrap";
    runtimeInputs = with pkgs; [
      age
      gnugrep
      openssh
      ripgrep
      sops
      yq
    ];
    text = ''
      exec ${../scripts/sops-bootstrap.sh} "$@"
    '';
  };
in
{
  "sops-bootstrap" =
    mkApp "${sops-bootstrap}/bin/sops-bootstrap" "Bootstrap host sops secrets and key recipients.";
  "sops-cat" = mkApp "${sops-cat}/bin/sops-cat" "Decrypt and print a host secret.";
  "sops-edit" = mkApp "${sops-edit}/bin/sops-edit" "Edit a host secret and merge template keys.";
  "sops-update" =
    mkApp "${sops-update}/bin/sops-update" "Merge missing template keys into a host secret.";
  "sops-copy" = mkApp "${sops-copy}/bin/sops-copy" "Copy a top-level key path between host secrets.";
}
