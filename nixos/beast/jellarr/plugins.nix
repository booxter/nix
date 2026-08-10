{
  config,
  lib,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  registry = import ./plugin-registry.nix;
  enabledPlugins = lib.filterAttrs (
    plugin: _: builtins.elem plugin model.requiredPlugins
  ) registry.plugins;
  enabledRepositoryIds = lib.unique (
    map (plugin: plugin.repository) (builtins.attrValues enabledPlugins)
  );
  enabledRepositories = lib.filterAttrs (
    repository: _: builtins.elem repository enabledRepositoryIds
  ) registry.repositories;
in
{
  host.jellyfin.declarativeConfig = {
    system.pluginRepositories = builtins.attrValues enabledRepositories;
    plugins = map (plugin: { inherit (plugin) name; }) (builtins.attrValues enabledPlugins);
  };
}
