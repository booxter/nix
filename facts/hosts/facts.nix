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
        realm = "home";
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
      });
in
{
  darwin = {
    mair = {
      realm = "home";
    };
    mmini = {
      realm = "home";
    };
    JGWXHWDL4X = {
      realm = "work";
    };
  };

  nixos = {
    ${frame} = {
      hostKind = "nixos";
      realm = "home";
      isDesktop = true;
    };
    nvws = {
      hostKind = "proxmox";
      realm = "work";
    };
    beast = {
      hostKind = "nixos";
      realm = "home";
    };
    nv = {
      realm = "work";
    };
    cache = {
      realm = "home";
    };
    srvarr = {
      realm = "home";
    };
    fana = {
      realm = "home";
    };
    gw = {
      realm = "home";
    };
    org = {
      realm = "home";
    };
    pki = {
      realm = "home";
    };
    home = {
      realm = "home";
    };
  }
  // labProxmoxSpecs
  // builderSpecs;
}
