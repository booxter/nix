{
  lib,
  python3,
  writeShellApplication,
}:
let
  pythonWithDeps = python3.withPackages (pythonPackages: [
    pythonPackages.python-telegram-bot
  ]);
in

writeShellApplication {
  name = "fana-alertmanager-watchdog";
  runtimeInputs = [ pythonWithDeps ];
  text = ''
    exec ${pythonWithDeps}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Watch fana Alertmanager readiness and send direct Telegram notifications";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "fana-alertmanager-watchdog";
    platforms = lib.platforms.linux;
  };
}
