{
  lib,
  nix,
  openssh,
  python3,
  stdenv,
  symlinkJoin,
  writeShellApplication,
}:
let
  python = python3;
  commonRuntimeInputs = [
    nix
    openssh
    python
  ];
  commonEnv = lib.optionalString stdenv.hostPlatform.isDarwin ''
    export SSH_AUTH_SOCK="''${SSHT_SECRETIVE_SOCKET:-$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh}"
  '';
  sshTicket = writeShellApplication {
    name = "ssh-ticket";
    runtimeInputs = commonRuntimeInputs;
    checkPhase = ''
      runHook preCheck
      SSH_TICKET_MAIN=${./main.py} ${python.pkgs.pytest}/bin/pytest -q -p no:cacheprovider ${./test_main.py}
      runHook postCheck
    '';
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
