{
  lib,
  python3,
  writeShellApplication,
}:

writeShellApplication {
  name = "frame-ollama-metrics";
  runtimeInputs = [ python3 ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Collect Ollama state metrics for Prometheus node-exporter textfiles";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "frame-ollama-metrics";
    platforms = lib.platforms.linux;
  };
}
