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
      name = "builder${idx'}";
      realm = "home";
      userProfile = "personal";
      memorySize = 64;
      balloonSize = 48;
      diskSize = 150;
      cores = 24;
      hmFull = false;
    };

  labProxmoxSpec =
    { index }:
    let
      index' = toString index;
      name = "prx${index'}-lab";
    in
    {
      hostKind = "proxmox";
      inherit name;
      realm = "home";
      userProfile = "personal";
      hmFull = false;
    };
in
{
  darwin = lib.mapAttrs (name: spec: spec // { inherit name; }) {
    mair = {
      realm = "home";
      userProfile = "personal";
      availability = "intermittent";
      isOperatorSeat = true;
    };
    mmini = {
      realm = "home";
      userProfile = "personal";
      isOperatorSeat = true;
    };
    JGWXHWDL4X = {
      realm = "work";
      userProfile = "nvidia";
      availability = "intermittent";
      isOperatorSeat = true;
    };
  };

  nixos = [
    {
      hostKind = "nixos";
      name = frame;
      realm = "home";
      userProfile = "personal";
      isDesktop = true;
      isOperatorSeat = true;
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
      hmFull = false;
    }
    (labProxmoxSpec { index = 1; })
    (labProxmoxSpec { index = 2; })
    (labProxmoxSpec { index = 3; })
    {
      isVM = true;
      name = "nv";
      realm = "work";
      userProfile = "nvidia";
      isOperatorSeat = true;
      cores = 64;
      memorySize = 128;
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
