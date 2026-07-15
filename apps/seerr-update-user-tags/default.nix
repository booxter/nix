{
  lib,
  openssh,
  python3,
  writeShellApplication,
}:
let
  sourceDir = ./.;
in
writeShellApplication {
  name = "seerr-update-user-tags";
  runtimeInputs = [ openssh ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';
  derivationArgs = {
    doCheck = true;
  };
  checkPhase = ''
    runHook preCheck
    PYTHONPATH="${sourceDir}" \
      ${python3}/bin/python3 -m unittest discover -s "${sourceDir}" -p 'test_*.py'
    runHook postCheck
  '';

  meta = {
    description = "Backfill Seerr requester tags onto existing Radarr and Sonarr items";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "seerr-update-user-tags";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
