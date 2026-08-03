let
  flake = builtins.getFlake (builtins.getEnv "DIFF_FLAKE_REF");
  name = builtins.getEnv "DIFF_MACHINE";
  hasNixos = flake ? nixosConfigurations && builtins.hasAttr name flake.nixosConfigurations;
  hasDarwin = flake ? darwinConfigurations && builtins.hasAttr name flake.darwinConfigurations;
in
if hasNixos then
  "nixos"
else if hasDarwin then
  "darwin"
else
  "missing"
