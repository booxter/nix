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
  name = "seerr-request-storage";
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
    description = "Report storage consumed by Radarr and Sonarr files attributable to Seerr requests";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "seerr-request-storage";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
