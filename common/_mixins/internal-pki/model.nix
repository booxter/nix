{
  config,
  hostSpec,
  lib,
  outputs,
}:
let
  localHost = hostSpec.name;
  localAuthority = {
    hostName = localHost;
    inherit (config.host) realm;
    inherit (config.host.pki) role;
    inherit (config.host.pki) authority;
  };
  otherConfigurations = builtins.removeAttrs (
    outputs.nixosConfigurations // outputs.darwinConfigurations
  ) [ localHost ];
  otherAuthorities = lib.mapAttrs (_: configuration: {
    hostName = configuration.config.networking.hostName;
    inherit (configuration.config.host) realm;
    inherit (configuration.config.host.pki) role;
    inherit (configuration.config.host.pki) authority;
  }) otherConfigurations;
  candidates = otherAuthorities // {
    ${localHost} = localAuthority;
  };
  realmAuthorities = lib.filterAttrs (
    _: candidate: candidate.realm == config.host.realm && candidate.role == "authority"
  ) candidates;
  authorityNames = builtins.attrNames realmAuthorities;
  realmAuthority =
    if builtins.length authorityNames == 1 then
      let
        candidate = realmAuthorities.${builtins.head authorityNames};
      in
      {
        inherit (candidate) hostName realm;
        inherit (candidate.authority)
          leafLifetimeDays
          port
          provisioner
          rootCaCertificate
          rootsPath
          url
          ;
      }
    else
      null;
in
{
  inherit authorityNames realmAuthority;
}
