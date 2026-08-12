{ config, lib }:
let
  cfg = config.host.aurral;
  slskd = import ../slskd/model.nix { inherit config lib; };
  selected =
    if cfg.slskd.instance == null then null else slskd.resolved.${cfg.slskd.instance} or null;
in
{
  inherit cfg selected slskd;
}
