{ inputs, pkgs, ... }:
let
  inherit (pkgs) lib;
  plugins = builtins.attrValues (import ../../nixos/beast/pkgs/jellyfin-plugins { inherit pkgs; });
  catalogue = pkgs.callPackage ../../nixos/beast/pkgs/jellyfin-plugins/catalogue.nix { } {
    inherit plugins;
  };
  jellarr = pkgs.callPackage ../../nixos/_mixins/jellyfin/packages/jellarr {
    src = inputs.jellarr;
  };
  jellarrConfig = pkgs.writeText "jellarr-plugin-set.json" (
    builtins.toJSON {
      version = 1;
      base_url = "http://127.0.0.1:8096";
      system.pluginRepositories = [
        {
          name = "Local builds";
          url = "http://127.0.0.1:8181/manifest.json";
          enabled = true;
        }
      ];
      plugins = map (plugin: {
        name = plugin.pluginName;
        id = plugin.pluginId;
      }) plugins;
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "jellyfin-plugin-set";
  nodes.machine = {
    services.jellyfin = {
      enable = true;
      package = pkgs.jellyfin;
    };
    services.nginx = {
      enable = true;
      virtualHosts.catalogue = {
        listen = [
          {
            addr = "127.0.0.1";
            port = 8181;
          }
        ];
        root = catalogue;
      };
    };
    services.meilisearch = {
      enable = true;
      listenAddress = "127.0.0.1";
      masterKeyFile = pkgs.writeText "meilisearch-test-key" "catalogue-test-key";
      settings.env = "development";
    };
    systemd.services.jellyfin.environment = {
      MEILI_URL = "http://127.0.0.1:7700";
      MEILI_MASTER_KEY = "catalogue-test-key";
    };
    systemd.services.jellarr.serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe jellarr} --configFile ${jellarrConfig}";
      EnvironmentFile = "/run/jellarr.env";
    };
    environment.systemPackages = [ pkgs.curl ];
    virtualisation = {
      memorySize = 3072;
      diskSize = 4096;
    };
  };
  testScript = ''
    EXPECTED = ${
      builtins.toJSON (
        builtins.listToAttrs (
          map (plugin: {
            name = lib.replaceStrings [ "-" ] [ "" ] plugin.pluginId;
            value = plugin.version;
          }) plugins
        )
      )
    }
  ''
  + builtins.readFile ./lib/jellyfin.py
  + builtins.readFile ./jellyfin-plugin-set/test.py;
}
