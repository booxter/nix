{ inputs, pkgs, ... }:
let
  inherit (pkgs) lib;
  jellyfinPkgs = import inputs.nixpkgs-jellyfin {
    inherit (pkgs.stdenv.hostPlatform) system;
  };
in
pkgs.testers.runNixOSTest {
  name = "jellyfin-catalogue";

  nodes.machine =
    { config, ... }:
    {
      imports = [
        inputs.jellarr.nixosModules.default
        ../../nixos/beast/jellyfin/catalogue.nix
      ];

      options.host.jellyfinDeclarativeConfig.system.pluginRepositories = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
        default = [ ];
      };

      config = {
        services.jellyfin = {
          enable = true;
          package = jellyfinPkgs.jellyfin;
        };

        services.jellarr = {
          enable = true;
          package = jellyfinPkgs.callPackage ../../nixos/_mixins/jellyfin/packages/jellarr {
            src = inputs.jellarr;
          };
          environmentFile = "/run/jellarr.env";
          config = {
            version = 1;
            base_url = "http://127.0.0.1:8096";
            system = {
              serverName = "catalogue-test";
              inherit (config.host.jellyfinDeclarativeConfig.system) pluginRepositories;
            };
          };
        };
        # The test completes the wizard and obtains a real API token first.
        systemd.services.jellarr.wantedBy = lib.mkForce [ ];
        systemd.timers.jellarr.wantedBy = lib.mkForce [ ];

        host.jellyfinDeclarativeConfig.system.pluginRepositories = [
          {
            name = "Existing repository";
            url = "http://127.0.0.1:8181/existing.json";
            enabled = true;
          }
        ];
        services.nginx.virtualHosts.jellyfin-plugins.locations."= /existing.json".alias =
          pkgs.writeText "existing.json"
            (builtins.toJSON [ ]);
        services.nginx.virtualHosts.jellyfin-plugins.root = lib.mkForce (
          pkgs.writeTextDir "manifest.json" (builtins.toJSON [ ])
        );

        environment.systemPackages = [ pkgs.curl ];
        virtualisation = {
          memorySize = 2048;
          diskSize = 4096;
        };
      };
    };

  testScript = builtins.readFile ./lib/jellyfin.py + builtins.readFile ./jellyfin-catalogue/test.py;
}
