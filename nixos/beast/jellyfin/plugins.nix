{
  config,
  lib,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  registry = import ./plugin-registry.nix;
  requiredPlugins = model.requiredPlugins ++ [
    "language-tags"
    "polyglot"
  ];
  enabledPlugins = lib.filterAttrs (plugin: _: builtins.elem plugin requiredPlugins) registry.plugins;
  unknownPlugins = builtins.filter (
    plugin: !builtins.hasAttr plugin registry.plugins
  ) requiredPlugins;
in
{
  assertions = [
    {
      assertion = unknownPlugins == [ ];
      message = "Jellarr requires unknown plugins: ${lib.concatStringsSep ", " unknownPlugins}";
    }
  ];

  host.jellyfinDeclarativeConfig = {
    plugins = builtins.attrValues enabledPlugins;
  };
}
