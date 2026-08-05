let
  flake = builtins.getFlake (builtins.getEnv "DIFF_FLAKE_REF");
  name = builtins.getEnv "DIFF_MACHINE";
  configuration = (builtins.getAttr name flake.darwinConfigurations).config;
  entryName = entry: if builtins.isString entry then entry else entry.name;
  taps = builtins.mapAttrs (_: path: toString path) configuration."nix-homebrew".taps;
in
{
  enabled = configuration.homebrew.enable;
  brews = map entryName configuration.homebrew.brews;
  casks = map entryName configuration.homebrew.casks;
  inherit taps;
}
