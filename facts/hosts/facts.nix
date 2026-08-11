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
      hmFull = false;
    };
in
{
  darwin = lib.mapAttrs (name: spec: spec // { inherit name; }) {
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

  nixos = [
    {
      hostKind = "nixos";
      name = frame;
      realm = "home";
      isDesktop = true;
      isOperatorSeat = true;
      sshTicket.allowX11Forwarding = true;
    }
    {
      hostKind = "proxmox";
      name = "nvws";
      realm = "work";
      hmFull = false;
    }
    {
      hostKind = "nixos";
      name = "beast";
      realm = "home";
      hmFull = false;
    }
    (labProxmoxSpec { index = 1; })
    (labProxmoxSpec { index = 2; })
    (labProxmoxSpec { index = 3; })
    {
      isVM = true;
      name = "nv";
      realm = "work";
      isOperatorSeat = true;
      cores = 64;
      memorySize = 128;
    }
    {
      isVM = true;
      name = "cache";
      realm = "home";
      hmFull = false;
      cores = 16;
      memorySize = 16;
      diskSize = 50; # actual cache is on NFS
    }
    {
      isVM = true;
      name = "srvarr";
      realm = "home";
      cores = 16;
      memorySize = 32;
      hmFull = false;
    }
    {
      isVM = true;
      name = "fana";
      realm = "home";
      cores = 8;
      memorySize = 16;
      diskSize = 300;
      hmFull = false;
    }
    {
      isVM = true;
      name = "gw";
      realm = "home";
      cores = 2;
      memorySize = 8;
      diskSize = 64;
      hmFull = false;
    }
    {
      isVM = true;
      name = "org";
      realm = "home";
      cores = 4;
      memorySize = 16;
      diskSize = 80;
      hmFull = false;
    }
    {
      isVM = true;
      name = "pki";
      realm = "home";
      cores = 2;
      memorySize = 4;
      diskSize = 50;
      hmFull = false;
    }
    {
      isVM = true;
      name = "home";
      realm = "home";
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
