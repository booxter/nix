{
  lib,
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "unifi-sync";
  checkPhase = ''
    runHook preCheck
    cd "$TMPDIR"
    cp ${./test_main.py} test_main.py
    UNIFI_SYNC_MAIN=${./main.py} ${python3.pkgs.pytest}/bin/pytest -q -p no:cacheprovider test_main.py
    runHook postCheck
  '';
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Sync UniFi reservations, DHCP settings, DNS records, and static routes from inventory";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "unifi-sync";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
