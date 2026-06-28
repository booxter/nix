{
  amdgpu_top,
  lib,
  python3,
  writeShellApplication,
}:

writeShellApplication {
  name = "frame-amdgpu-metrics";
  runtimeInputs = [
    amdgpu_top
    python3
  ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Collect AMD GPU metrics from amdgpu_top JSON for Prometheus node-exporter textfiles";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "frame-amdgpu-metrics";
    platforms = lib.platforms.linux;
  };
}
