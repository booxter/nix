{ config, lib }:
let
  cfg = config.host.aurral;
  slskd = import ../slskd/model.nix { inherit config lib; };
in
{
  inherit cfg slskd;
  selected = slskd.resolved;
}
