{
  lib,
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "unifi-fixed-reservation";
  runtimeInputs = [ python3 ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Sync UniFi client reservations from inventory or set a single client through the legacy UniFi OS API";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "unifi-fixed-reservation";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
