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
  name = "issue-observability-cert";
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
    description = "Issue internal PKI certs for Prometheus mTLS endpoints and store them in host sops secrets";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "issue-observability-cert";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
