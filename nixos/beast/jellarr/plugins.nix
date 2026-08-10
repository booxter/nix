{
  config,
  lib,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  registry = import ./plugin-registry.nix;
  enabledPluginIds = builtins.filter (
    plugin: builtins.elem plugin model.requiredPlugins
  ) registry.pluginOrder;
  enabledRepositoryIds = lib.unique (
    map (plugin: registry.plugins.${plugin}.repository) enabledPluginIds
  );
in
{
  host.jellyfin.declarativeConfig = {
    system.pluginRepositories = map (repository: registry.repositories.${repository}) (
      builtins.filter (repository: builtins.elem repository enabledRepositoryIds) registry.repositoryOrder
    );
    plugins = map (plugin: { inherit (registry.plugins.${plugin}) name; }) enabledPluginIds;
  };
}
