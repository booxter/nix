{
  config,
  hostInventory,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  framePkgs = import ./pkgs pkgs;
  ollamaService = hostInventory.servicesById.ollama;
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
in
{
  _module.args.framePkgs = framePkgs;

  imports = [
    (import ../disko/luks.nix { })
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
    ./alertmanager-watchdog.nix
    ./remote-desktop.nix
    ./remote-luks.nix
    ./ups.nix
  ];

  # This host needs manual local or remote unlock after boot; never auto-reboot
  # on upgrades.
  system.autoUpgrade.allowReboot = lib.mkForce false;
  host.observability.blackbox.remote.enable = true;
  hardware = {
    drmCard = "card1";
    displayMode = {
      width = 3840;
      height = 2160;
      refreshRate = 60;
    };
    scale = 1.5;
    displays = [
      {
        position = "left";
        connector = "DP-4";
        x = 0;
        primary = true;
      }
      {
        position = "right";
        connector = "DP-2";
        x = 2560;
      }
    ];
    gpu = {
      vendors = [ "amd" ];
      compute = "rocm";
    };
  };

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
  remote-control.server = {
    wayland.enable = true;
    x11.enable = true;
  };

  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;
    host = "127.0.0.1";
    port = 11434;
    loadModels = [
      "gemma4:31b"
      "granite4:32b-a9b-h"
      "nemotron-cascade-2:30b"
      "nomic-embed-text"
      "qwen3-next:80b"
      "qwen3-vl:8b-instruct"
    ];
    syncModels = true;
    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "30m";
    };
  };

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

  systemd.services.frame-ollama-metrics = {
    description = "Collect Ollama state metrics for Prometheus";
    wants = [ "ollama.service" ];
    after = [ "ollama.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe' framePkgs.frame-observability "frame-ollama-metrics"} --base-url http://127.0.0.1:${toString config.services.ollama.port} --output ${nodeExporterTextfileDir}/frame-ollama.prom";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ nodeExporterTextfileDir ];
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
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

  systemd.timers.frame-ollama-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "1m";
      AccuracySec = "10s";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${nodeExporterTextfileDir} 0755 root root - -"
  ];

  host.internalHttps.services.ollama = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.ollama.port}";
    mtls.enable = true;
    serverAliases = [ ollamaService.displayHost ];
    localAliases = [ "ollama" ];
    locationExtraConfig = ''
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
  };
}
