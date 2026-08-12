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
    }
    {
      hostKind = "nixos";
      name = "beast";
      realm = "home";
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
    }
    {
      isVM = true;
      name = "fana";
      realm = "home";
      cores = 8;
      memorySize = 16;
      diskSize = 300;
    }
    {
      isVM = true;
      name = "gw";
      realm = "home";
      cores = 2;
      memorySize = 8;
      diskSize = 64;
    }
    {
      isVM = true;
      name = "org";
      realm = "home";
      cores = 4;
      memorySize = 16;
      diskSize = 80;
    }
    {
      isVM = true;
      name = "pki";
      realm = "home";
      cores = 2;
      memorySize = 4;
      diskSize = 50;
    }
    {
      isVM = true;
      name = "home";
      realm = "home";
      cores = 4;
      memorySize = 8;
      diskSize = 80;
    }
  ]
  ++ map builderSpec [
    1
    2
    3
  ];
}
