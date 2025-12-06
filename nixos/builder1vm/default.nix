{ ... }:
{
  systemd.services.nix-daemon.serviceConfig = {
    MemoryAccounting = true;
    MemoryMax = "90%";
    OOMScoreAdjust = 500;
  };

  # TODO: is it really needed?
  systemd.tmpfiles.rules = [ "f /etc/nix/attic-push-hook.sh 0755 root root -" ];
}
