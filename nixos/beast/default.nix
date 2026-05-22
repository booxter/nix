{
  hostInventory,
  pkgs,
  username,
  ...
}:
{
  imports = [
    (import ../../disko { })
    ./backup-server.nix
    ./btrfs.nix
    ./disk-bays.nix
    ./igpu.nix
    ./jellyfin.nix
    ./jellyfin-exporter.nix
    ./jellyfin-backup.nix
    ./jellarr.nix
    ./library-dirs.nix
    ./nfs.nix
    ./nginx.nix
    ./pause.nix
    ./raid.nix
    ./ups.nix
  ];

  # Pin this host to the latest stable release channel (critical infra).
  users.users.${username}.hashedPassword = "$6$gQ7Gm5b2aq7qPn7W$dcuDT19.SJ88xPA4tQHbscdJDMo3wK.UXGhffrohh7YU4QAzcmRk3GKPNku.BnGrkgDYvZXm/4tBfT.NP6eF.1";

  # Use the freshest kernel available on the stable channel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Host critical services; keep upgrades on Monday, separate from the fleet's
  # default Saturday schedule, but still leave room for local backups and later
  # cloud offload jobs after the reboot window work settles.
  system.autoUpgrade.dates = "Mon 04:00";
  system.autoUpgrade.randomizedDelaySec = "15min";

  users.groups.media.gid = hostInventory.site.gids.media;

  host.observability.client.blackbox.enable = true;

  sops = {
    defaultSopsFile = ../../secrets/beast.yaml;
  };

  networking.resolvconf.enable = true;

  environment.systemPackages = [ pkgs.join-media-parts ];
}
