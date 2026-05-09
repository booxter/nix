{
  iproute2,
  lib,
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "nightly-speedtest-probe";
  runtimeInputs = [
    iproute2
    python3
  ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Nightly speedtest runner with Transmission/SABnzbd quiescing and Prometheus export";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "nightly-speedtest-probe";
    platforms = lib.platforms.linux;
  };
}
