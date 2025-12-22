{ ... }:
{
  imports = [
    ../_mixins/auto-update
  ];

  # TODO: is it really needed?
  systemd.tmpfiles.rules = [ "f /etc/nix/attic-push-hook.sh 0755 root root -" ];
}
