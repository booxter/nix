{
  git,
  issueInternalServiceCert,
  issueObservabilityCert,
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
  pythonWithDeps = python3.withPackages (ps: [
    ps.cryptography
    ps.pyyaml
  ]);
in
writeShellApplication {
  name = "pki-rotation";
  runtimeInputs = [
    git
    issueInternalServiceCert
    issueObservabilityCert
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
    description = "Inspect and rotate repo-managed internal PKI certificates";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "pki-rotation";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
