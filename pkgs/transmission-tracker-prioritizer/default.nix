{
  lib,
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "transmission-tracker-prioritizer";
  runtimeInputs = [ python3 ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Continuously raise Transmission bandwidth priority for torrents on selected tracker hosts";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "transmission-tracker-prioritizer";
    platforms = lib.platforms.linux;
  };
}
