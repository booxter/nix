{
  lib,
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "transmission-torrent-cleaner";
  runtimeInputs = [ python3 ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Dry-run cleaner for old high-ratio non-priority Transmission torrents";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "transmission-torrent-cleaner";
    platforms = lib.platforms.linux;
  };
}
