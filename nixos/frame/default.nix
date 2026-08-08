{
  inputs,
  lib,
  pkgs,
  ...
}:
let
  framePkgs = import ./pkgs pkgs;
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
in
{
  _module.args.framePkgs = framePkgs;

  imports = [
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
    ./alertmanager-watchdog.nix
    ./remote-desktop.nix
  ];

  nixpkgs.config.rocmSupport = true;

  networking.wireless.enable = false;
  networking.wireless.secretsFile = "/etc/wireless.secrets";
  networking.wireless.networks = {
    booxter = {
      pskRaw = "ext:psk_booxter";
    };
  };

  services.displayManager.gdm = {
    enable = true;
  };
  services.displayManager.defaultSession = "hyprland";
  programs.hyprland.enable = true;

  # systemd's global bpf-restrict-fs link took roughly three minutes to detach
  # during reboot while the kernel waited for a Tasks RCU grace period. No
  # service on this host uses RestrictFileSystems=, so keep the other default
  # LSMs without enabling the BPF LSM solely for that unused systemd feature.
  security.lsm = lib.mkForce [
    "landlock"
    "yama"
  ];

  security.pam.services.hyprlock = { };
  services.openssh.settings.X11Forwarding = true;

  services.ollama = {
    package = pkgs.ollama-rocm;
  };

  environment.systemPackages = with pkgs; [
    amdgpu_top
    clinfo
    radeontop
    rocmPackages.rocm-smi
    rocmPackages.rocminfo
    waypipe
  ];

  systemd.services.frame-amdgpu-metrics = {
    description = "Collect AMD GPU metrics for Prometheus";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe' framePkgs.frame-observability "frame-amdgpu-metrics"} --output ${nodeExporterTextfileDir}/frame-amdgpu.prom";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ nodeExporterTextfileDir ];
      RestrictAddressFamilies = [ "AF_UNIX" ];
      RestrictRealtime = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
    };
  };

  systemd.timers.frame-amdgpu-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "30s";
      AccuracySec = "5s";
    };
  };

  systemd.tmpfiles.rules = [ "d ${nodeExporterTextfileDir} 0755 root root - -" ];
}
