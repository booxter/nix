{ lib }:
let
  validIpv4 =
    address:
    let
      parts = if builtins.isString address then lib.splitString "." address else [ ];
    in
    builtins.length parts == 4
    && lib.all (part: builtins.match "(0|[1-9][0-9]{0,2})" part != null) parts
    && lib.all (part: builtins.fromJSON part <= 255) parts;

  ipv4ToInt =
    address:
    lib.foldl' (result: part: result * 256 + builtins.fromJSON part) 0 (lib.splitString "." address);

  validPrefixLength = prefix: builtins.match "(0|[1-9]|[12][0-9]|3[0-2])" prefix != null;

  validCidr =
    cidr:
    let
      parts = if builtins.isString cidr then lib.splitString "/" cidr else [ ];
    in
    builtins.length parts == 2
    && validIpv4 (builtins.elemAt parts 0)
    && validPrefixLength (builtins.elemAt parts 1);

  prefixLength = cidr: builtins.fromJSON (builtins.elemAt (lib.splitString "/" cidr) 1);

  inCidr =
    cidr: address:
    let
      network = builtins.elemAt (lib.splitString "/" cidr) 0;
      hostBits = 32 - prefixLength cidr;
      blockSize = lib.foldl' (result: _: result * 2) 1 (builtins.genList (_: null) hostBits);
    in
    validCidr cidr
    && validIpv4 address
    && builtins.div (ipv4ToInt address) blockSize == builtins.div (ipv4ToInt network) blockSize;
in
{
  inherit
    inCidr
    ipv4ToInt
    prefixLength
    validCidr
    validIpv4
    ;
}
