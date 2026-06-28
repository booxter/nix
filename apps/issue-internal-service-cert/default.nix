{
  bash,
  age-plugin-se,
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
writeShellApplication {
  name = "issue-internal-service-cert";
  runtimeInputs = [
    bash
    age-plugin-se
    git
    jq
    nix
    openssh
    python3
    sops
    yq-go
  ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Issue internal PKI certs for internal HTTPS services and store them in host sops secrets";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "issue-internal-service-cert";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
