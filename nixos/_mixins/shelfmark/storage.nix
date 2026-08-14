{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  storageClaims = lib.unique (
    map (item: item.storage.claim) (
      builtins.filter (item: item != null) [
        model.ebooks
        model.audiobooks
        model.torrent
        model.usenet
      ]
    )
  );
in
{
  config = lib.mkIf (cfg != null) {
    host.storage.claims = lib.mkMerge (
      map (claim: {
        ${claim}.attachments.shelfmark.unit = "shelfmark";
      }) storageClaims
    );

    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0700 ${model.user} root - -"
    ];
  };
}
