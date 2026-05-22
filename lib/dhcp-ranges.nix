{ lib }:
rec {
  ipToInt = ip: lib.foldl' (acc: octet: acc * 256 + octet) 0 (map lib.toInt (lib.splitString "." ip));

  pow2 = n: if n == 0 then 1 else 2 * pow2 (n - 1);

  cidrToRange =
    cidr:
    let
      parts = lib.splitString "/" cidr;
      address = builtins.elemAt parts 0;
      prefixLength = lib.toInt (builtins.elemAt parts 1);
      networkSize = pow2 (32 - prefixLength);
      start = builtins.div (ipToInt address) networkSize * networkSize;
    in
    {
      inherit start;
      end = start + networkSize - 1;
    };

  rangeToIntBounds = range: {
    start = ipToInt range.start;
    end = ipToInt range.end;
  };

  rangeOverlapsCidr =
    range: cidr:
    let
      rangeBounds = rangeToIntBounds range;
      cidrBounds = cidrToRange cidr;
    in
    rangeBounds.start <= cidrBounds.end && cidrBounds.start <= rangeBounds.end;

  mkExclusionAssertions =
    name: dhcpRange:
    map (excludeRange: {
      assertion = builtins.all (range: !(rangeOverlapsCidr range excludeRange)) dhcpRange.ranges;
      message = "LAN DHCP pool `${name}` must not overlap excluded subnet `${excludeRange}`.";
    }) dhcpRange.excludeRanges;
}
