{ config }:
let
  cfg = config.host.aurral;
  slskd = import ./slskd/model.nix { inherit config; };
  storageClaim = if cfg == null then null else config.host.storage.claims.${cfg.storageClaim} or null;
in
{
  inherit cfg slskd storageClaim;
  selected = slskd.resolved;
  ssoApplication = config.host.sso.applications.aurral or null;
  port = 3001;
  user = "aurral";
  group = "media";
  flowRelativePath = "library/flows";
  flowDir = if storageClaim == null then null else "${storageClaim.mountPoint}/library/flows";
}
