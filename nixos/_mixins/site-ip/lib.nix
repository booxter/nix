{ lib }:
let
  validIpv4 =
    address:
    let
      parts = lib.splitString "." address;
    in
    builtins.length parts == 4
    && lib.all (part: builtins.match "(0|[1-9][0-9]{0,2})" part != null) parts
    && lib.all (part: builtins.fromJSON part <= 255) parts;

  ipv4ToInt =
    address:
    lib.foldl' (result: part: result * 256 + builtins.fromJSON part) 0 (lib.splitString "." address);

  inCidr =
    cidr: address:
    let
      cidrParts = lib.splitString "/" cidr;
      network = builtins.elemAt cidrParts 0;
      prefixLength = builtins.fromJSON (builtins.elemAt cidrParts 1);
      hostBits = 32 - prefixLength;
      blockSize = lib.foldl' (result: _: result * 2) 1 (builtins.genList (_: null) hostBits);
    in
    validIpv4 address
    && builtins.div (ipv4ToInt address) blockSize == builtins.div (ipv4ToInt network) blockSize;
in
{
  inherit
    inCidr
    ipv4ToInt
    validIpv4
    ;
}
