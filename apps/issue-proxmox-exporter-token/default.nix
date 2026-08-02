{
  age-plugin-se,
  git,
  lib,
  nix,
  openssh,
  python3,
  sops,
  writeShellApplication,
}:
writeShellApplication {
  name = "issue-proxmox-exporter-token";
  runtimeInputs = [
    age-plugin-se
    git
    nix
    openssh
    sops
  ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Issue the Proxmox VE prometheus-pve-exporter API token and store it in host sops secrets";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "issue-proxmox-exporter-token";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
