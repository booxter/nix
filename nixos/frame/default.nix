{
  config,
  fleetInventory,
  inputs,
  lib,
  sshKeys,
  ...
}:
{
  system.stateVersion = "25.11";

  home-manager.users.${config.host.username}.host.hm.pass.yubikey = "main";

  imports = [
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
  ];

  host = {
    ci.runners = 4;
    disko = {
      layout = "luks";
      remoteUnlock = {
        kernelModules = [ "r8169" ];
        hostKeyPath = "/etc/secrets/initrd/ssh_host_ed25519_key";
        authorizedKeys = [
          sshKeys.keys.mairSecretive
          sshKeys.keys.yubikey
        ];
      };
    };
    desktop = { };
    nix.builderClient = { };
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
        vendor = "amd";
        compute = "rocm";
        collector.enable = true;
      };
    };
    network.interfaces.enp191s0 = { };
    observability = {
      alertmanagerWatchdog.enable = true;
    };
    ollama = {
      contextLength = 65536;
      models = {
        "gemma3:27b" = { };
        "gpt-oss:20b" = { };
        "granite4:32b-a9b-h" = { };
        "qwen3.8:27b-mtp-q4_K_M" = { };
        "qwen3-vl:8b-instruct".capabilities = [
          "text"
          "vision"
        ];
      };
    };
    remote-control.server = {
      vnc = {
        basePort = 5933;
      };
      wayland = { };
      x11 = { };
    };
    ssh = {
      credentials.backend = "yubikey";
      operator.authorizedKeys = sshKeys.operators.frame;
      tickets = {
        allowX11Forwarding = true;
        issuer = {
          publicKey = sshKeys.ticketIssuers.frame;
          keyName = "id_ed25519_sk_rk";
          useAgent = false;
        };
      };
    };
    security = {
      secrets.operator.ageIdentity = {
        backend = "yubikey";
        path = "${fleetInventory.yubikeys.home.main.ageIdentity}";
      };
    };
    ups.server = {
      description = "APC UPS 1500VA";
    };
  };

  # It caused hangs on shutdown.
  security.lsm = lib.mkForce [
    "landlock"
    "yama"
  ];

  security.pam.u2f = {
    enable = true;
    control = "sufficient";
    settings = {
      appid = "pam://frame";
      origin = "pam://frame";
      cue = true;
    };
  };
}
