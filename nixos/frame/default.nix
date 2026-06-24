{
  config,
  hostInventory,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  ollamaService = hostInventory.servicesById.ollama;
in
{
  imports = [
    (import ../disko/luks.nix { })
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
    ./ups.nix
  ];

  # This host needs manual unlock after boot; never auto-reboot on upgrades.
  system.autoUpgrade.allowReboot = lib.mkForce false;
  host.observability.client.blackbox.enable = true;
  host.observability.client.blackbox.mtls.enable = true;

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
  programs.hyprland.enable = true;

  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;
    host = "127.0.0.1";
    port = 11434;
    loadModels = [
      "nomic-embed-text"
      "qwen3.5:9b"
      "qwen3-vl:8b-instruct"
    ];
    syncModels = false;
    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "30m";
    };
  };

  environment.systemPackages = with pkgs; [
    clinfo
    radeontop
    rocmPackages.rocminfo
  ];

  host.internalHttps.services.ollama = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.ollama.port}";
    mtls.enable = true;
    serverAliases = [ ollamaService.displayHost ];
    localAliases = [ "ollama" ];
  };
}
