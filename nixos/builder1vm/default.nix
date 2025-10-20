{ inputs, pkgs, ... }: let
  atticUrl   = "http://prox-cachevm:8080";
  cacheName  = "default";
  cachePub   = "default:+epFjzN1YKGqqeraQczdEfRyIuzgWd6/nrifa0467QQ=";
in {
  imports = [
    inputs.attic.nixosModules.atticd
  ];

  systemd.services.nix-daemon.serviceConfig = {
    MemoryAccounting = true;
    MemoryMax = "90%";
    OOMScoreAdjust = 500;
  };

  # TODO: Adopt secrets management
  # /root/.config/attic/config.toml:

  # default-server = "local"
  # [servers.local]
  # endpoint = "http://prox-cachevm:8080"
  # token = "PASTE_PUSH_TOKEN_HERE"

  # Hook script
  environment.etc."nix/attic-push-hook.sh" = {
    text = ''
      #!/bin/sh
      set -eu
      exec ${pkgs.attic}/bin/attic push ${cacheName} $OUT_PATHS
    '';
    mode = "0755";
  };
  systemd.tmpfiles.rules = [ "f /etc/nix/attic-push-hook.sh 0755 root root -" ];
}
