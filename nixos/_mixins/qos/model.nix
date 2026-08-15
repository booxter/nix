{
  config,
  lib,
  pkgs,
}:
let
  cfg = config.host.qos;
  package = pkgs.callPackage ./pkgs/qosctl { };
  rateBits = rateMbit: builtins.floor (rateMbit * 1000 * 1000);
  profileNames = builtins.attrNames cfg.interfaces;
  profileIndexes = builtins.listToAttrs (
    lib.imap0 (index: name: {
      inherit name;
      value = index;
    }) profileNames
  );
  profileData = builtins.mapAttrs (
    profileName: profile:
    let
      limitNames = builtins.attrNames profile.limits;
      egressNames = builtins.filter (name: profile.limits.${name}.direction == "egress") limitNames;
      ingressNames = builtins.filter (name: profile.limits.${name}.direction == "ingress") limitNames;
      classMinors = builtins.listToAttrs (
        lib.imap0 (index: name: {
          inherit name;
          value = 16 + index;
        }) egressNames
      );
      ifbInterfaces = builtins.listToAttrs (
        lib.imap0 (index: name: {
          inherit name;
          value = "ifb-q${toString profileIndexes.${profileName}}-${toString index}";
        }) ingressNames
      );
      limits = map (
        name:
        let
          limit = profile.limits.${name};
        in
        {
          inherit name;
          inherit (limit) direction;
          rateBits = rateBits limit.rateMbit;
          queue =
            if limit.queue != null then
              limit.queue
            else if limit.direction == "ingress" then
              "cake"
            else
              "fq_codel";
          classMinor = classMinors.${name} or 0;
          ifbInterface = ifbInterfaces.${name} or "";
          inherit (limit) match;
        }
      ) limitNames;
      configFile = (pkgs.formats.json { }).generate "qos-${profileName}.json" {
        profile = profileName;
        interface = profile.device;
        nftTable = "qos_${profileName}";
        linkRateBits = rateBits profile.linkRateMbit;
        inherit limits;
      };
    in
    {
      inherit
        classMinors
        configFile
        ifbInterfaces
        ;
    }
  ) cfg.interfaces;
in
{
  inherit
    package
    profileData
    profileNames
    ;
  classIds = builtins.mapAttrs (
    _: data: builtins.mapAttrs (_: minor: "1:${lib.toLower (lib.toHexString minor)}") data.classMinors
  ) profileData;
  configFiles = builtins.mapAttrs (_: data: data.configFile) profileData;
  hasIngress = lib.any (profileName: profileData.${profileName}.ifbInterfaces != { }) profileNames;
}
