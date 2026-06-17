{
  lib,
  python3,
  writeShellApplication,
}:

writeShellApplication {
  name = "wg-home-dns-sync";
  runtimeInputs = [ python3 ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Sync home WireGuard peer DNS overrides through unifi-sync";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "wg-home-dns-sync";
  };
}
