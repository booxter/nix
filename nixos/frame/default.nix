{
  config,
  inputs,
  lib,
  ...
}:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = "25.11";

  imports = [
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
  ];

  host = {
    disko.layout = "luks";
    desktop.hyprland.enable = true;
    nix.builder = {
      enable = true;
      speedFactor = 200;
    };
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
        collector.enable = true;
      };
    };
    luks = {
      remoteUnlock = {
        kernelModules = [ "r8169" ];
        hostKeyPath = "/etc/secrets/initrd/ssh_host_ed25519_key";
        authorizedKeys = [
          (readPublicKey ../../common/_mixins/ssh/public-keys/mair.pub)
          (readPublicKey ../../common/_mixins/ssh/public-keys/mmini.pub)
        ];
      };
    };
    network = {
      interfaces.enp191s0.kind = "ethernet";
      macAddress = "9c:bf:0d:00:fa:0a";
      primaryInterface = "enp191s0";
      reservation = {
        enable = true;
        address = "192.168.11.228";
      };
    };
    observability = {
      alertmanagerWatchdog.enable = true;
      blackbox.remote.enable = true;
    };
    ollama = {
      enable = true;
      enableMetrics = true;
      models = {
        "granite4:32b-a9b-h" = { };
        "qwen3-vl:8b-instruct".capabilities = [
          "text"
          "vision"
        ];
      };
    };
    remote-control.server = {
      vnc = {
        enable = true;
        basePort = 5933;
      };
      wayland.enable = true;
      x11.enable = true;
    };
    ssh = {
      operator.authorizedKeys = [
        (readPublicKey ../../common/_mixins/ssh/public-keys/frame.pub)
        (readPublicKey ../../common/_mixins/ssh/public-keys/yubikey.pub)
      ];
      tickets = {
        allowX11Forwarding = true;
        issuer = {
          publicKey = readPublicKey ../../common/_mixins/ssh/public-keys/yubikey.pub;
          keyName = "id_ed25519_sk_rk";
          useAgent = false;
        };
      };
    };
    security = {
      authentication.u2f = {
        enable = true;
        appId = "pam://frame";
        origin = "pam://frame";
      };
      secrets.operator.ageIdentity = {
        backend = "yubikey";
        path = "/home/${config.host.username}/.config/sops/age/yubi-nix.txt";
      };
      ssh.credentials.backend = "yubikey";
    };
    userEnvironment = {
      preset = "personal";
      roles = {
        developer.enable = true;
        workstation.enable = true;
      };
    };
    ups.server = {
      enable = true;
      description = "APC UPS 1500VA";
    };
  };

  # It caused hangs on shutdown.
  security.lsm = lib.mkForce [
    "landlock"
    "yama"
  ];
}
