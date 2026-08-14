{
  configuration,
  host,
  repo,
}:
let
  flake = builtins.getFlake "path:${repo}";
  configuredHost = (builtins.getAttr host (builtins.getAttr configuration flake)).config;
  realmAuthority = configuredHost.host.pki.authority;
in
{
  realm = configuredHost.host.realm;
  realm_authority =
    if realmAuthority == null then null else realmAuthority // { inherit (configuredHost.host) realm; };
  certificates = builtins.attrValues configuredHost.host.pki.certificates;
}
