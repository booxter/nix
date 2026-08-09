{
  appSet,
  pkgs,
  ...
}:
appSet.packages
// {
  patch-context = pkgs.patch-context;
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  backup = import ../tests/nixos/backup.nix { inherit pkgs; };
  blackbox = import ../tests/nixos/blackbox.nix { inherit pkgs; };
  oauth2-proxy-gate = import ../tests/nixos/oauth2-proxy-gate.nix { inherit pkgs; };
  qos = import ../tests/nixos/qos.nix { inherit pkgs; };
}
