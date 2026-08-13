{
  context,
  lib,
}:
let
  inherit (context) frame;

  builderSpecs =
    lib.genAttrs
      (map (idx: "builder${toString idx}") [
        1
        2
        3
      ])
      (_: {
        isVM = true;
        realm = "home";
        proxmox.cluster = "default";
        memorySize = 64;
        balloonSize = 48;
        diskSize = 150;
        cores = 24;
      });

  labProxmoxSpecs =
    lib.genAttrs
      (map (index: "prx${toString index}-lab") [
        1
        2
        3
      ])
      (_: {
        hostKind = "proxmox";
        realm = "home";
        proxmox.cluster = "default";
      });
in
{
  darwin = {
    mair = {
      realm = "home";
      availability = "intermittent";
      isOperatorSeat = true;
    };
    mmini = {
      realm = "home";
      isOperatorSeat = true;
    };
    JGWXHWDL4X = {
      realm = "work";
      availability = "intermittent";
      isOperatorSeat = true;
    };
  };

  nixos = {
    ${frame} = {
      hostKind = "nixos";
      realm = "home";
      isDesktop = true;
      isOperatorSeat = true;
    };
    nvws = {
      hostKind = "proxmox";
      realm = "work";
      proxmox.cluster = "default";
    };
    beast = {
      hostKind = "nixos";
      realm = "home";
    };
    nv = {
      isVM = true;
      realm = "work";
      proxmox.cluster = "default";
      isOperatorSeat = true;
      cores = 64;
      memorySize = 128;
    };
    cache = {
      isVM = true;
      realm = "home";
      proxmox.cluster = "default";
      cores = 16;
      memorySize = 16;
      diskSize = 50; # actual cache is on NFS
    };
    srvarr = {
      isVM = true;
      realm = "home";
      proxmox.cluster = "default";
      cores = 16;
      memorySize = 32;
    };
    fana = {
      isVM = true;
      realm = "home";
      proxmox.cluster = "default";
      cores = 8;
      memorySize = 16;
      diskSize = 300;
    };
    gw = {
      isVM = true;
      realm = "home";
      proxmox.cluster = "default";
      cores = 2;
      memorySize = 8;
      diskSize = 64;
    };
    org = {
      isVM = true;
      realm = "home";
      proxmox.cluster = "default";
      cores = 4;
      memorySize = 16;
      diskSize = 80;
    };
    pki = {
      isVM = true;
      realm = "home";
      proxmox.cluster = "default";
      cores = 2;
      memorySize = 4;
      diskSize = 50;
    };
    home = {
      isVM = true;
      realm = "home";
      proxmox.cluster = "default";
      cores = 4;
      memorySize = 8;
      diskSize = 80;
    };
  }
  // labProxmoxSpecs
  // builderSpecs;
}
