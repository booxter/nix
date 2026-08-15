{
  configuration,
  host,
  repo,
}:
let
  flake = builtins.getFlake "path:${repo}";
  configuredHost = (builtins.getAttr host (builtins.getAttr configuration flake)).config;
  realmAuthority = import ../../common/_mixins/internal-pki/model.nix { config = configuredHost; };
in
{
  realm = configuredHost.host.realm;
  realm_authority =
    if realmAuthority == null then null else realmAuthority // { inherit (configuredHost.host) realm; };
  certificates = builtins.attrValues configuredHost.host.pki.certificates;
}
