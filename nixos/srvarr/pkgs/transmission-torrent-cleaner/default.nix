{
  lib,
  python3,
  transmissionCommon,
  writeShellApplication,
}:
let
  sourceDir = ./.;
  pythonWithDeps = python3.withPackages (_: [
    transmissionCommon
  ]);
in
writeShellApplication {
  name = "transmission-torrent-cleaner";
  runtimeInputs = [ pythonWithDeps ];
  text = ''
    exec ${pythonWithDeps}/bin/python3 ${./main.py} "$@"
  '';
  derivationArgs = {
    doCheck = true;
  };
  checkPhase = ''
    runHook preCheck
    PYTHONPATH="${sourceDir}" \
      ${pythonWithDeps}/bin/python3 -m unittest discover -s "${sourceDir}" -p 'test_*.py'
    runHook postCheck
  '';

  meta = {
    description = "Cleanup utility for old high-ratio or stale non-seeding non-priority Transmission torrents";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "transmission-torrent-cleaner";
    platforms = lib.platforms.linux;
  };
}
