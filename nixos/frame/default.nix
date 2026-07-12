{
  config,
  hostInventory,
  inputs,
  lib,
  pkgs,
  username,
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
    ./remote-luks.nix
    ./ups.nix
  ];

  # This host needs manual local or remote unlock after boot; never auto-reboot
  # on upgrades.
  system.autoUpgrade.allowReboot = lib.mkForce false;
  host.observability.client.blackbox.enable = true;
  host.observability.client.blackbox.mtls.enable = true;
  home-manager.users.${username}.programs.sshTicket.enableKnownHosts = true;

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
  security.pam.services.hyprlock = { };
  services.openssh.settings.X11Forwarding = true;

  programs.yubi = {
    age.enable = true;
    ssh.enable = true;
    pamU2f.enable = true;
  };

  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;
    host = "127.0.0.1";
    port = 11434;
    loadModels = [
      "nomic-embed-text"
      "qwen3.5:9b"
      "qwen3-next:80b"
      "qwen3-vl:8b-instruct"
    ];
    syncModels = false;
    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "30m";
    };
  };

  environment.systemPackages = with pkgs; [
    amdgpu_top
    clinfo
    radeontop
    rocmPackages.rocm-smi
    rocmPackages.rocminfo
  ];

  systemd.services.frame-amdgpu-metrics = {
    description = "Collect AMD GPU metrics for Prometheus";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe framePkgs.frame-amdgpu-metrics} --output ${nodeExporterTextfileDir}/frame-amdgpu.prom";
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
      ExecStart = "${lib.getExe framePkgs.frame-ollama-metrics} --base-url http://127.0.0.1:${toString config.services.ollama.port} --output ${nodeExporterTextfileDir}/frame-ollama.prom";
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
  };
}
