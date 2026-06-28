{
  iproute2,
  lib,
  python3,
  transmissionCommon,
  writeShellApplication,
}:
let
  pythonWithDeps = python3.withPackages (_: [
    transmissionCommon
  ]);
in
writeShellApplication {
  name = "adaptive-upload-controller";
  runtimeInputs = [
    iproute2
    pythonWithDeps
  ];
  text = ''
    exec ${pythonWithDeps}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Adaptive upload policy controller for Jellyfin-aware torrent shaping";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "adaptive-upload-controller";
    platforms = lib.platforms.unix;
  };
}
