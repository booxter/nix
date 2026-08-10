{
  config,
  facts,
  lib,
  pkgs,
  ...
}:
let
  nfsPath = facts.nfs.links.cache.nixCache.mountPoint;
in
{
  system.stateVersion = "25.11";

  host.network = {
    macAddress = "bc:24:11:0d:85:41";
    reservation = {
      enable = true;
      address = "192.168.20.7";
    };
  };

  environment.systemPackages = with pkgs; [
    attic-client
  ];

  # https://docs.attic.rs/admin-guide/deployment/nixos.html
  services.atticd = {
    enable = true;

    # Replace with absolute path to your environment file
    # Put in file: ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=$(nix run nixpkgs#openssl -- genrsa -traditional 4096 | base64 -w0)
    environmentFile = "/etc/atticd.env";

    settings = {
      listen = "127.0.0.1:8080";

      jwt = { };

      # Data chunking
      #
      # Warning: If you change any of the values here, it will be
      # difficult to reuse existing chunks for newly-uploaded NARs
      # since the cutpoints will be different. As a result, the
      # deduplication ratio will suffer for a while after the change.
      chunking = {
        # The minimum NAR size to trigger chunking
        #
        # If 0, chunking is disabled entirely for newly-uploaded NARs.
        # If 1, all NARs are chunked.
        nar-size-threshold = 64 * 1024; # 64 KiB

        # The preferred minimum size of a chunk, in bytes
        min-size = 16 * 1024; # 16 KiB

        # The preferred average size of a chunk, in bytes
        avg-size = 64 * 1024; # 64 KiB

        # The preferred maximum size of a chunk, in bytes
        max-size = 256 * 1024; # 256 KiB
      };

      storage = {
        type = "local";
        path = nfsPath;
      };
    };
  };

  host.web.services.atticd = {
    enable = true;
    upstream = "http://127.0.0.1:8080";
    internal = {
      serverName = "nix-cache.${config.host.network.lanDomain}";
      localAliases = [ "nix-cache" ];
      locationExtraConfig = ''
        client_max_body_size 0;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
      '';
    };
  };

  # Upgrade cache before the Monday critical-infra window so the cache is
  # ready before machines that may consume it during their own auto-updates.
  system.autoUpgrade.dates = lib.mkForce "Mon 03:30";
  system.autoUpgrade.randomizedDelaySec = lib.mkForce "5min";
  system.autoUpgrade.rebootWindow = {
    lower = lib.mkForce "02:59";
    upper = lib.mkForce "06:00";
  };

  systemd.services.atticd.unitConfig.RequiresMountsFor = "/cache";
}
