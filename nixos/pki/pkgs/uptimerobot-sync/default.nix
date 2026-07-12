{
  lib,
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "uptimerobot-sync";
  runtimeInputs = [ python3 ];
  checkPhase = ''
    runHook preCheck
    cd "$TMPDIR"
    cp ${./test_main.py} test_main.py
    UPTIMEROBOT_SYNC_MAIN=${./main.py} ${python3.pkgs.pytest}/bin/pytest -q -p no:cacheprovider test_main.py
    runHook postCheck
  '';
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Sync UptimeRobot monitors from Nix service inventory";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "uptimerobot-sync";
    platforms = lib.platforms.linux;
  };
}
