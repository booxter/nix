{
  config,
  facts,
  lib,
  outputs,
  pkgs,
}:
let
  cfg = config.host.pinepods;
  storage = import ../storage/resources/model.nix { inherit config lib outputs; };
  claim = storage.localClaims.${cfg.storage.claim} or null;
  ssoApplication = config.host.sso.applications.${cfg.sso.application} or null;
  bootstrapOwnerName = if ssoApplication == null then null else ssoApplication.bootstrapOwner;
  bootstrapOwner =
    if bootstrapOwnerName == null then null else config.host.sso.users.${bootstrapOwnerName} or null;
  ociImages = import ../../_lib/oci-images.nix { inherit facts pkgs; };
in
{
  inherit
    bootstrapOwner
    bootstrapOwnerName
    cfg
    claim
    ssoApplication
    ;
  downloadsDir = if claim == null then null else "${claim.mountPoint}/${cfg.storage.relativePath}";
  storageGroup = if claim == null then null else claim.resolvedResource.sharedGroup;
  service = config.host.web.services.pinepods;
  oidcClient = config.host.sso.oidc.clients.pinepods or null;
  oidcScopes = config.host.sso.oidc.baseScopes;
  image = ociImages.pinepods.ref;
  imageFile = ociImages.pinepods.imageFile;
  bootstrapReady =
    bootstrapOwner != null
    && bootstrapOwner.mailAddressSopsKey != null
    && ssoApplication.adminGroup != null
    && ssoApplication.userGroup != null;
}
