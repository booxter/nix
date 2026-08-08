{
  hostInventory,
  pkgs,
  ...
}:
let
  nfsPath = "/cache";
in
{
  host.nfs.mounts.nixCache = nfsPath;

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

  host.internalHttps.services.atticd = {
    enable = true;
    serverName = "nix-cache.${hostInventory.site.lan.domain}";
    localAliases = [ "nix-cache" ];
    upstream = "http://127.0.0.1:8080";
    locationExtraConfig = ''
      client_max_body_size 0;
      proxy_request_buffering off;
      proxy_buffering off;
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    '';
  };

  systemd.services.atticd.unitConfig.RequiresMountsFor = "/cache";
}
