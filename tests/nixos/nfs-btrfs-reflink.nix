{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "nfs-btrfs-reflink";

  nodes.server = {
    boot.supportedFilesystems = [ "btrfs" ];
    virtualisation.emptyDiskImages = [ 512 ];
    environment.systemPackages = [
      pkgs.btrfs-progs
      pkgs.python314
    ];
    environment.etc."reflink-probe.py".source = ./nfs-btrfs-reflink/probe.py;
    networking.firewall.enable = false;
    services.nfs.server = {
      enable = true;
      exports = ''
        /srv/media *(rw,sync,no_subtree_check,no_root_squash,fsid=10)
        /srv/media/torrents *(rw,sync,no_subtree_check,no_root_squash,fsid=11)
      '';
    };
  };

  nodes.client = {
    boot.supportedFilesystems = [ "nfs" ];
    environment.systemPackages = [ pkgs.python314 ];
    environment.etc."reflink-probe.py".source = ./nfs-btrfs-reflink/probe.py;
    networking.firewall.enable = false;
  };

  testScript = builtins.readFile ./nfs-btrfs-reflink/test.py;
}
