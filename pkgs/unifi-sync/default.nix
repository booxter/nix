{
  lib,
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "unifi-sync";
  runtimeInputs = [ python3 ];
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
