{ lib, pkgs, ... }:
let
  nfsPath = "/cache";
  cache = {
    device = "beast:/volume2/nix-cache";
    fsType = "nfs";
  };
in
{
  # local qemu vms override filesystems
  # TODO: move this special handling for FS to mkVM?
  fileSystems.${nfsPath} = cache;
  virtualisation.vmVariant.virtualisation.fileSystems.${nfsPath} = cache;

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
      listen = "[::]:8080";

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
  networking.firewall.allowedTCPPorts = [
    8080
  ];

  # auto-update cachevm on a separate schedule so that it doesn't clash with
  # machines that use the cache for their auto-updates.
  system.autoUpgrade.dates = lib.mkForce "Sun 06:00";

  systemd.services.atticd.unitConfig.RequiresMountsFor = "/cache";
}
