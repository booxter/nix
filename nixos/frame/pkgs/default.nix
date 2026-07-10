pkgs: {
  fana-alertmanager-watchdog = pkgs.callPackage ./fana-alertmanager-watchdog { };
  frame-amdgpu-metrics = pkgs.callPackage ./frame-amdgpu-metrics { };
  frame-ollama-metrics = pkgs.callPackage ./frame-ollama-metrics { };
}
