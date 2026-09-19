{ config }:
let
  cfg = config.host.aurral;
  storageClaim = if cfg == null then null else config.host.storage.claims.${cfg.storageClaim} or null;
in
{
  inherit cfg storageClaim;
  ssoApplication = config.host.sso.applications.aurral or null;
  port = 3001;
  user = "aurral";
  group = "media";
  flowRelativePath = "library/flows";
  flowDir = if storageClaim == null then null else "${storageClaim.mountPoint}/library/flows";
}
