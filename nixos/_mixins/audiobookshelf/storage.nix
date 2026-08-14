{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  claims = lib.unique (
    map (library: library.media.storage.claim) (
      builtins.filter (library: library.media != null) (builtins.attrValues model.libraries)
    )
  );
in
{
  config = lib.mkIf (cfg != null) {
    host.storage.claims = lib.mkMerge (
      map (claim: {
        ${claim}.attachments.audiobookshelf.unit = "audiobookshelf";
      }) claims
    );

    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
    ];
  };
}
