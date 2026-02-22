{ pkgs }:
let
  mkApp = program: {
    type = "app";
    inherit program;
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

  # Generic bootstrap command with subcommands (host-keygen/repo-init).
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

  # Generate/read /var/lib/sops-nix/key.txt and print the age public key.
  sops-host-keygen = pkgs.writeShellApplication {
    name = "sops-host-keygen";
    runtimeInputs = with pkgs; [
      age
      gnugrep
      openssh
      ripgrep
      sops
      yq
    ];
    text = ''
      exec ${../scripts/sops-bootstrap.sh} host-keygen "$@"
    '';
  };

  # Create/update .sops.yaml and initialize encrypted secrets/HOST.yaml.
  sops-repo-init = pkgs.writeShellApplication {
    name = "sops-repo-init";
    runtimeInputs = with pkgs; [
      age
      gnugrep
      openssh
      ripgrep
      sops
      yq
    ];
    text = ''
      exec ${../scripts/sops-bootstrap.sh} repo-init "$@"
    '';
  };

  # Bootstrap a remote host over SSH and initialize its encrypted secret file.
  sops-bootstrap-remote = pkgs.writeShellApplication {
    name = "sops-bootstrap-remote";
    runtimeInputs = with pkgs; [
      age
      gnugrep
      openssh
      ripgrep
      sops
      yq
    ];
    text = ''
      exec ${../scripts/sops-bootstrap-remote.sh} "$@"
    '';
  };
in
{
  default = mkApp "${sops-bootstrap}/bin/sops-bootstrap";
  "sops-bootstrap" = mkApp "${sops-bootstrap}/bin/sops-bootstrap";
  "sops-bootstrap-remote" = mkApp "${sops-bootstrap-remote}/bin/sops-bootstrap-remote";
  "sops-host-keygen" = mkApp "${sops-host-keygen}/bin/sops-host-keygen";
  "sops-repo-init" = mkApp "${sops-repo-init}/bin/sops-repo-init";
  "sops-cat" = mkApp "${sops-cat}/bin/sops-cat";
  "sops-edit" = mkApp "${sops-edit}/bin/sops-edit";
  "sops-update" = mkApp "${sops-update}/bin/sops-update";
}
