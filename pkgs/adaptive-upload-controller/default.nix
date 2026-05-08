{
  iproute2,
  lib,
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "adaptive-upload-controller";
  runtimeInputs = [
    iproute2
    python3
  ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Adaptive upload policy controller for Jellyfin-aware torrent shaping";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "adaptive-upload-controller";
    platforms = lib.platforms.unix;
  };
}
