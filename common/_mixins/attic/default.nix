{
  config,
  hostInventory,
  lib,
  hostname,
  hostSpecName ? hostname,
  ...
}:
let
  hostSecretName =
    if builtins.hasAttr hostSpecName hostInventory.nixosHostSpecsByName then hostSpecName else hostname;
  hostSecretFile = ../../../secrets/${hostSecretName}.yaml;
in
lib.mkMerge [
  {
    sops = {
      defaultSopsFile = hostSecretFile;
    }
    // {
      secrets = {
        "attic/token" = { };
      };
      templates."attic-client-config.toml" = {
        owner = "root";
        group = "root";
        mode = "0400";
        content = ''
          default-server = "local"
          [servers.local]
          endpoint = "https://nix-cache.home.arpa"
          token = "${config.sops.placeholder."attic/token"}"
        '';
      };
    };
  }
]
