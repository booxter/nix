{
  config,
  lib,
  hostname,
  ...
}:
let
  hostSecretFile = ../../../secrets/${hostname}.yaml;
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
