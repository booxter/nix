{
  configurations,
  lib,
  repoRoot,
}:
let
  categories = import ./categories.nix;
  participating = lib.filterAttrs (
    _: entry: entry.value.config.host.pki.authority != null
  ) configurations;
  authorityHosts = lib.filterAttrs (
    name: entry: entry.value.config.host.pki.authority.hostName == name
  ) participating;
  authorityNames = builtins.attrNames authorityHosts;
  authorityEntry = builtins.head (builtins.attrValues authorityHosts);
  authorityConfig = authorityEntry.value.config;
  authority = import ./model.nix { config = authorityConfig; } // {
    inherit (authorityConfig.host) realm;
  };
  hosts = lib.mapAttrs (
    _: entry:
    let
      hostConfig = entry.value.config;
    in
    {
      inherit (entry) configuration;
      system = hostConfig.nixpkgs.hostPlatform.system;
      runtimeHost = hostConfig.networking.hostName;
      inherit (hostConfig.host) realm;
    }
  ) participating;
  hostCertificates = lib.concatLists (
    lib.mapAttrsToList (
      host: entry:
      let
        hostConfig = entry.value.config;
        inherit (hostConfig.host) realm;
      in
      map (
        certificate:
        certificate
        // {
          inherit host realm;
          secretPath = "secrets/${realm}/${host}.yaml";
          inherit (categories.${certificate.category}) certificateField keyField;
        }
      ) (builtins.attrValues hostConfig.host.pki.certificates)
    ) participating
  );
in
assert lib.assertMsg (
  builtins.length authorityNames == 1
) "fleet PKI requires exactly one authority host";
{
  inherit
    authority
    hosts
    ;
  repoRoot = toString repoRoot;
  certificates = hostCertificates;
}
