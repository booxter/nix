{
  lib,
  nix,
  openssh,
  python3,
  symlinkJoin,
  writeShellApplication,
  repoRoot ? ../..,
}:
let
  python = python3;
  commonRuntimeInputs = [
    nix
    openssh
    python
  ];
  commonEnv = ''
    export SSHT_REPO_ROOT="${repoRoot}"
  '';
  sshTicket = writeShellApplication {
    name = "ssh-ticket";
    runtimeInputs = commonRuntimeInputs;
    text = ''
      ${commonEnv}
      exec ${python}/bin/python3 ${./main.py} "$@"
    '';
  };
  ssht = writeShellApplication {
    name = "ssht";
    runtimeInputs = commonRuntimeInputs;
    text = ''
      ${commonEnv}
      exec ${python}/bin/python3 ${./main.py} ssht "$@"
    '';
  };
in
symlinkJoin {
  name = "ssh-ticket";
  paths = [
    sshTicket
    ssht
  ];

  meta = {
    description = "Issue per-host short-lived SSH user certificates and connect through ssht";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "ssh-ticket";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
