{
  context,
  lib,
}:
let
  inherit (context) frame;

  builderSpec =
    idx:
    let
      idx' = toString idx;
    in
    {
      isVM = true;
      observability.capacityProfile = "cpu-bursty";
      name = "builder${idx'}";
      realm = "home";
      userProfile = "personal";
      proxNode = "prx${idx'}-lab";
      memorySize = 64;
      balloonSize = 48;
      diskSize = 150;
      cores = 24;
      hmFull = false;
    };

  labProxmoxSpec =
    {
      index,
      proxmoxUpgradeTime,
    }:
    let
      index' = toString index;
      name = "prx${index'}-lab";
    in
    {
      hostKind = "proxmox";
      inherit
        name
        proxmoxUpgradeTime
        ;
      realm = "home";
      userProfile = "personal";
      hmFull = false;
      observability.capacityProfile = "hypervisor";
    };
in
{
  darwin = lib.mapAttrs (name: spec: spec // { inherit name; }) {
    mair = {
      realm = "home";
      userProfile = "personal";
      availability = "intermittent";
      observability.capacityProfile = "interactive";
      isOperatorSeat = true;
      isSecretsOperator = true;
    };
    mmini = {
      realm = "home";
      userProfile = "personal";
      observability.capacityProfile = "interactive";
      isOperatorSeat = true;
      isSecretsOperator = true;
    };
    JGWXHWDL4X = {
      realm = "work";
      userProfile = "nvidia";
      availability = "intermittent";
      isOperatorSeat = true;
      isSecretsOperator = true;
    };
  };

  nixos = [
    {
      hostKind = "nixos";
      name = frame;
      realm = "home";
      userProfile = "personal";
      observability.capacityProfile = "cpu-bursty";
      isDesktop = true;
      isOperatorSeat = true;
      isSecretsOperator = true;
      sshTicket.allowX11Forwarding = true;
    }
    {
      hostKind = "proxmox";
      name = "nvws";
      realm = "work";
      userProfile = "nvidia";
      hmFull = false;
    }
    {
      hostKind = "nixos";
      name = "beast";
      realm = "home";
      userProfile = "personal";
      critical = true;
      hmFull = false;
      hardware.igpu.renderDevice = "/dev/dri/renderD128";
    }
    (labProxmoxSpec {
      index = 1;
      proxmoxUpgradeTime = "Mon 03:50";
    })
    (labProxmoxSpec {
      index = 2;
      proxmoxUpgradeTime = "Mon 04:20";
    })
    (labProxmoxSpec {
      index = 3;
      proxmoxUpgradeTime = "Mon 04:50";
    })
    {
      isVM = true;
      name = "nv";
      realm = "work";
      userProfile = "nvidia";
      isOperatorSeat = true;
      cores = 64;
      memorySize = 128;
      proxNode = "nvws";
    }
    {
      isVM = true;
      name = "cache";
      realm = "home";
      userProfile = "personal";
      hmFull = false;
      cores = 16;
      memorySize = 16;
      diskSize = 50; # actual cache is on NFS
    }
    {
      isVM = true;
      name = "srvarr";
      realm = "home";
      userProfile = "personal";
      cores = 16;
      memorySize = 32;
      hmFull = false;
    }
    {
      isVM = true;
      name = "fana";
      realm = "home";
      userProfile = "personal";
      cores = 8;
      memorySize = 16;
      diskSize = 300;
      hmFull = false;
    }
    {
      isVM = true;
      name = "gw";
      realm = "home";
      userProfile = "personal";
      cores = 2;
      memorySize = 8;
      diskSize = 64;
      hmFull = false;
    }
    {
      isVM = true;
      name = "org";
      realm = "home";
      userProfile = "personal";
      cores = 4;
      memorySize = 16;
      diskSize = 80;
      hmFull = false;
    }
    {
      isVM = true;
      name = "pki";
      realm = "home";
      userProfile = "personal";
      cores = 2;
      memorySize = 4;
      diskSize = 50;
      hmFull = false;
    }
    {
      isVM = true;
      name = "home";
      realm = "home";
      userProfile = "personal";
      proxNode = "prx2-lab";
      cores = 4;
      memorySize = 8;
      diskSize = 80;
      hmFull = false;
    }
  ]
  ++ map builderSpec [
    1
    2
    3
  ];
}
