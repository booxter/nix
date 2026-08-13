{
  config,
  lib,
  outputs,
}:
let
  localHost = config.networking.hostName;
  otherConfigurations = builtins.removeAttrs (
    outputs.nixosConfigurations // outputs.darwinConfigurations
  ) [ localHost ];
  hostView = hostConfig: {
    inherit (hostConfig.host.site) name;
    providers = lib.filterAttrs (_: provider: provider.enable) hostConfig.host.site.search.providers;
  };
  hosts = lib.mapAttrs (_: configuration: hostView configuration.config) otherConfigurations // {
    ${localHost} = hostView config;
  };
  siteHosts = lib.filterAttrs (_: host: host.name == config.host.site.name) hosts;
  contributions = builtins.concatLists (
    lib.mapAttrsToList (
      owner: host:
      lib.mapAttrsToList (id: provider: {
        inherit id owner;
        inherit (provider) aliases endpoints title;
      }) host.providers
    ) siteHosts
  );
  byIdLists = builtins.groupBy (provider: provider.id) contributions;
  duplicateIds = lib.filterAttrs (_: values: builtins.length values != 1) byIdLists;
  byId = lib.mapAttrs (_: values: builtins.head values) byIdLists;
in
assert lib.assertMsg (duplicateIds == { }) (
  "search provider IDs must be unique within site '${toString config.host.site.name}': "
  + lib.concatStringsSep ", " (builtins.attrNames duplicateIds)
);
{
  inherit byId contributions;
}
