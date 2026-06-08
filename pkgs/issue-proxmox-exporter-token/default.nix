{
  bash,
  git,
  jq,
  lib,
  nix,
  openssh,
  python3,
  sops,
  writeShellApplication,
  yq-go,
}:
let
  pythonWithDeps = python3.withPackages (ps: [ ps.pyyaml ]);
in
writeShellApplication {
  name = "issue-proxmox-exporter-token";
  runtimeInputs = [
    bash
    git
    jq
    nix
    openssh
    pythonWithDeps
    sops
    yq-go
  ];
  text = ''
    exec ${pythonWithDeps}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Issue the Proxmox VE prometheus-pve-exporter API token and store it in host sops secrets";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "issue-proxmox-exporter-token";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
