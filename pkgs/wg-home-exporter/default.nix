{
  lib,
  python3,
  wireguard-tools,
  writeShellApplication,
}:

writeShellApplication {
  name = "wg-home-exporter";
  runtimeInputs = [
    python3
    wireguard-tools
  ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Expose home WireGuard peer connection state as JSON and Prometheus metrics";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "wg-home-exporter";
  };
}
