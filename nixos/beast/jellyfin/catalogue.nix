{ pkgs, ... }:
let
  url = "http://127.0.0.1:8181";
in
{
  services.nginx = {
    enable = true;
    virtualHosts.jellyfin-plugins = {
      # Only Jellyfin on this machine needs access to the repository.
      listen = [
        {
          addr = "127.0.0.1";
          port = 8181;
        }
      ];
      root = pkgs.writeTextDir "manifest.json" (builtins.toJSON [ ]);
    };
  };

  host.jellyfinDeclarativeConfig.system.pluginRepositories = [
    {
      name = "Local builds";
      url = "${url}/manifest.json";
      enabled = true;
    }
  ];

  systemd.services.jellarr = {
    requires = [ "nginx.service" ];
    after = [ "nginx.service" ];
  };
}
