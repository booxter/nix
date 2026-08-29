{ inputs, pkgs, ... }:
let
  fixtures = ./aurral;
  inherit (pkgs) lib;
  lidarrApiKey = "lidarr-test-api-key";
  slskdApiKey = "slskd-test-api-key";
  wireguardConfig = pkgs.writeText "aurral-test-wireguard.conf" ''
    [Interface]
    PrivateKey = 8PZQ8felOfsPGDaAPdHaJlkf0hcCn6JGhU1DJq5Ts3M=
    Address = 10.100.0.2/24
    DNS = 1.1.1.1

    [Peer]
    PublicKey = ObYLOQ9jBDhE2a/Jxgzg3f+Navp0rXjkctKCelb0xEI=
    AllowedIPs = 0.0.0.0/0
    Endpoint = 127.0.0.1:51820
  '';
in
pkgs.testers.runNixOSTest {
  name = "aurral";
  node.specialArgs = { inherit inputs; };

  nodes.machine = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../../nixos/_mixins/aurral/composition.nix
      ./lib/sops.nix
    ];

    _module.args.storageConfigurations = { };

    networking.hostName = "aurral-node";

    host = {
      realm = "test";
      network = {
        lanDomain = "test.invalid";
        publicDomain = "example.invalid";
      };
      site.timeZone = "Etc/UTC";
      aurral = {
        storageClaim = "media";
        publicHostName = "music.example.invalid";
        slskd = {
          vpnNamespace = "wg";
          peerPort = 13869;
        };
      };
      storage = {
        claims.media = {
          provider = "aurral-node";
          resource = "media";
          mountPoint = "/srv/media";
        };
        resources.media = {
          volume = "durable";
          relativePath = ".";
          directoryDefaults = {
            owner = "root";
            group = "media";
            mode = "0755";
          };
        };
        volumes.durable = {
          mountPoint = "/srv/durable";
          device = "none";
          fsType = "tmpfs";
        };
      };
      sso = {
        groups = [
          "media-admins"
          "media-users"
        ];
        applications.aurral.roles = {
          admin = "media-admins";
          user = "media-users";
        };
        users = {
          admin.groups = [
            "media-admins"
            "media-users"
          ];
          listener.groups = [ "media-users" ];
        };
      };
      vpn.namespaces.wg = {
        accessibleFrom = [ "127.0.0.1" ];
        bridgeAddress = "192.168.50.5";
        namespaceAddress = "192.168.50.1";
        wireguardConfigFile = "${wireguardConfig}";
      };
    };

    # NixOS tests replace normal host filesystems with their VM root disk.
    # Recreate the local provider volume and its claim inside the VM.
    virtualisation.fileSystems = {
      "/srv/durable" = {
        device = "none";
        fsType = "tmpfs";
      };
      "/srv/media" = {
        device = "/srv/durable";
        fsType = "none";
        options = [
          "bind"
          "nofail"
          "x-systemd.requires-mounts-for=/srv/durable"
        ];
      };
    };

    services.nginx.enable = true;

    sops.placeholder = {
      "slskd/soulseek/username" = "test-user";
      "slskd/soulseek/password" = "test-password";
      "slskd/web/username" = "test-admin";
      "slskd/web/password" = "test-password";
      "slskd/web/apiKey" = slskdApiKey;
    };

    testSupport.sops.values = {
      "slskd/soulseek/username" = "test-user";
      "slskd/soulseek/password" = "test-password";
      "slskd/web/username" = "test-admin";
      "slskd/web/password" = "test-password";
      "slskd/web/apiKey" = slskdApiKey;
    };

    systemd.services.fake-lidarr = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          "${pkgs.python3}/bin/python"
          "${fixtures}/fake-lidarr.py"
          "--api-key"
          lidarrApiKey
          "--port"
          "8686"
        ];
        Restart = "on-failure";
      };
    };

    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    AURRAL_URL = "http://127.0.0.1:3001"
    CURL = ${builtins.toJSON (lib.getExe pkgs.curl)}
    LIDARR_API_KEY = ${builtins.toJSON lidarrApiKey}
    LIDARR_URL = "http://127.0.0.1:8686"
    SLSKD_API_KEY = ${builtins.toJSON slskdApiKey}
    SLSKD_URL = "http://192.168.50.1:5030"
  ''
  + builtins.readFile "${fixtures}/test.py";
}
