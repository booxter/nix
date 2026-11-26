{ inputs, pkgs, ... }:
let
  inherit (pkgs) lib;
  jellyfinPkgs = import inputs.nixpkgs-jellyfin {
    inherit (pkgs.stdenv.hostPlatform) system;
  };
  fixture =
    localRevision:
    import ./jellyfin-plugin-updates/package.nix {
      inherit pkgs localRevision;
      jellyfin = jellyfinPkgs.jellyfin;
    };
  original = fixture 1;
  updated = fixture 2;
  buildCatalogue = pkgs.callPackage ../../nixos/beast/pkgs/jellyfin-plugins/catalogue.nix { };
  catalogue = plugin: buildCatalogue { plugins = [ plugin ]; };
  originalCatalogue = catalogue original;
  updatedCatalogue = catalogue updated;
  incompatibleCatalogue = catalogue (
    updated
    // {
      version = "99.0.0.0";
      targetAbi = "99.0.0.0";
    }
  );
  badChecksumCatalogue =
    pkgs.runCommand "jellyfin-bad-checksum-catalogue" { nativeBuildInputs = [ pkgs.jq ]; }
      ''
        mkdir -p "$out"
        cp -r ${updatedCatalogue}/${updated.pname} "$out/"
        jq '.[0].versions[0].checksum = "00000000000000000000000000000000"' \
          ${updatedCatalogue}/manifest.json > "$out/manifest.json"
      '';
  jellarr = jellyfinPkgs.callPackage ../../nixos/_mixins/jellyfin/packages/jellarr {
    src = inputs.jellarr;
  };
  jellarrConfig = pkgs.writeText "jellarr-catalogue.json" (
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
      plugins = [
        {
          name = original.pluginName;
          id = original.pluginId;
          configuration.ManagedSetting = "declarative";
        }
      ];
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "jellyfin-plugin-updates";
  nodes.machine = {
    services.jellyfin = {
      enable = true;
      package = jellyfinPkgs.jellyfin;
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
        root = "/run/catalogue";
      };
    };
    systemd.services.jellarr.serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe jellarr} --configFile ${jellarrConfig}";
      EnvironmentFile = "/run/jellarr.env";
    };
    environment.systemPackages = [ pkgs.curl ];
    virtualisation = {
      memorySize = 2048;
      diskSize = 4096;
    };
  };
  testScript = ''
    ORIGINAL_CATALOGUE = ${builtins.toJSON (toString originalCatalogue)}
    UPDATED_CATALOGUE = ${builtins.toJSON (toString updatedCatalogue)}
    INCOMPATIBLE_CATALOGUE = ${builtins.toJSON (toString incompatibleCatalogue)}
    BAD_CHECKSUM_CATALOGUE = ${builtins.toJSON (toString badChecksumCatalogue)}
    ORIGINAL_VERSION = ${builtins.toJSON original.version}
    UPDATED_VERSION = ${builtins.toJSON updated.version}
    PLUGIN_ID = ${builtins.toJSON original.pluginId}
  ''
  + builtins.readFile ./lib/jellyfin.py
  + builtins.readFile ./jellyfin-plugin-updates/test.py;
}
