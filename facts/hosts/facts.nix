{
  context,
  lib,
}:
let
  inherit (context) frame;

  builderSpecs = lib.genAttrs (map (idx: "builder${toString idx}") [
    1
    2
    3
  ]) (_: { });

  labProxmoxSpecs = lib.genAttrs (map (index: "prx${toString index}-lab") [
    1
    2
    3
  ]) (_: { });
in
{
  darwin = {
    mair = { };
    mmini = { };
    JGWXHWDL4X = { };
  };

  nixos = {
    ${frame} = { };
    nvws = { };
    beast = { };
    nv = { };
    cache = { };
    srvarr = { };
    fana = { };
    gw = { };
    org = { };
    pki = { };
    home = { };
  }
  // labProxmoxSpecs
  // builderSpecs;
}
